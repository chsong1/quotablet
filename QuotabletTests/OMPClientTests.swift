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

    func testTheWeeklyGrokShapeDecodesWithOnlyItsSharedPoolStandingForTheAccountWhileCursorStaysSeparate() throws {
        func limit(_ id: String, _ label: String, used: Double) -> String {
            """
            {
              "id": "\(id)",
              "label": "\(label)",
              "scope": { "provider": "xai-oauth", "windowId": "1w", "shared": true },
              "window": { "id": "1w", "label": "Weekly", "durationMs": 604800000, "resetsAt": 1800500000000 },
              "amount": { "used": \(used), "limit": 100, "remaining": \(100 - used), "usedFraction": \(used / 100), "remainingFraction": \(1 - used / 100), "unit": "percent" },
              "status": "ok"
            }
            """
        }
        let payload = Data(
            """
            {
              "generatedAt": 1800000000000,
              "reports": [
                {
                  "provider": "xai-oauth",
                  "fetchedAt": 1800000000000,
                  "metadata": { "accountId": "synthetic-grok", "billingKind": "weekly" },
                  "limits": [
                    \(limit("xai-oauth:credits:1w", "SuperGrok Weekly Credits", used: 24)),
                    \(limit("xai-oauth:product:cursor:1w", "Cursor (Weekly)", used: 22)),
                    \(limit("xai-oauth:product:grokbot:1w", "GrokBot (Weekly)", used: 1)),
                    \(limit("xai-oauth:product:api:1w", "API (Weekly)", used: 1)),
                    {
                      "id": "xai-oauth:on-demand",
                      "label": "On-demand",
                      "scope": { "provider": "xai-oauth", "shared": true },
                      "amount": { "used": 0, "limit": 50, "remaining": 50, "usedFraction": 0, "remainingFraction": 1, "unit": "unknown" },
                      "status": "ok"
                    }
                  ]
                },
                {
                  "provider": "cursor",
                  "fetchedAt": 1800000000000,
                  "limits": [
                    {
                      "id": "cursor:usd:individual-auto",
                      "label": "Cursor Models",
                      "scope": { "provider": "cursor", "windowId": "monthly" },
                      "window": { "id": "monthly", "label": "Monthly", "resetsAt": 1801000000000 },
                      "amount": { "used": 0, "usedFraction": 0, "unit": "percent" },
                      "status": "ok"
                    },
                    {
                      "id": "cursor:usd:individual-api",
                      "label": "Other Models",
                      "scope": { "provider": "cursor", "windowId": "monthly" },
                      "window": { "id": "monthly", "label": "Monthly", "resetsAt": 1801000000000 },
                      "amount": { "used": 0, "limit": 553.95, "remaining": 553.95, "usedFraction": 0, "remainingFraction": 1, "unit": "usd" },
                      "status": "ok"
                    }
                  ]
                }
              ]
            }
            """.utf8
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let snapshot = try OMPClient.decode(payload, receivedAt: now)
        let providers = snapshot.providerUsage(now: now)
        let grok = try XCTUnwrap(snapshot.providerDetail(of: "xai-oauth", now: now)).accounts[0]
        let cursor = try XCTUnwrap(snapshot.providerDetail(of: "cursor", now: now)).accounts[0]

        XCTAssertEqual(providers.map(\.provider), ["xai-oauth", "cursor"])
        XCTAssertEqual(providers[0].measured.map(\.quota.limitID), ["xai-oauth:credits:1w"])
        XCTAssertEqual(try XCTUnwrap(providers[0].usedFraction), 0.24, accuracy: 0.0001)
        XCTAssertEqual(grok.windows.map(\.name.short), ["Shared pool", "On-demand"])
        // OMP names the unit of the on-demand amount "unknown", so it has no currency to show.
        XCTAssertNil(grok.windows[1].money)
        XCTAssertEqual(grok.productUsage.map(\.phrase), ["Cursor 22%", "GrokBot 1%", "API 1%"])
        // The Cursor report carries no account identity, so nothing joins it to the Grok account.
        XCTAssertNil(snapshot.reports[1].sourceAccount)
        XCTAssertEqual(try XCTUnwrap(providers[1].usedFraction), 0, accuracy: 0.0001)
        XCTAssertEqual(cursor.windows.map(\.money?.limit), [nil, 553.95])
        XCTAssertTrue(cursor.productUsage.isEmpty)
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

    func testDecodesDisabledCredentialsAndAccountsWithoutUsageIntoOneProblemList() throws {
        let payload = Data(
            #"""
            {
              "generatedAt": 1800000000000,
              "reports": [],
              "accountsWithoutUsage": [
                { "provider": "openai-codex", "type": "oauth", "orgName": "Synthetic Org", "accountId": "codex-account", "authorizedAt": 1799990000000 },
                { "provider": "cursor", "type": "api_key", "projectId": "cursor-project" },
                { "provider": "xai-oauth", "type": "oauth" }
              ],
              "disabledCredentials": [
                {
                  "id": 7,
                  "provider": "anthropic",
                  "type": "oauth",
                  "email": "person@example.invalid",
                  "orgName": "Synthetic Org",
                  "cause": "oauth refresh failed: OAuthError: anthropic token refresh failed: 400 {\"error\": \"invalid_grant\", \"error_description\": \"Refresh token not found or invalid\"}",
                  "disabledAtMs": 1799996400000
                },
                { "id": 8, "provider": "anthropic", "type": "oauth", "accountId": "claude-account", "cause": "oauth refresh failed: token revoked by provider" }
              ]
            }
            """#.utf8
        )

        let problems = try OMPClient.decode(payload).accountProblems

        XCTAssertEqual(problems, [
            AccountProblem(
                provider: "anthropic",
                kind: .disconnected,
                privateDisplayLabel: "person@example.invalid",
                reason: "Refresh token not found or invalid",
                since: Date(timeIntervalSince1970: 1_799_996_400)
            ),
            AccountProblem(provider: "anthropic", kind: .disconnected, privateDisplayLabel: "claude-account", reason: "token revoked by provider", since: nil),
            AccountProblem(provider: "openai-codex", kind: .noUsageData, privateDisplayLabel: "Synthetic Org", reason: nil, since: nil),
            AccountProblem(provider: "cursor", kind: .noUsageData, privateDisplayLabel: "cursor-project", reason: nil, since: nil),
            AccountProblem(provider: "xai-oauth", kind: .noUsageData, privateDisplayLabel: nil, reason: nil, since: nil)
        ])
    }

    func testOutputWithoutEitherListDecodesWithNoProblemAccounts() throws {
        let absent = Data(#"{"generatedAt":1800000000000,"reports":[{"provider":"anthropic","fetchedAt":1800000000000,"limits":[]}]}"#.utf8)
        let empty = Data(#"{"generatedAt":1800000000000,"reports":[],"accountsWithoutUsage":[],"disabledCredentials":[]}"#.utf8)

        let older = try OMPClient.decode(absent)

        XCTAssertEqual(older.reports.map(\.provider), ["anthropic"])
        XCTAssertEqual(older.accountProblems, [])
        XCTAssertEqual(try OMPClient.decode(empty).accountProblems, [])
    }

    func testAnEntryThatCannotBeReadIsDroppedAndNeverCostsTheReportsOrTheOtherEntries() throws {
        let payload = Data(
            #"""
            {
              "generatedAt": 1800000000000,
              "reports": [{ "provider": "anthropic", "fetchedAt": 1800000000000, "limits": [] }],
              "accountsWithoutUsage": "not a list",
              "disabledCredentials": [
                { "id": 1, "type": "oauth", "cause": "an entry without a provider" },
                "not an object",
                { "id": 2, "provider": "   ", "type": "oauth", "cause": "a blank provider" },
                { "id": 3, "provider": "anthropic", "type": "oauth", "cause": "oauth refresh failed: token revoked" }
              ]
            }
            """#.utf8
        )

        let snapshot = try OMPClient.decode(payload)

        XCTAssertEqual(snapshot.reports.count, 1)
        XCTAssertEqual(snapshot.accountProblems, [
            AccountProblem(provider: "anthropic", kind: .disconnected, privateDisplayLabel: nil, reason: "token revoked", since: nil)
        ])
    }

    func testADisconnectedAccountsReasonIsTheUpstreamDescriptionElseTheClauseAfterTheLastColon() throws {
        func reason(_ cause: String?) throws -> String? {
            var entry: [String: Any] = ["id": 1, "provider": "anthropic", "type": "oauth"]
            entry["cause"] = cause
            let payload = try JSONSerialization.data(withJSONObject: ["generatedAt": 1_800_000_000_000, "reports": [], "disabledCredentials": [entry]] as [String: Any])
            return try OMPClient.decode(payload).accountProblems.first?.reason
        }

        XCTAssertEqual(
            try reason(#"oauth refresh failed: OAuthError: anthropic token refresh failed: 400 {"error": "invalid_grant", "error_description": "Refresh token not found or invalid"}"#),
            "Refresh token not found or invalid"
        )
        XCTAssertEqual(
            try reason(#"oauth refresh failed: {\"error_description\": \"Refresh token not found or invalid\"}"#),
            "Refresh token not found or invalid"
        )
        XCTAssertEqual(try reason("oauth refresh failed: OAuthError: openai token refresh failed: connection reset by peer"), "connection reset by peer")
        XCTAssertEqual(try reason("oauth refresh failed:    token revoked  "), "token revoked")
        XCTAssertEqual(try reason("oauth refresh failed"), "oauth refresh failed")
        XCTAssertEqual(
            try reason(#"oauth refresh failed: OAuthError: anthropic token refresh failed: 400 {"error": "invalid_grant"}"#),
            "invalid_grant"
        )
        XCTAssertEqual(
            try reason(#"oauth refresh failed: OAuthError: openai token refresh failed: 400 {"error": {"message": "The refresh token was already used.", "code": "refresh_token_reused"}}"#),
            "The refresh token was already used."
        )
        XCTAssertEqual(
            try reason(#"oauth refresh failed: 400 {"type":"error","error":{"type":"invalid_request_error","message":"Invalid refresh token"}}"#),
            "Invalid refresh token"
        )
        XCTAssertNil(try reason(""))
        XCTAssertNil(try reason("   "))
        XCTAssertNil(try reason(nil))
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
