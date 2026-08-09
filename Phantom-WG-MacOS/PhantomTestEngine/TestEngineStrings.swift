#if DEBUG
import Foundation

/// Self-contained TR/EN strings for the DEBUG harness CHROME only — the
/// shell that wraps the experience (menu entry, panel title, buttons, the
/// config gate). Kept out of the app's translations catalog on purpose,
/// resolved from `LocalizationManager.current`.
///
/// Workflows are NOT localized: their names, step titles and log lines
/// are authored in English inside the workflow. Localization wraps only
/// the interface.
struct TestEngineStrings {
    let menuEntry: String
    let navTitle: String
    let close: String
    let run: String
    let copy: String
    let save: String
    let emptyTitle: String
    let emptyDesc: String
    let gateTitle: String
    let gateIntro: String
    let gateReturn: String

    static func of(_ language: LocalizationManager.Language) -> TestEngineStrings {
        switch language {
        case .tr: return .tr
        default:  return .en
        }
    }

    static let tr = TestEngineStrings(
        menuEntry: "Test Motoru",
        navTitle: "Test Motoru",
        close: "Kapat",
        run: "Çalıştır",
        copy: "Kopyala",
        save: "Kaydet",
        emptyTitle: "Henüz koşum yok",
        emptyDesc: "Çalıştır'a basın.",
        gateTitle: "Test Yapılandırmaları Gerekli",
        gateIntro: "Bu alana ulaşmak için iki yapılandırmaya ihtiyacınız var.",
        gateReturn:"Bu isimde yapılandırmaları içe aktardıktan sonra buraya dönmelisiniz."
    )

    static let en = TestEngineStrings(
        menuEntry: "Test Engine",
        navTitle: "Test Engine",
        close: "Close",
        run: "Run",
        copy: "Copy",
        save: "Save",
        emptyTitle: "No run yet",
        emptyDesc: "Press Run.",
        gateTitle: "Test Configurations Required",
        gateIntro: "You need two configurations to reach this area.",
        gateReturn: "Import configurations with these names, then return here."
    )
}
#endif
