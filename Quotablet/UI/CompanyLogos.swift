import AppKit

// The one kind of logo Quotablet ships: the mark of the company behind an account's email domain, whether its employer, its mail provider or its
// privacy relay, for that account's badge. Each is a PNG in the app bundle, read from there and never from the network. The logos of the AI
// providers stay files the user installs (`ProviderLogoCatalog`). Both kinds are drawn exactly as the file provides them.
enum CompanyLogos {
    // Any class of this module finds the bundle that holds its resources: the app, or the test bundle that compiles the same sources.
    private final class BundleLocator {}

    // Loaded once, on first use. A company whose file is missing or unreadable has no logo, and its badge stays a number.
    private static let logos: [AccountCompany: ProviderLogo] = {
        let bundle = Bundle(for: BundleLocator.self)
        var logos: [AccountCompany: ProviderLogo] = [:]
        for company in AccountCompany.allCases {
            guard let url = bundle.url(forResource: company.logoResource, withExtension: "png") else { continue }
            logos[company] = ProviderLogo(contentsOf: url)
        }
        return logos
    }()

    static func logo(for company: AccountCompany) -> ProviderLogo? {
        logos[company]
    }
}
