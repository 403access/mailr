import SwiftUI
import WebKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Renders message HTML in a locked-down web view: JavaScript is disabled,
/// remote resources are blocked unless explicitly allowed, and link clicks
/// open in the user's browser.
enum HTMLMessageDocument {
    static func make(html: String, allowRemote: Bool) -> String {
        let contentSecurityPolicy: String
        if allowRemote {
            contentSecurityPolicy = "default-src 'none'; img-src data: https: http:; media-src data: https: http:; style-src 'unsafe-inline' https: http:; font-src data: https:;"
        } else {
            contentSecurityPolicy = "default-src 'none'; img-src data:; media-src data:; style-src 'unsafe-inline'; font-src data:;"
        }

        let fragment = bodyFragment(from: html)

        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy)">
        <meta name="color-scheme" content="light dark">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          :root { color-scheme: light dark; }
          html, body { margin: 0; padding: 0; background: transparent; }
          body {
            padding: 18px 22px 28px;
            font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
            font-size: 14px;
            line-height: 1.62;
            color: #1d1d1f;
            overflow-wrap: anywhere;
            -webkit-text-size-adjust: 100%;
          }
          img { max-width: 100%; height: auto; }
          table { max-width: 100%; }
          a { color: #0a66d6; }
          blockquote {
            border-left: 3px solid #d6d6d8;
            margin: 12px 0;
            padding-left: 14px;
            color: #555;
          }
          pre, code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12.5px; }
          pre { background: rgba(127,127,127,0.12); padding: 10px; border-radius: 6px; overflow-x: auto; }
          @media (prefers-color-scheme: dark) {
            body { color: #e8e8ea; }
            a { color: #6cb0ff; }
            blockquote { border-color: #4a4a4d; color: #b0b0b4; }
          }
        </style>
        </head>
        <body>\(fragment)</body>
        </html>
        """
    }

    private static func bodyFragment(from html: String) -> String {
        guard html.range(of: "<body", options: .caseInsensitive) != nil else {
            return html
        }
        guard let open = html.range(of: "<body[^>]*>", options: [.regularExpression, .caseInsensitive]),
              let close = html.range(of: "</body\\s*>", options: [.regularExpression, .caseInsensitive]),
              open.upperBound <= close.lowerBound else {
            return html
        }
        return String(html[open.upperBound..<close.lowerBound])
    }
}

@MainActor
final class HTMLNavigationCoordinator: NSObject, WKNavigationDelegate {
    var loadedDocument: String?

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard navigationAction.navigationType == .linkActivated,
              let url = navigationAction.request.url else {
            return .allow
        }

        if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
            URLOpener.open(url)
        }
        return .cancel
    }
}

#if os(macOS)

struct HTMLMessageView: NSViewRepresentable {
    let html: String
    let allowRemote: Bool
    let colorScheme: ColorScheme

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsMagnification = true
        webView.underPageBackgroundColor = .clear
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        webView.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        let document = HTMLMessageDocument.make(html: html, allowRemote: allowRemote)
        guard context.coordinator.loadedDocument != document else { return }
        context.coordinator.loadedDocument = document
        webView.loadHTMLString(document, baseURL: nil)
    }

    func makeCoordinator() -> HTMLNavigationCoordinator {
        HTMLNavigationCoordinator()
    }
}

#else

struct HTMLMessageView: UIViewRepresentable {
    let html: String
    let allowRemote: Bool
    let colorScheme: ColorScheme

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        webView.overrideUserInterfaceStyle = colorScheme == .dark ? .dark : .light
        let document = HTMLMessageDocument.make(html: html, allowRemote: allowRemote)
        guard context.coordinator.loadedDocument != document else { return }
        context.coordinator.loadedDocument = document
        webView.loadHTMLString(document, baseURL: nil)
    }

    func makeCoordinator() -> HTMLNavigationCoordinator {
        HTMLNavigationCoordinator()
    }
}

#endif
