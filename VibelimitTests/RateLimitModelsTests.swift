import XCTest
@testable import Vibelimit

final class RateLimitModelsTests: XCTestCase {
    func testDecodesAndSortsMultiBucketPayloadWithCodexFirst() throws {
        let data = Data(
            """
            {
              "rateLimits": {
                "limitId": "codex",
                "limitName": null,
                "primary": {
                  "usedPercent": 3,
                  "windowDurationMins": 10080,
                  "resetsAt": 1785913256
                },
                "secondary": null,
                "credits": {"hasCredits": false, "unlimited": false, "balance": "0"},
                "planType": "prolite",
                "rateLimitReachedType": null
              },
              "rateLimitsByLimitId": {
                "codex_spark": {
                  "limitId": "codex_spark",
                  "limitName": "GPT-5.3-Codex-Spark",
                  "primary": {
                    "usedPercent": 42,
                    "windowDurationMins": 300,
                    "resetsAt": 1785910000
                  },
                  "secondary": null,
                  "credits": null,
                  "planType": "prolite",
                  "rateLimitReachedType": null
                },
                "codex": {
                  "limitId": "codex",
                  "limitName": null,
                  "primary": {
                    "usedPercent": 3,
                    "windowDurationMins": 10080,
                    "resetsAt": 1785913256
                  },
                  "secondary": null,
                  "credits": null,
                  "planType": "prolite",
                  "rateLimitReachedType": null
                }
              },
              "rateLimitResetCredits": {
                "availableCount": 2,
                "credits": []
              }
            }
            """.utf8
        )

        let payload = try JSONDecoder().decode(RateLimitsPayload.self, from: data)

        XCTAssertEqual(payload.sortedBuckets.map(\.limitId), ["codex", "codex_spark"])
        XCTAssertEqual(payload.sortedBuckets[0].displayName, "Codex")
        XCTAssertEqual(payload.sortedBuckets[1].displayName, "GPT-5.3-Codex-Spark")
        XCTAssertEqual(payload.rateLimitResetCredits?.availableCount, 2)
    }

    func testFallsBackToLegacySingleBucket() throws {
        let data = Data(
            """
            {
              "rateLimits": {
                "limitId": "codex",
                "primary": {
                  "usedPercent": 25,
                  "windowDurationMins": 60,
                  "resetsAt": 1000
                }
              }
            }
            """.utf8
        )

        let payload = try JSONDecoder().decode(RateLimitsPayload.self, from: data)

        XCTAssertEqual(payload.sortedBuckets.count, 1)
        XCTAssertEqual(payload.sortedBuckets[0].primary?.remainingPercent, 75)
    }

    func testRemainingPercentClampsToValidRange() {
        XCTAssertEqual(makeWindow(used: -12).remainingPercent, 100)
        XCTAssertEqual(makeWindow(used: 43.5).remainingPercent, 56.5)
        XCTAssertEqual(makeWindow(used: 140).remainingPercent, 0)
    }

    func testWindowAndCountdownFormatting() {
        XCTAssertEqual(DurationFormatter.windowLabel(minutes: 10_080), "7d")
        XCTAssertEqual(DurationFormatter.windowLabel(minutes: 300), "5h")
        XCTAssertEqual(DurationFormatter.windowLabel(minutes: 45), "45m")

        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(
            DurationFormatter.countdown(
                to: Date(timeIntervalSince1970: 1_000 + 90_060),
                relativeTo: now
            ),
            "1d 1h"
        )
        XCTAssertEqual(
            DurationFormatter.countdown(
                to: Date(timeIntervalSince1970: 1_000 + 5_460),
                relativeTo: now
            ),
            "1h 31m"
        )
    }

    func testCapacityThresholds() {
        XCTAssertEqual(CapacityLevel(remainingPercent: 26), .healthy)
        XCTAssertEqual(CapacityLevel(remainingPercent: 25), .warning)
        XCTAssertEqual(CapacityLevel(remainingPercent: 10), .warning)
        XCTAssertEqual(CapacityLevel(remainingPercent: 9.9), .critical)
    }

