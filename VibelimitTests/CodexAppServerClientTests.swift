import XCTest
@testable import Vibelimit

final class CodexAppServerClientTests: XCTestCase {
    func testJSONLBufferHandlesPartialAndMalformedLines() {
        let buffer = JSONLBuffer()

        XCTAssertTrue(buffer.append(Data("{\"id\":".utf8)).isEmpty)
        let lines = buffer.append(Data("1}\nnot-json\n".utf8))

        XCTAssertEqual(String(decoding: lines[0], as: UTF8.self), "{\"id\":1}")
        XCTAssertEqual(String(decoding: lines[1], as: UTF8.self), "not-json")
    }

    func testExecutableDiscoveryUsesCandidateThenPathFallback() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("codex")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        XCTAssertEqual(
            CodexExecutableDiscovery.discover(
                environment: [:],
                preferredPaths: [executable.path]
            ),
            executable
        )
        XCTAssertEqual(
            CodexExecutableDiscovery.discover(
                environment: ["PATH": directory.path],
                preferredPaths: []
            ),
            executable
        )
    }

    func testClientInitializesAndReadsRateLimitsFromJSONLProcess() throws {
        let executable = try makeFakeServer(
            """
            #!/bin/sh
            IFS= read -r initialize
            printf '%s\\n' '{"id":0,"result":{"userAgent":"fake"}}'
            IFS= read -r initialized
            IFS= read -r request
            printf '%s\\n' '{"id":1,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":12,"windowDurationMins":10080,"resetsAt":1785913256}}}}'
            while IFS= read -r line; do :; done
            """
        )
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }

        let client = CodexAppServerClient(executableURL: executable, requestTimeout: 1)
        let expectation = expectation(description: "rate limits")
        var result: Result<RateLimitsPayload, CodexClientError>?

        client.refresh {
            result = $0
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 2)
        client.stop()

        let payload = try XCTUnwrap(try result?.get())
        XCTAssertEqual(payload.sortedBuckets.first?.primary?.remainingPercent, 88)
    }

    func testClientTimesOutWhenServerDoesNotAnswerRateLimitRequest() throws {
        let executable = try makeFakeServer(
            """
            #!/bin/sh
            IFS= read -r initialize
            printf '%s\\n' '{"id":0,"result":{"userAgent":"fake"}}'
            while IFS= read -r line; do :; done
            """
        )
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }

        let client = CodexAppServerClient(executableURL: executable, requestTimeout: 0.05)
        let expectation = expectation(description: "timeout")
        var receivedError: CodexClientError?

        client.refresh { result in
            if case let .failure(error) = result {
                receivedError = error
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1)
        client.stop()

        XCTAssertEqual(receivedError, .timedOut)
    }

    func testClientIgnoresMalformedLineAndStillDecodesNextResponse() throws {
        let executable = try makeFakeServer(
            """
            #!/bin/sh
            IFS= read -r initialize
            printf '%s\\n' 'not-json'
            printf '%s\\n' '{"id":0,"result":{"userAgent":"fake"}}'
            IFS= read -r initialized
            IFS= read -r request
            printf '%s\\n' '{"id":1,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":20,"windowDurationMins":300,"resetsAt":1785913256}}}}'
            while IFS= read -r line; do :; done
            """
        )
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }

        let client = CodexAppServerClient(executableURL: executable, requestTimeout: 1)
        let expectation = expectation(description: "response after malformed line")

        client.refresh { result in
            XCTAssertEqual(try? result.get().sortedBuckets.first?.primary?.remainingPercent, 80)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 2)
        client.stop()
    }

    func testClientForwardsRateLimitNotification() throws {
        let executable = try makeFakeServer(
            """
            #!/bin/sh
            IFS= read -r initialize
            printf '%s\\n' '{"id":0,"result":{"userAgent":"fake"}}'
            IFS= read -r initialized
            printf '%s\\n' '{"method":"account/rateLimits/updated","params":{"rateLimits":{"limitId":"codex"}}}'
            IFS= read -r request
            printf '%s\\n' '{"id":1,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":10,"windowDurationMins":60,"resetsAt":1785913256}}}}'
            while IFS= read -r line; do :; done
            """
        )
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }

        let client = CodexAppServerClient(executableURL: executable, requestTimeout: 1)
        let notification = expectation(description: "rate limit notification")
        let response = expectation(description: "rate limit response")
        client.onRateLimitsChanged = {
            notification.fulfill()
        }
        client.refresh { _ in
            response.fulfill()
        }

        wait(for: [notification, response], timeout: 2)
        client.stop()
    }

    func testClientCompletesWhenProcessTerminates() throws {
        let executable = try makeFakeServer(
            """
            #!/bin/sh
            IFS= read -r initialize
            printf '%s\\n' '{"id":0,"result":{"userAgent":"fake"}}'
            IFS= read -r initialized
            IFS= read -r request
            exit 7
            """
        )
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }

        let client = CodexAppServerClient(executableURL: executable, requestTimeout: 1)
        let completion = expectation(description: "request completion")
        var receivedError: CodexClientError?
        client.refresh { result in
            if case let .failure(error) = result {
                receivedError = error
            }
            completion.fulfill()
        }

        wait(for: [completion], timeout: 2)
        client.stop()

        guard case .processFailed = receivedError else {
            return XCTFail("Expected process failure, got \(String(describing: receivedError))")
        }
    }

    private func makeFakeServer(_ source: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("fake-codex")
        try Data(source.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        return executable
    }
}
