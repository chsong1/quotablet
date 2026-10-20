import AppKit
import Foundation
import SwiftUI
import XCTest

// Every address here is invented, on a real domain only where the test is about that domain.

final class AccountEmailTests: XCTestCase {
    func testTheDomainIsTheHostAfterTheAddressesSingleAtSignInLowercase() {
        XCTAssertEqual(AccountEmail.domain(of: "person@suresofttech.com"), "suresofttech.com")
        XCTAssertEqual(AccountEmail.domain(of: "Person@SureSoftTech.COM"), "suresofttech.com")
        XCTAssertEqual(AccountEmail.domain(of: "  person@suresofttech.com\n"), "suresofttech.com")
        XCTAssertEqual(AccountEmail.domain(of: "first.last+tag@mail.example.invalid"), "mail.example.invalid")
        XCTAssertEqual(AccountEmail.domain(of: "person@\(String(repeating: "a", count: 63)).invalid"), "\(String(repeating: "a", count: 63)).invalid")
    }

    func testAnAddressQuotabletCannotReadHasNoDomain() {
        let unreadable: [String?] = [
            nil, "", "   ", "person", "person@", "@suresofttech.com",
            "person@@suresofttech.com", "a@b@suresofttech.com", "person@evil.invalid@suresofttech.com",
            "person@suresofttech", "person@suresofttech.com.", "person@.suresofttech.com", "person@suresofttech..com",
            "person@-suresofttech.com", "person@suresofttech-.com", "person@sure_softtech.com",
            "person@suresofttech.com/path", "person@suresofttech.com:443", "person@suresoft tech.com", "per son@suresofttech.com",
            // A dot sits between characters of the name, and a character a mailbox name cannot hold makes the address unreadable.
            ".person@gmail.com", "person..name@suresofttech.com", "person.@gmail.com", "person<@naver.com",
            // A letter of another script is not an ASCII one, whatever it looks like or folds into.
            "person@suresofttech.c\u{043E}m", "person@suresofttech.\u{FF43}om", "person@suresofttech.com\u{0007}",
            "person@\(String(repeating: "a", count: 64)).invalid"
        ]

        for email in unreadable {
            XCTAssertNil(AccountEmail.domain(of: email), email ?? "nil")
        }
    }
}

final class AccountCompanyTests: XCTestCase {
    private func matched(_ email: String?) -> AccountCompany? {
        AccountCompany(emailDomain: AccountEmail.domain(of: email))
    }

    func testEachEvidencedDomainNamesItsCompanyInAnyLetterCase() {
        let addresses: [(String, AccountCompany)] = [
            ("person@suresofttech.com", .suresoft), ("Person@SureSoftTech.Com", .suresoft), ("PERSON@SURESOFTTECH.COM", .suresoft),
            ("person@gmail.com", .gmail), ("PERSON@GMail.COM", .gmail), (" person@gmail.com\n", .gmail),
            ("person@kakao.com", .kakao), ("Person@Kakao.com", .kakao),
            ("person@naver.com", .naver), ("Person@NAVER.com", .naver),
            ("person@privaterelay.appleid.com", .apple), ("person@PrivateRelay.AppleID.com", .apple), ("PERSON@PRIVATERELAY.APPLEID.COM", .apple),
            // Dots and a plus tag inside the name are part of a readable address.
            ("first.last+tag@gmail.com", .gmail), ("first.last@suresofttech.com", .suresoft), ("per+son.name@naver.com", .naver)
        ]

        for (email, company) in addresses {
            XCTAssertEqual(matched(email), company, email)
        }
        XCTAssertEqual(AccountCompany(emailDomain: "suresofttech.com"), .suresoft)
        XCTAssertEqual(AccountCompany(emailDomain: "GMAIL.com"), .gmail)
    }

