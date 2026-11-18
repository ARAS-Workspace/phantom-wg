// Test Engine: Interface Strings
//
// TR/EN strings for the test engine's own screen and its toolbar button,
// selected off `LocalizationManager.Language`.
//
// Carried here rather than in the shipped localization catalogue: this
// surface is `#if DEBUG` only, so its text never ships and has no
// business growing the product's translation files.

#if DEBUG
import Foundation

struct TestEngineStrings {
    let menuEntry: String
    let navTitle: String
    let close: String
    let run: String
    let stop: String
    let copy: String
    let share: String
    let emptyTitle: String
    let emptyDesc: String
    let gateTitle: String
    let gateIntro: String
    let gateReal: String
    let gateElsewhere: String
    let gateMissing: String

    static func of(_ language: LocalizationManager.Language) -> TestEngineStrings {
        switch language {
        case .tr: return .tr
        case .en: return .en
        }
    }

    static let tr = TestEngineStrings(
        menuEntry: "Test Motoru",
        navTitle: "Test Motoru",
        close: "Kapat",
        run: "Çalıştır",
        stop: "Durdur",
        copy: "Kopyala",
        share: "Paylaş",
        emptyTitle: "Henüz koşum yok",
        emptyDesc: "Çalıştır'a basın.",
        gateTitle: "Canlı tüneller",
        gateIntro: "Canlı aileler bu iki tünelle gerçek uzantıda koşar. Biri eksikse atlanır.",
        gateReal: "gerçek uzantı",
        gateElsewhere: "gerçek uzantıda değil",
        gateMissing: "listede yok"
    )

    static let en = TestEngineStrings(
        menuEntry: "Test Engine",
        navTitle: "Test Engine",
        close: "Close",
        run: "Run",
        stop: "Stop",
        copy: "Copy",
        share: "Share",
        emptyTitle: "No run yet",
        emptyDesc: "Press Run.",
        gateTitle: "Live tunnels",
        gateIntro: "The live families run on the real extension with these two tunnels. With either missing, they are skipped.",
        gateReal: "real extension",
        gateElsewhere: "not on the real extension",
        gateMissing: "not listed"
    )
}
#endif
