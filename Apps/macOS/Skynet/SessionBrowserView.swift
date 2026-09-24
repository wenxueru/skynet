import SwiftUI
import WebKit

struct SessionBrowserView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var browser = SessionBrowserController()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { browser.webView.goBack() } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(!browser.canGoBack)
                Button { browser.webView.goForward() } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(!browser.canGoForward)
                TextField("Enter a URL", text: $browser.address)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { browser.navigate(browser.address) }
                Button { browser.webView.reload() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                Button("Close") { dismiss() }
            }
            .padding(10)
            if let error = browser.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
            BrowserWebView(webView: browser.webView)
        }
        .frame(minWidth: 720, minHeight: 480)
    }
}

private struct BrowserWebView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}

@MainActor
private final class SessionBrowserController: NSObject, ObservableObject, WKNavigationDelegate {
    @Published var address = ""
    @Published var errorMessage: String?
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    let webView = WKWebView(frame: .zero)

    override init() {
        super.init()
        webView.navigationDelegate = self
    }

    func navigate(_ input: String) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let candidate = text.contains("://") ? text : "https://\(text)"
        guard let url = URL(string: candidate),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            errorMessage = "Enter a valid HTTP or HTTPS URL."
            return
        }
        errorMessage = nil
        address = url.absoluteString
        webView.load(URLRequest(url: url))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let url = webView.url { address = url.absoluteString }
        errorMessage = nil
        updateNavigationState()
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        errorMessage = error.localizedDescription
        updateNavigationState()
    }

    private func updateNavigationState() {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
    }
}