    func testAPrefixASuffixASubdomainOrAHostInTheLocalPartIsAnotherDomain() {
        for company in AccountCompany.allCases {
            let domain = company.emailDomain
            let lookalikes = [
                "person@evil\(domain)", "person@x\(domain)", "person@\(domain)x", "person@\(domain)-evil.invalid", "person@\(domain).evil.invalid",
                "person@mail.\(domain)", "person@a.b.\(domain)", "person@\(domain).", "person@.\(domain)",
                "\(domain)@evil.invalid", "\(domain)@example.invalid",
                "person@\(domain)@evil.invalid", "person@evil.invalid@\(domain)", "person@evil.invalid?\(domain)"
            ]

            for email in lookalikes {
                XCTAssertNil(matched(email), email)
            }
        }
    }

    func testOtherDomainsOfTheSameBrandsAreNotEvidencedSoTheyStayNumeric() {
        let domains = [
            "suresoft.com", "suresofttech.co.kr", "suresofttech.net",
            "googlemail.com", "google.com", "gmail.co", "gmail.net", "mail.google.com",
            "kakaocorp.com", "kakao.co.kr", "kakaomail.com", "accounts.kakao.com",
            "navercorp.com", "naver.net", "m.naver.com", "mail.naver.com",
            "apple.com", "appleid.com", "appleid.apple.com", "icloud.com", "me.com", "mac.com"
        ]

        for domain in domains {
            XCTAssertNil(matched("person@\(domain)"), domain)
        }
    }

    func testOtherMailProvidersAndUnknownDomainsGetNoCompany() {
        let domains = ["outlook.com", "hotmail.com", "live.com", "yahoo.com", "daum.net", "hanmail.net", "proton.me", "example.invalid"]

        for domain in domains {
            XCTAssertNil(matched("person@\(domain)"), domain)
            XCTAssertNil(matched("Person@\(domain.uppercased())"), domain)
        }
    }

    func testAMissingOrInvalidEmailGetsNoCompany() {
        let emails: [String?] = [
            nil, "", "   ", "not-an-email", "suresofttech.com", "gmail.com", "@gmail.com", "person@", "person@gmail",
            // A listed domain behind a name that is not a readable mailbox name still names no company.
            ".person@gmail.com", "person..name@suresofttech.com", "person.@gmail.com", "person<@naver.com"
        ]

        for email in emails {
            XCTAssertNil(matched(email), email ?? "nil")
        }
        XCTAssertNil(AccountCompany(emailDomain: nil))
        XCTAssertNil(AccountCompany(emailDomain: ""))
    }

    func testEveryCompanyIsReachableFromItsOwnDomainAndNoTwoShareOne() {
        for company in AccountCompany.allCases {
            XCTAssertEqual(AccountCompany(emailDomain: company.emailDomain), company, company.rawValue)
            XCTAssertEqual(AccountEmail.hostName(company.emailDomain), company.emailDomain, company.rawValue)
        }
        XCTAssertEqual(Set(AccountCompany.allCases.map(\.emailDomain)).count, AccountCompany.allCases.count)
    }

    func testTheSpokenBadgeCarriesTheBrandTheNumberAndTheRoleSoOnlyTheCompanyIsHeardAsAnEmployer() {
        XCTAssertEqual(AccountCompany.allCases.filter { $0.role == .employer }, [.suresoft])

        var heardRoleByRole: [AccountCompany.Role: String] = [:]
        for company in AccountCompany.allCases {
            let spoken = company.spokenBadge(number: 2)

            XCTAssertTrue(spoken.contains(company.displayName), spoken)
            XCTAssertTrue(spoken.contains("2"), spoken)
            XCTAssertTrue(company.spokenBadge(number: 17).contains("17"), company.rawValue)
            XCTAssertNotEqual(spoken, company.spokenBadge(number: 3), company.rawValue)

            // What is left once the brand and the number are taken out is what the badge says about the role.
            let heardRole = spoken.replacingOccurrences(of: company.displayName, with: "").replacingOccurrences(of: "2", with: "")
            if let sameRole = heardRoleByRole[company.role] {
                XCTAssertEqual(heardRole, sameRole, company.rawValue)
            } else {
                heardRoleByRole[company.role] = heardRole
            }
        }
        XCTAssertEqual(Set(heardRoleByRole.values).count, heardRoleByRole.count)
    }
}

