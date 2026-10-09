import Darwin
import Foundation
import XCTest

final class OMPClientTests: XCTestCase {
    func testClientDrainsLargeStderrAndAcceptsEmptySuccess() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("QuotabletOMPTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try makeExecutable(
            in: directory,
            body: """
            #!/bin/sh
            [ "$1" = "usage" ] && [ "$2" = "--json" ] || exit 64
            i=0
            while [ "$i" -lt 8192 ]; do
              printf 'synthetic diagnostic\\n' >&2
              i=$((i + 1))
            done
            printf '%s\\n' '{"generatedAt":1800000000000,"reports":[]}'
            """
        )

        let snapshot = try await OMPClient().fetch(configuration: CLIConfiguration(executablePath: executable.path, homeDirectory: directory))

        XCTAssertTrue(snapshot.reports.isEmpty)
        XCTAssertEqual(snapshot.generatedAt, Date(timeIntervalSince1970: 1_800_000_000))
    }

    func testCommandFailureNeverReturnsRawStderr() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("QuotabletOMPTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try makeExecutable(
            in: directory,
            body: """
            #!/bin/sh
            printf '%s\\n' 'synthetic-private-diagnostic' >&2
            exit 17
            """
        )

        do {
            _ = try await OMPClient().fetch(configuration: CLIConfiguration(executablePath: executable.path, homeDirectory: directory))
            XCTFail("A nonzero command must not produce a usage snapshot.")
        } catch let error as OMPClientError {
            XCTAssertEqual(error, .commandFailed(17))
            XCTAssertFalse(error.localizedDescription.contains("synthetic-private-diagnostic"))
        }
    }

    func testBrokenExplicitPathDoesNotFallBackToAutomaticDiscovery() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("QuotabletOMPTests-\(UUID().uuidString)", isDirectory: true)
        do {
            _ = try await OMPClient().fetch(
                configuration: CLIConfiguration(executablePath: directory.appendingPathComponent("missing-omp").path)
            )
            XCTFail("A configured but missing executable must not use automatic discovery.")
        } catch let error as OMPClientError {
            XCTAssertEqual(error, .configuredExecutableUnavailable)
        } catch {
            XCTFail("The executable boundary must return a safe OMP error.")
        }
    }

    func testDecodesCurrentNestedWireShapesAndLiteralValues() throws {
        let payload = Data(
            """
            {
              "generatedAt": 1800000000000,
              "reports": [
                {
                  "provider": "anthropic",
                  "fetchedAt": 1799999900000,
                  "metadata": {
                    "accountId": "synthetic-account",
                    "orgId": "synthetic-org",
                    "orgName": "Synthetic Org",
                    "projectId": "synthetic-project",
                    "email": "person@example.invalid"
                  },
                  "resetCredits": { "availableCount": 2, "credits": [] },
                  "limits": [
                    {
                      "id": "anthropic:5h",
                      "label": "Claude 5 Hour",
                      "scope": {
                        "provider": "anthropic",
                        "accountId": "synthetic-account",
                        "orgId": "synthetic-org",
                        "projectId": "synthetic-project",
                        "modelId": "synthetic-model",
                        "windowId": "5h",
                        "tier": "pro",
                        "shared": true
                      },
                      "window": {
                        "id": "5h",
                        "label": "5 Hour",
                        "durationMs": 18000000,
                        "resetsAt": 1800003600000,
                        "resetLabel": "tick"
                      },
                      "amount": {
                        "used": 25,
                        "limit": 100,
                        "remaining": 75,
                        "usedFraction": 0.25,
                        "remainingFraction": 0.75,
                        "unit": "percent"
                      },
                      "status": "ok"
                    }
                  ]
                },
                {
                  "provider": "cursor",
                  "fetchedAt": 1800000000000,
                  "limits": []
                },
                {
                  "provider": "openai-codex",
                  "fetchedAt": 1800000000000,
                  "limits": [{
                    "id": "codex:5h",
                    "label": "Codex 5 Hour",
                    "scope": {
                      "provider": "openai-codex",
                      "accountId": "scope-only-account",
                      "windowId": "5h"
                    },
                    "window": { "id": "5h", "label": "5 Hour" },
                    "amount": { "unit": "percent" }
                  }]
                }
              ]
            }
            """.utf8
        )
        let receivedAt = Date(timeIntervalSince1970: 1_800_000_001)
        let snapshot = try OMPClient.decode(payload, receivedAt: receivedAt)
        let report = try XCTUnwrap(snapshot.reports.first)
        let quota = try XCTUnwrap(report.quotas.first)
        let window = try XCTUnwrap(quota.window)
        let amount = try XCTUnwrap(quota.amount)

        XCTAssertEqual(snapshot.generatedAt, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(snapshot.receivedAt, receivedAt)
        XCTAssertEqual(report.fetchedAt, Date(timeIntervalSince1970: 1_799_999_900))
        XCTAssertEqual(report.sourceAccount, SourceAccountIdentity(
            accountID: "synthetic-account",
            organizationID: "synthetic-org",
            projectID: "synthetic-project"
        ))
        XCTAssertEqual(report.privateDisplayLabel, "person@example.invalid")
        XCTAssertEqual(report.resetCredits, 2)
        XCTAssertEqual(window.identity.id, "5h")
        XCTAssertEqual(window.label, "5 Hour")
        XCTAssertEqual(window.durationMilliseconds, 18_000_000.0)
        XCTAssertEqual(quota.resetsAt, Date(timeIntervalSince1970: 1_800_003_600))
        XCTAssertEqual(window.resetLabel, "tick")
        XCTAssertEqual(quota.scope, QuotaScope(
            provider: "anthropic",
            accountID: "synthetic-account",
            organizationID: "synthetic-org",
            projectID: "synthetic-project",
            modelID: "synthetic-model",
            tier: "pro",
            windowID: "5h",
            shared: true
        ))
        XCTAssertEqual(quota.scope?.tier, "pro")
        XCTAssertEqual(amount.displayedRemaining, 75)
        XCTAssertEqual(amount.unit, .percent)
        XCTAssertEqual(quota.status, .available)
        let emptyMetadataReport = snapshot.reports[1]
        XCTAssertNil(emptyMetadataReport.sourceAccount)
        XCTAssertNil(emptyMetadataReport.privateDisplayLabel)
        XCTAssertNil(emptyMetadataReport.resetCredits)
        let scopeOnlyReport = try XCTUnwrap(snapshot.reports.last)
        XCTAssertEqual(scopeOnlyReport.sourceAccount, SourceAccountIdentity(
            accountID: "scope-only-account",
            organizationID: nil,
            projectID: nil
        ))
    }

    func testScopeDiscriminatorAliasesDoNotBecomeIdentity() throws {
        let payload = Data(
            """
            {
              "generatedAt": 1800000000000,
              "reports": [{
                "provider": "anthropic",
                "fetchedAt": 1800000000000,
                "limits": [{
                  "id": "anthropic:5h",
                  "label": "Claude 5 Hour",
                  "scope": { "provider": "anthropic", "kind": "organization", "id": "invented-org" },
                  "window": { "id": "5h", "label": "5 Hour" },
                  "amount": { "unit": "percent" }
                }]
              }]
            }
            """.utf8
        )

        let snapshot = try OMPClient.decode(payload)
        let quota = try XCTUnwrap(snapshot.reports.first?.quotas.first)
        let scope = try XCTUnwrap(quota.scope)

        XCTAssertEqual(scope.provider, "anthropic")
        XCTAssertNil(scope.organizationID)
        XCTAssertNil(scope.projectID)
        XCTAssertNil(scope.accountID)
    }

    func testConflictingScopeAccountIDsGiveNoSourceAccount() throws {
        let payload = Data(
            """
            {
              "generatedAt": 1800000000000,
              "reports": [{
                "provider": "anthropic",
                "fetchedAt": 1800000000000,
                "limits": [
                  {
                    "id": "anthropic:5h",
                    "label": "Claude 5 Hour",
                    "scope": { "provider": "anthropic", "accountId": "scope-account-a", "windowId": "5h" },
                    "window": { "id": "5h", "label": "5 Hour" },
                    "amount": { "unit": "percent" }
                  },
                  {
                    "id": "anthropic:7d",
                    "label": "Claude 7 Day",
                    "scope": { "provider": "anthropic", "accountId": "scope-account-b", "windowId": "7d" },
                    "window": { "id": "7d", "label": "7 Day" },
                    "amount": { "unit": "percent" }
                  }
                ]
              }]
            }
            """.utf8
        )

        let report = try XCTUnwrap(OMPClient.decode(payload).reports.first)

        XCTAssertNil(report.sourceAccount)
    }

    func testMalformedRequiredEnvelopeAndFlatWindowAreRejected() {
        for payload in [
            "{\"reports\":[]}",
            "{\"generatedAt\":1800000000000,\"reports\":[{\"provider\":\"anthropic\",\"limits\":[]}]}"
        ] {
            XCTAssertThrowsError(try OMPClient.decode(Data(payload.utf8))) { error in
                XCTAssertEqual(error as? OMPClientError, .invalidResponse)
            }
        }

        let flatWindow = Data(
            """
            {
              "generatedAt": 1800000000000,
              "reports": [{
                "provider": "anthropic",
                "fetchedAt": 1800000000000,
                "limits": [{
                  "id": "anthropic:5h",
                  "label": "Claude 5 Hour",
                  "scope": { "provider": "anthropic", "windowId": "5h" },
                  "window": "5h",
                  "amount": { "unit": "percent" }
                }]
              }]
            }
            """.utf8
        )
        XCTAssertThrowsError(try OMPClient.decode(flatWindow)) { error in
            XCTAssertEqual(error as? OMPClientError, .invalidResponse)
        }
    }

    private func makeExecutable(in directory: URL, body: String) throws -> URL {
        let executable = directory.appendingPathComponent("synthetic-omp")
        try body.write(to: executable, atomically: true, encoding: .utf8)
        guard Darwin.chmod(executable.path, mode_t(S_IRUSR | S_IWUSR | S_IXUSR)) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return executable
    }
}
