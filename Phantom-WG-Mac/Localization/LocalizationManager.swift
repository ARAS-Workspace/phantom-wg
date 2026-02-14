import Foundation

class LocalizationManager: ObservableObject {

    enum Language: String, CaseIterable, Identifiable {
        case tr, en
        var id: String { rawValue }

        var flag: String {
            switch self {
            case .tr: return "\u{1F1F9}\u{1F1F7}"
            case .en: return "\u{1F1FA}\u{1F1F8}"
            }
        }
    }

    static let shared = LocalizationManager()

    @Published var current: Language {
        didSet {
            guard current != oldValue else { return }
            UserDefaults.standard.set(current.rawValue, forKey: "app_language")
            loadStrings()
        }
    }

    private var strings: [String: String] = [:]

    init() {
        // 1. Saved preference
        if let saved = UserDefaults.standard.string(forKey: "app_language"),
           let lang = Language(rawValue: saved) {
            _current = Published(initialValue: lang)
        }
        // 2. Device locale
        else if Locale.current.language.languageCode?.identifier == "tr" {
            _current = Published(initialValue: .tr)
        }
        // 3. Default English
        else {
            _current = Published(initialValue: .en)
        }
        loadStrings()
    }

    /// Simple key lookup.
    func t(_ key: String) -> String {
        strings[key] ?? key
    }

    /// Key lookup with format arguments (%d, %@, etc.).
    func t(_ key: String, _ args: CVarArg...) -> String {
        let template = strings[key] ?? key
        return String(format: template, arguments: args)
    }

    /// Returns the HTML file name for the current language (without extension).
    var aboutHTMLFileName: String {
        current.rawValue
    }

    private func loadStrings() {
        guard let url = Bundle.main.url(forResource: current.rawValue, withExtension: "json", subdirectory: "translations"),
              let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: String].self, from: data)
        else { return }
        strings = dict
    }
}