final class AccountBadgeTests: XCTestCase {
    private let timestamp = Date(timeIntervalSince1970: 1_800_000_000)

    func testOnlyOMPsEmailFieldSuppliesTheReportsDomain() throws {
        let snapshot = try decode([
            ["accountId": "a1", "email": "Person@SureSoftTech.com"],
            ["accountId": "a2", "email": "person@gmail.com"],
            ["accountId": "a3"],
            ["accountId": "a4", "email": "not-an-email"],
            // The label falls back to the organization's name, which here looks like an address. It still names no domain.
            ["accountId": "person@suresofttech.com", "orgName": "person@suresofttech.com"],
            nil
        ])

        XCTAssertEqual(snapshot.reports.map(\.emailDomain), ["suresofttech.com", "gmail.com", nil, nil, nil, nil])
        XCTAssertEqual(snapshot.reports[4].privateDisplayLabel, "person@suresofttech.com")
    }

    func testTheDomainSurvivesSavingAndASnapshotSavedWithoutOneStillLoads() throws {
        let snapshot = try decode([["accountId": "a1", "email": "person@suresofttech.com"]])
        let saved = try JSONEncoder().encode(snapshot)

        XCTAssertEqual(try JSONDecoder().decode(UsageSnapshot.self, from: saved), snapshot)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        var reports = try XCTUnwrap(object["reports"] as? [[String: Any]])
        reports[0].removeValue(forKey: "emailDomain")
        object["reports"] = reports
        let older = try JSONDecoder().decode(UsageSnapshot.self, from: JSONSerialization.data(withJSONObject: object))

        XCTAssertNil(older.reports[0].emailDomain)
        XCTAssertEqual(older.reports[0].privateDisplayLabel, "person@suresofttech.com")
    }

    func testABadgeNamesACompanyOnlyWhileIdentifiersAreRevealed() throws {
        let snapshot = try decode([
            ["accountId": "a1", "email": "person@suresofttech.com"],
            ["accountId": "a2", "email": "Person@GMail.com"],
            ["accountId": "a3", "email": "person@kakao.com"],
            ["accountId": "a4", "email": "person@naver.com"],
            ["accountId": "a5", "email": "person@privaterelay.appleid.com"],
            ["accountId": "a6", "email": "person@icloud.com"],
            ["accountId": "a7", "email": "not-an-email"],
            ["accountId": "a8"]
        ])
        let accounts = try XCTUnwrap(snapshot.providerDetail(of: "anthropic", now: timestamp)).accounts

        XCTAssertEqual(accounts.map { $0.badgeCompany(revealingIdentifiers: false) }, [AccountCompany?](repeating: nil, count: 8))
        XCTAssertEqual(
            accounts.map { $0.badgeCompany(revealingIdentifiers: true) },
            [.suresoft, .gmail, .kakao, .naver, .apple, nil, nil, nil]
        )
    }

    @MainActor
    func testIdentifiersStartHiddenSoNoBadgeNamesACompanyUntilTheyAreRevealed() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("QuotabletTests-\(UUID().uuidString)", isDirectory: true)
        let store = UsageStore(persistence: AppPersistence(directoryURL: directory))
        let accounts = try detail([draft("a1", email: "person@suresofttech.com"), draft("a2", email: "person@gmail.com")]).accounts

