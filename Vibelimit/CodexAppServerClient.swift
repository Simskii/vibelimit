import Foundation

enum CodexClientError: LocalizedError, Equatable {
    case executableNotFound
    case processFailed(String)
    case invalidResponse
    case server(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "A compatible Codex installation wasn’t found."
        case .processFailed:
            return "Codex stopped unexpectedly."
        case .invalidResponse:
            return "Codex returned an unreadable response."
        case let .server(message):
            return message.isEmpty ? "Codex couldn’t refresh limits." : message
        case .timedOut:
            return "Codex took too long to respond."
        }
    }
}

struct CodexExecutableDiscovery {
    static let preferredPaths = [
        "/Applications/ChatGPT.app/Contents/Resources/codex",
        "/opt/homebrew/bin/codex",
        "/usr/local/bin/codex",
        "/usr/bin/codex"
    ]

    static func discover(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        preferredPaths: [String] = preferredPaths
    ) -> URL? {
        for path in preferredPaths where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        let pathEntries = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        for entry in pathEntries {
            let candidate = URL(fileURLWithPath: entry).appendingPathComponent("codex").path
            if fileManager.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }
}

final class JSONLBuffer {
    private(set) var data = Data()

    func append(_ newData: Data) -> [Data] {
        data.append(newData)
        var lines: [Data] = []
        while let newline = data.firstIndex(of: 0x0A) {
            let line = data[..<newline]
            data.removeSubrange(...newline)
            if !line.isEmpty {
                lines.append(Data(line))
            }
        }
        return lines
    }
}

final class CodexAppServerClient {
    typealias PayloadCompletion = (Result<RateLimitsPayload, CodexClientError>) -> Void

    var onRateLimitsChanged: (() -> Void)?
    var onProcessExit: ((CodexClientError) -> Void)?

    private let executableURL: URL?
    private let requestTimeout: TimeInterval
    private let queue = DispatchQueue(label: "se.simonlundh.vibelimit.codex-client")
    private let decoder = JSONDecoder()
    private let stdoutBuffer = JSONLBuffer()
    private var process: Process?
    private var inputHandle: FileHandle?
    private var nextRequestID = 1
    private var initialized = false
    private var pendingAfterInitialization: [(Result<Void, CodexClientError>) -> Void] = []
    private var completions: [Int: PayloadCompletion] = [:]
    private var timeoutItems: [Int: DispatchWorkItem] = [:]
    private var stoppedIntentionally = false

    init(
        executableURL: URL? = CodexExecutableDiscovery.discover(),
        requestTimeout: TimeInterval = 12
    ) {
        self.executableURL = executableURL
        self.requestTimeout = requestTimeout
    }

    func refresh(completion: @escaping PayloadCompletion) {
        queue.async { [weak self] in
            guard let self else { return }
            self.ensureStarted { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    self.sendRateLimitRequest(completion: completion)
                case let .failure(error):
                    DispatchQueue.main.async { completion(.failure(error)) }
                }
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stoppedIntentionally = true
            self.process?.terminationHandler = nil
            if self.process?.isRunning == true {
                self.process?.terminate()
            }
            self.cleanUp()
        }
    }

    private func ensureStarted(completion: @escaping (Result<Void, CodexClientError>) -> Void) {
        if initialized, process?.isRunning == true {
            completion(.success(()))
            return
        }

        pendingAfterInitialization.append(completion)

        if process?.isRunning == true {
            return
        }

        guard let executableURL else {
            failInitialization(with: .executableNotFound)
            return
        }

        stoppedIntentionally = false
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()

        process.executableURL = executableURL
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async {
                self?.consume(data)
            }
        }
        error.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        process.terminationHandler = { [weak self] process in
            self?.queue.async {
                self?.handleTermination(status: process.terminationStatus)
            }
        }

        do {
            try process.run()
            self.process = process
            inputHandle = input.fileHandleForWriting
            try send([
                "method": "initialize",
                "id": 0,
                "params": [
                    "clientInfo": [
                        "name": "vibelimit",
                        "title": "Vibelimit",
                        "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
                    ]
                ]
            ])
        } catch {
            cleanUp()
            failInitialization(with: .processFailed(error.localizedDescription))
        }
    }

