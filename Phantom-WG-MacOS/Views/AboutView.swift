import SwiftUI
import WebKit

struct AboutView: View {
    @EnvironmentObject private var loc: LocalizationManager

    var body: some View {
        AboutWebView(fileName: loc.aboutHTMLFileName)
            .navigationTitle(loc.t("about_title"))
            .ignoresSafeArea(edges: .bottom)
    }
}

struct AboutWebView: NSViewRepresentable {
    let fileName: String

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        loadHTML(into: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        loadHTML(into: webView)
    }

    private func loadHTML(into webView: WKWebView) {
        guard let url = Bundle.main.url(forResource: fileName, withExtension: "html",
                                         subdirectory: "pages/about-us") else { return }
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }
}