        XCTAssertEqual(accounts.map { $0.badgeCompany(revealingIdentifiers: store.revealsIdentifiers) }, [nil, nil])
        store.setRevealsIdentifiers(true)
        XCTAssertEqual(accounts.map { $0.badgeCompany(revealingIdentifiers: store.revealsIdentifiers) }, [.suresoft, .gmail])
        store.setRevealsIdentifiers(false)
        XCTAssertEqual(accounts.map { $0.badgeCompany(revealingIdentifiers: store.revealsIdentifiers) }, [nil, nil])
    }

    func testSeveralAccountsOfOneCompanyKeepTheirOwnNumbersThroughUrgencySorting() throws {
        let page = try detail([
            draft("a1", email: "one@suresofttech.com", remaining: 70),
            draft("a2", email: "two@gmail.com", status: .exhausted, remaining: 0),
            draft("a3", email: "three@SURESOFTTECH.com", status: .nearLimit, remaining: 8),
            draft("a4", email: "four@example.invalid", remaining: 10),
            draft("a5", email: "five@suresofttech.com", remaining: 90)
        ])

        XCTAssertEqual(page.accounts.map(\.number), [1, 2, 3, 4, 5])
        XCTAssertEqual(page.accountsByUrgency.map(\.number), [2, 3, 4, 1, 5])
        XCTAssertEqual(
            page.accountsByUrgency.map { $0.badgeCompany(revealingIdentifiers: true) },
            [.gmail, .suresoft, nil, .suresoft, .suresoft]
        )
        XCTAssertEqual(page.accountsByUrgency.filter { $0.badgeCompany(revealingIdentifiers: true) == .suresoft }.map(\.number), [3, 1, 5])
        XCTAssertEqual(page.accountsByUrgency.filter { $0.badgeCompany(revealingIdentifiers: true) == .gmail }.map(\.number), [2])
        XCTAssertEqual(page.accountsByUrgency.compactMap { $0.badgeCompany(revealingIdentifiers: false) }, [])
    }

    func testTheSpokenLabelCarriesTheBrandAndTheNumberOnlyWhenTheBadgeShowsThemAndNeverBeforeTheyAreRevealed() throws {
        let accounts = try detail([
            draft("a1", email: "person@gmail.com"),
            draft("a2", email: "Person@SureSoftTech.com"),
            draft("a3", email: "person@privaterelay.appleid.com"),
            draft("a4", email: "person@icloud.com")
        ]).accounts
        let shown: [(index: Int, label: String, company: AccountCompany)] = [
            (0, "person@gmail.com", .gmail),
            (1, "Person@SureSoftTech.com", .suresoft),
            (2, "person@privaterelay.appleid.com", .apple)
        ]

        for (index, label, company) in shown {
            let account = accounts[index]
            let alias = UsageFormatting.accountAlias(account.number)
            let plain = account.accessibilityLabel(accountLabel: alias, now: timestamp)
            let hidden = account.accessibilityLabel(
                accountLabel: alias,
                now: timestamp,
                company: account.badgeCompany(revealingIdentifiers: false)
            )
            let revealed = account.accessibilityLabel(
                accountLabel: label,
                now: timestamp,
                company: account.badgeCompany(revealingIdentifiers: true)
            )
            let details = String(plain.dropFirst("\(alias), ".count))

            // Hidden, the label is the plain number's and holds no brand, domain or address.
            XCTAssertEqual(hidden, plain)
            XCTAssertTrue(hidden.hasPrefix("\(alias), "))
            for named in AccountCompany.allCases {
                XCTAssertFalse(hidden.lowercased().contains(named.displayName.lowercased()), hidden)
                XCTAssertFalse(hidden.lowercased().contains(named.emailDomain), hidden)
            }
            XCTAssertFalse(hidden.lowercased().contains(label.lowercased()), hidden)

            // Revealed, the label names the account, then the badge's brand, role and number, and keeps what the plain label says.
            XCTAssertTrue(revealed.hasPrefix("\(label), "), revealed)
            XCTAssertTrue(revealed.contains(company.spokenBadge(number: account.number)), revealed)
            XCTAssertTrue(revealed.contains(details), revealed)
            XCTAssertNotEqual(revealed, plain)
        }
        let unlisted = accounts[3]
        XCTAssertNil(unlisted.badgeCompany(revealingIdentifiers: true))
        XCTAssertEqual(
            unlisted.accessibilityLabel(accountLabel: "person@icloud.com", now: timestamp, company: unlisted.badgeCompany(revealingIdentifiers: true)),
            unlisted.accessibilityLabel(accountLabel: "person@icloud.com", now: timestamp)
        )
    }

    // OMP's usage JSON with one report for each entry. An entry is that report's metadata, and nil leaves the metadata out.
    private func decode(_ metadata: [[String: String]?]) throws -> UsageSnapshot {
        let reports: [[String: Any]] = metadata.map { metadata in
            var report: [String: Any] = ["provider": "anthropic", "fetchedAt": 1_800_000_000_000, "limits": [Any]()]
            if let metadata { report["metadata"] = metadata }
            return report
        }
        let payload = try JSONSerialization.data(withJSONObject: ["generatedAt": 1_800_000_000_000, "reports": reports] as [String: Any])
        return try OMPClient.decode(payload)
    }

    private func detail(_ drafts: [UsageReportDraft]) throws -> ProviderDetail {
        try XCTUnwrap(UsageSnapshot(generatedAt: timestamp, reportDrafts: drafts).providerDetail(of: "anthropic", now: timestamp))
    }

    // One account with one weekly quota, as OMP reports it, whose email names the domain the badge may read.
    private func draft(_ accountID: String, email: String?, status: UsageLimitStatus = .available, remaining: Double = 70) -> UsageReportDraft {
        UsageReportDraft(
            provider: "anthropic",
            sourceAccount: SourceAccountIdentity(accountID: accountID, organizationID: nil, projectID: nil),
            privateDisplayLabel: email,
            emailDomain: AccountEmail.domain(of: email),
            fetchedAt: timestamp,
            resetCredits: nil,
            quotas: [
                UsageQuotaDraft(
                    id: "weekly",
                    label: "Claude 7 Day",
                    scope: nil,
                    window: QuotaWindow(identity: QuotaWindowIdentity(id: "7d"), label: "7 Day", durationMilliseconds: 604_800_000, resetLabel: nil),
                    amount: UsageAmount(
                        used: 100 - remaining,
                        limit: 100,
                        remaining: remaining,
                        usedFraction: (100 - remaining) / 100,
                        remainingFraction: remaining / 100,
                        unit: .percent
                    ),
                    status: status,
                    resetsAt: nil
                )
            ]
        )
    }
}

