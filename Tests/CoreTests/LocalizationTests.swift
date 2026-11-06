import Foundation
import Testing
@testable import TonkunstCore

struct LocalizationTests {
    @Test func germanResourcesResolveComputedLabelsAndPlurals() throws {
        let url = try #require(AppLocalization.bundle.url(forResource: "de", withExtension: "lproj"))
        let german = try #require(Bundle(url: url))
        #expect(german.localizedString(forKey: "Offline Mode", value: nil, table: nil) == "Offline-Modus")
        #expect(german.localizedString(forKey: "Unknown Artist", value: nil, table: nil) == "Unbekannter Interpret")
        let one = String(localized: "\(1) older downloads remain in Files because their account could not be identified.",
                         bundle: german, locale: Locale(identifier: "de"))
        let two = String(localized: "\(2) older downloads remain in Files because their account could not be identified.",
                         bundle: german, locale: Locale(identifier: "de"))
        #expect(one.hasPrefix("1 älterer Download bleibt"))
        #expect(two.hasPrefix("2 ältere Downloads bleiben"))
    }
}
