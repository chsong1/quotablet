import Foundation

// The host of an email address, read the one way the whole app agrees on.
enum AccountEmail {
    // The host after the address's single "@", in lowercase ASCII. Nil when there is no address to read: no text, no "@" or more than one,
    // nothing before it that `isLocalPart` accepts, or a host that is not a dotted name of ASCII letters, digits and hyphens. An address
    // Quotablet cannot read gets no domain, so it is never taken for one that Quotablet can.
    static func domain(of email: String?) -> String? {
        guard let email else { return nil }
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = address.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, isLocalPart(parts[0]) else { return nil }
        return hostName(String(parts[1]))
    }

    // The host in lowercase, or nil when the text is not a dotted ASCII name. The text must already be all ASCII before its case is folded,
    // so a letter of another script that folds into an ASCII one never passes for it.
    static func hostName(_ text: String) -> String? {
        let bytes = text.utf8
        guard bytes.count <= 253, bytes.allSatisfy({ $0 < 0x80 }) else { return nil }
        let host = text.lowercased()
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ isHostLabel($0) }) else { return nil }
        return host
    }

    // The text before the "@" when it is a conventional local part, the "dot-atom" of RFC 5322: atoms joined by single dots, as in
    // "first.last+tag". An atom is one or more ASCII letters, digits and symbols from !#$%&'*+-/=?^_`{|}~. A leading, trailing or
    // doubled dot, a quote, an angle or square bracket, a parenthesis, a space, a control and a character outside ASCII are not part of
    // one. So a quoted address such as "first last"@host, or one in angle brackets, is not read and gets no domain.
    private static func isLocalPart(_ text: Substring) -> Bool {
        let bytes = text.utf8
        guard !bytes.isEmpty, bytes.first != 0x2E, bytes.last != 0x2E else { return false }
        var previous: UInt8 = 0
        for byte in bytes {
            guard (byte == 0x2E && previous != 0x2E) || isAtomByte(byte) else { return false }
            previous = byte
        }
        return true
    }

    // An ASCII letter, a digit or one of the symbols RFC 5322 allows in an atom. The dot is not one: it only joins atoms.
    private static func isAtomByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: true
        default: "!#$%&'*+-/=?^_`{|}~".utf8.contains(byte)
        }
    }

    private static func isHostLabel(_ label: Substring) -> Bool {
        let bytes = label.utf8
        guard (1...63).contains(bytes.count), bytes.first != 0x2D, bytes.last != 0x2D else { return false }
        return bytes.allSatisfy { ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2D }
    }
}

// A company whose logo can stand on an account's badge, and what that logo says about the account. An account matches one by the exact domain
// of its email address, as in "person@suresofttech.com". An unlisted domain, a prefix, a suffix or a subdomain of a listed one, and an address
// that cannot be read all match nothing, and their badges stay numbers.
enum AccountCompany: String, CaseIterable, Sendable {
    case suresoft
    case gmail
    case kakao
    case naver
    case apple

    // What the logo says about the account. Only a company's own domain says who employs its user. A mail provider's or a privacy relay's
    // logo says where the address is hosted and nothing about an employer.
    enum Role: Sendable {
        case employer
        case mailProvider
        case privateRelay

        // How a screen reader names the role.
        var spokenName: String {
            switch self {
            case .employer: "company"
            case .mailProvider: "email provider"
            case .privateRelay: "private email relay"
            }
        }
    }

    // In lowercase, as `AccountEmail` reads a host. Only these domains are evidenced, so a provider's other domains, such as googlemail.com
    // or icloud.com, match nothing.
    var emailDomain: String {
        switch self {
        case .suresoft: "suresofttech.com"
        case .gmail: "gmail.com"
        case .kakao: "kakao.com"
        case .naver: "naver.com"
        case .apple: "privaterelay.appleid.com"
        }
    }

    var role: Role {
        switch self {
        case .suresoft: .employer
        case .gmail, .kakao, .naver: .mailProvider
        case .apple: .privateRelay
        }
    }

    // How a screen reader names the brand.
    var displayName: String {
        switch self {
        case .suresoft: "Suresoft"
        case .gmail: "Gmail"
        case .kakao: "Kakao"
        case .naver: "Naver"
        case .apple: "Apple"
        }
    }

    // What a screen reader says for the badge, such as "Gmail email provider, account 2". The role is part of it, so a mail provider's logo is
    // never taken for an employer's.
    func spokenBadge(number: Int) -> String {
        "\(displayName) \(role.spokenName), account \(number)"
    }

    // The logo's PNG in the app bundle, without its extension. The app reads it from the bundle and never from the network.
    var logoResource: String { "company-\(rawValue)" }

    // Nil unless the host is exactly one company's domain, whatever the case it was written in.
    init?(emailDomain: String?) {
        guard
            let host = emailDomain.flatMap(AccountEmail.hostName),
            let company = Self.allCases.first(where: { $0.emailDomain == host })
        else { return nil }
        self = company
    }
}

extension AccountDetail {
    // The company whose logo the account's badge may wear. The domain of an account's email is part of who it is, so the badge shows a logo only
    // while identifiers are revealed. While they are hidden every account gets its plain number, whatever its email says.
    func badgeCompany(revealingIdentifiers: Bool) -> AccountCompany? {
        guard revealingIdentifiers else { return nil }
        return AccountCompany(emailDomain: report.emailDomain)
    }
}