    func testMenuPercentageUsesCodexThenLowestFallback() {
        let spark = makeBucket(id: "spark", used: 60)
        let other = makeBucket(id: "other", used: 20)
        XCTAssertEqual(
            UsageSnapshot(buckets: [spark, other], resetCredits: nil).menuRemainingPercent,
            40
        )

        let codex = makeBucket(id: "codex", used: 5)
        XCTAssertEqual(
            UsageSnapshot(buckets: [spark, codex], resetCredits: nil).menuRemainingPercent,
            95
        )
    }

    func testDisplayBucketsPrefersOnlyCanonicalCodex() {
        let spark = makeBucket(id: "codex_spark", used: 60)
        let codex = makeBucket(id: "codex", used: 5)

        XCTAssertEqual(
            UsageSnapshot(buckets: [codex, spark], resetCredits: nil).displayBuckets.map(\.limitId),
            ["codex"]
        )
        XCTAssertEqual(
            UsageSnapshot(buckets: [spark], resetCredits: nil).displayBuckets.map(\.limitId),
            ["codex_spark"]
        )
    }

    func testNotificationStateUsesMostConstrainedCodexWindow() throws {
        let primary = makeWindow(used: 20)
        let secondary = RateLimitWindow(
            usedPercent: 94,
            windowDurationMins: 10_080,
            resetsAt: 2_000
        )
        let bucket = RateLimitBucket(
            limitId: "codex",
            limitName: nil,
            primary: primary,
            secondary: secondary,
            credits: nil,
            planType: nil,
            rateLimitReachedType: nil
        )

        let state = try XCTUnwrap(
            LimitNotificationEvaluator.state(
                for: UsageSnapshot(buckets: [bucket], resetCredits: nil)
            )
        )

        XCTAssertEqual(state.remainingPercent, 6)
        XCTAssertEqual(state.resetsAt, 2_000)
        XCTAssertFalse(state.isExhausted)
    }

    func testNotificationEventsOnlyFireOnMeaningfulTransitions() {
        let healthy = LimitNotificationState(
            remainingPercent: 40,
            isExhausted: false,
            resetsAt: 1_000
        )
        let low = LimitNotificationState(
            remainingPercent: 10,
            isExhausted: false,
            resetsAt: 1_000
        )
        let exhausted = LimitNotificationState(
            remainingPercent: 0,
            isExhausted: true,
            resetsAt: 1_000
        )
        let recovered = LimitNotificationState(
            remainingPercent: 100,
            isExhausted: false,
            resetsAt: 2_000
        )

        XCTAssertNil(LimitNotificationEvaluator.event(previous: nil, current: low))
        XCTAssertEqual(
            LimitNotificationEvaluator.event(previous: healthy, current: low),
            .low(remainingPercent: 10, resetsAt: 1_000)
        )
        XCTAssertNil(LimitNotificationEvaluator.event(previous: low, current: low))
        XCTAssertEqual(
            LimitNotificationEvaluator.event(previous: low, current: exhausted),
            .exhausted(resetsAt: 1_000)
        )
        XCTAssertEqual(
            LimitNotificationEvaluator.event(previous: exhausted, current: recovered),
            .recovered(remainingPercent: 100)
        )
    }

    private func makeWindow(used: Double) -> RateLimitWindow {
        RateLimitWindow(usedPercent: used, windowDurationMins: 60, resetsAt: 1_000)
    }

    private func makeBucket(id: String, used: Double) -> RateLimitBucket {
        RateLimitBucket(
            limitId: id,
            limitName: nil,
            primary: makeWindow(used: used),
            secondary: nil,
            credits: nil,
            planType: nil,
            rateLimitReachedType: nil
        )
    }
}
