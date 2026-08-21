#if DEBUG
import Foundation

struct TestEngineStrings {
    let menuEntry: String
    let navTitle: String
    let close: String
    let run: String
    let stop: String
    let copy: String
    let save: String
    let ok: String
    let saveErrorTitle: String
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
        stop: "Durdur",
        copy: "Kopyala",
        save: "Kaydet",
        ok: "Tamam",
        saveErrorTitle: "Kaydetme Hatası",
        emptyTitle: "Henüz koşum yok",
        emptyDesc: "Çalıştır'a basın.",
        gateTitle: "Test Yapılandırmaları Gerekli",
        gateIntro: "Bu alana ulaşmak için iki yapılandırmaya ihtiyacınız var.",
        gateReturn: "Bu isimde yapılandırmaları içe aktardıktan sonra buraya dönmelisiniz."
    )

    static let en = TestEngineStrings(
        menuEntry: "Test Engine",
        navTitle: "Test Engine",
        close: "Close",
        run: "Run",
        stop: "Stop",
        copy: "Copy",
        save: "Save",
        ok: "OK",
        saveErrorTitle: "Save Failed",
        emptyTitle: "No run yet",
        emptyDesc: "Press Run.",
        gateTitle: "Test Configurations Required",
        gateIntro: "You need two configurations to reach this area.",
        gateReturn: "Import configurations with these names, then return here."
    )
}
#endif