    private func consume(_ data: Data) {
        for line in stdoutBuffer.append(data) {
            consumeLine(line)
        }
    }

    private func consumeLine(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        if let method = object["method"] as? String {
            if method == "account/rateLimits/updated" {
                DispatchQueue.main.async { [weak self] in
                    self?.onRateLimitsChanged?()
                }
            }
            return
        }

        guard let id = object["id"] as? Int else { return }
        if id == 0 {
            guard object["result"] != nil else {
                let message = Self.errorMessage(from: object)
                failInitialization(with: .server(message))
                return
            }
            do {
                try send(["method": "initialized", "params": [:] as [String: Any]])
                initialized = true
                let callbacks = pendingAfterInitialization
                pendingAfterInitialization.removeAll()
                callbacks.forEach { $0(.success(())) }
            } catch {
                failInitialization(with: .processFailed(error.localizedDescription))
            }
            return
        }

        guard let completion = completions.removeValue(forKey: id) else { return }
        timeoutItems.removeValue(forKey: id)?.cancel()

        if let error = object["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "Codex couldn’t refresh limits."
            DispatchQueue.main.async { completion(.failure(.server(message))) }
            return
        }

        guard let result = object["result"],
              JSONSerialization.isValidJSONObject(result),
              let resultData = try? JSONSerialization.data(withJSONObject: result),
              let payload = try? decoder.decode(RateLimitsPayload.self, from: resultData) else {
            DispatchQueue.main.async { completion(.failure(.invalidResponse)) }
            return
        }

        DispatchQueue.main.async { completion(.success(payload)) }
    }

    private func sendRateLimitRequest(completion: @escaping PayloadCompletion) {
        let id = nextRequestID
        nextRequestID += 1
        completions[id] = completion

        let timeout = DispatchWorkItem { [weak self] in
            guard let self, let completion = self.completions.removeValue(forKey: id) else { return }
            self.timeoutItems.removeValue(forKey: id)
            DispatchQueue.main.async { completion(.failure(.timedOut)) }
        }
        timeoutItems[id] = timeout
        queue.asyncAfter(deadline: .now() + requestTimeout, execute: timeout)

        do {
            try send(["method": "account/rateLimits/read", "id": id])
        } catch {
            timeout.cancel()
            timeoutItems.removeValue(forKey: id)
            completions.removeValue(forKey: id)
            DispatchQueue.main.async {
                completion(.failure(.processFailed(error.localizedDescription)))
            }
        }
    }

    private func send(_ object: [String: Any]) throws {
        guard let inputHandle else {
            throw CodexClientError.processFailed("Input stream unavailable")
        }
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try inputHandle.write(contentsOf: data)
    }

    private func handleTermination(status: Int32) {
        let error = CodexClientError.processFailed("Exit status \(status)")
        let pending = Array(completions.values)
        cleanUp()
        pending.forEach { completion in
            DispatchQueue.main.async { completion(.failure(error)) }
        }
        if !stoppedIntentionally {
            DispatchQueue.main.async { [weak self] in
                self?.onProcessExit?(error)
            }
        }
    }

    private func failInitialization(with error: CodexClientError) {
        let callbacks = pendingAfterInitialization
        cleanUp()
        DispatchQueue.main.async { [weak self] in
            callbacks.forEach { $0(.failure(error)) }
            self?.onProcessExit?(error)
        }
    }

    private func cleanUp() {
        timeoutItems.values.forEach { $0.cancel() }
        timeoutItems.removeAll()
        completions.removeAll()
        pendingAfterInitialization.removeAll()
        inputHandle = nil
        process = nil
        initialized = false
    }

    private static func errorMessage(from object: [String: Any]) -> String {
        guard let error = object["error"] as? [String: Any] else {
            return "Codex couldn’t start."
        }
        return error["message"] as? String ?? "Codex couldn’t start."
    }
}