final class CompanyBadgeRenderingTests: XCTestCase {
    @MainActor
    func testEveryFaceOfTheBadgeKeepsTheFootprintOfThePlainNumber() {
        func size(_ chip: AccountChip) -> CGSize {
            NSHostingView(rootView: chip).fittingSize
        }

        let footprint = CGSize(width: 24, height: 24)
        XCTAssertEqual(size(AccountChip(number: 3, company: nil, color: .blue, isStale: false)), footprint)
        XCTAssertEqual(size(AccountChip(number: 12, company: nil, color: .blue, isStale: true)), footprint)
        for company in AccountCompany.allCases {
            for number in [3, 12] {
                for isStale in [false, true] {
                    XCTAssertEqual(
                        size(AccountChip(number: number, company: company, color: .purple, isStale: isStale)),
                        footprint,
                        "\(company) \(number) \(isStale)"
                    )
                }
            }
        }
    }

    // Only a logo's plate is pure white, so a mapped badge that finds no logo and falls back to the plain number shows none.
    @MainActor
    func testAMappedBadgeDrawsItsLogoOnAWhitePlateAndAPlainBadgeDoesNot() throws {
        XCTAssertEqual(try whitePixels(of: AccountChip(number: 3, company: nil, color: .blue, isStale: false)), 0)
        for company in AccountCompany.allCases {
            for isStale in [false, true] {
                let white = try whitePixels(of: AccountChip(number: 3, company: company, color: .blue, isStale: isStale))

                XCTAssertGreaterThan(white, 200, "\(company) \(isStale)")
            }
        }
    }

    // The opaque pure white pixels of the chip rendered at twice its size.
    @MainActor
    private func whitePixels(of chip: AccountChip) throws -> Int {
        let renderer = ImageRenderer(content: chip)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage)
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try XCTUnwrap(context.data)
        let bytes = UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: context.bytesPerRow * image.height)
        var white = 0
        for row in 0..<image.height {
            for column in 0..<image.width {
                let offset = row * context.bytesPerRow + column * 4
                if bytes[offset] > 250, bytes[offset + 1] > 250, bytes[offset + 2] > 250, bytes[offset + 3] == 255 { white += 1 }
            }
        }
        return white
    }
}
