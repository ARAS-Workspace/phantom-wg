import Foundation

@Observable
final class LocalizationManager {

    enum Language: String, CaseIterable, Identifiable {
        case tr, en
        var id: String { rawValue }

        var flag: String {
            switch self {
            case .tr: return "\u{1F1F9}\u{1F1F7}"
            case .en: return "\u{1F1FA}\u{1F1F8}"
            }
        }

        var displayName: String {
            switch self {
            case .tr: return "Türkçe"
            case .en: return "English"
            }
        }
    }

    @ObservationIgnored static let shared = LocalizationManager()

    var current: Language {
        didSet {
            guard current != oldValue else { return }
            UserDefaults.standard.set(current.rawValue, forKey: "app_language")
            loadStrings()
        }
    }

    private var strings: [String: String] = [:]

    init() {
        if let saved = UserDefaults.standard.string(forKey: "app_language"),
           let lang = Language(rawValue: saved) {
            self.current = lang
        } else if Locale.current.language.languageCode?.identifier == "tr" {
            self.current = .tr
        } else {
            self.current = .en
        }
        loadStrings()
    }

    func t(_ key: String) -> String {
        strings[key] ?? key
    }

    func t(_ key: String, _ args: CVarArg...) -> String {
        let template = strings[key] ?? key
        return String(format: template, arguments: args)
    }

    private func loadStrings() {
        guard let url = Bundle.main.url(forResource: current.rawValue, withExtension: "json", subdirectory: "translations"),
              let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: String].self, from: data)
        else { return }
        strings = dict
    }
}
