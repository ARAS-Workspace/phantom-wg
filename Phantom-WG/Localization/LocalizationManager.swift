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
    }

    @ObservationIgnored static let shared = LocalizationManager()

    var current: Language {
        didSet {
            guard current != oldValue else { return }
            UserDefaults.standard.set(current.rawValue, forKey: "app_language")
            loadStrings()
        }
    }

    /// Observed so that views calling `t(_:)` re-render when the dictionary
    /// is reloaded after a language switch. Without this, `@Observable` would
    /// only track `current`, and callers would see stale translations because
    /// `t(_:)` reads `strings` internally (not `current`).
    private var strings: [String: String] = [:]

    init() {
        // Resolve initial language: saved preference → device locale → English.
        //
        // The middle step reads `Locale.current`, which is the *app's*
        // locale — the user's preferred languages intersected with the
        // ones the bundle declares — not the device's raw setting. It
        // can only ever answer `tr` while `tr.lproj` ships: drop that
        // folder and this branch goes quiet without a line of this file
        // changing. The flag still wins either way, because a language
        // the user has picked once is saved and read first.
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

    /// The privacy policy is published as two plain-text documents, one
    /// per language. The app links to the one matching what it is
    /// currently showing rather than handing the reader a language
    /// switch to solve first — which is why this lives here, beside the
    /// language itself, and not in the views that draw the link.
    var privacyPolicyURL: URL? {
        switch current {
        case .tr: return URL(string: "https://www.phantom.tc/privacy-policy-tr.txt")
        case .en: return URL(string: "https://www.phantom.tc/privacy-policy.txt")
        }
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

    private func loadStrings() {
        guard let url = Bundle.main.url(forResource: current.rawValue, withExtension: "json", subdirectory: "translations"),
              let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: String].self, from: data)
        else { return }
        strings = dict
    }
}
