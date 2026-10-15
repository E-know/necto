//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import SwiftUI
import WebKit

/// A page that talks to the network and to the app, for WebView capture to show.
///
/// The page's requests appear in the Network plugin with a `WebView` badge, and its
/// messages to the app, the app's replies and the app's calls into the page appear in
/// the Event Log under `WebView`. The page is served from `LocalAPI`'s origin, so its
/// requests are same-origin and need no internet.
struct WebViewDemoView: View {
    @StateObject private var page = WebViewDemoPage()

    var body: some View {
        VStack(spacing: 0) {
            WebViewContainer(webView: page.webView)
            Divider()
            Button("Call the page from the app") {
                page.callPage()
            }
            .padding()
        }
        .navigationTitle("WebView")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Owns the WebView, so it outlives SwiftUI redrawing the container around it.
@MainActor
private final class WebViewDemoPage: ObservableObject {
    let webView: WKWebView
    private var calls = 0

    init() {
        let configuration = WKWebViewConfiguration()
        // A handler of its own rather than this object: the content controller keeps
        // its handlers alive, and this object keeps the WebView.
        configuration.userContentController.addScriptMessageHandler(
            ExampleBridge(),
            contentWorld: .page,
            name: "exampleBridge"
        )
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.loadHTMLString(Self.html, baseURL: URL(string: "\(LocalAPI.shared.origin)/webview"))
    }

    func callPage() {
        calls += 1
        webView.evaluateJavaScript("receiveFromApp('hello from the app, call \(calls)')", completionHandler: nil)
    }

    private static let html = """
    <!doctype html>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>WebView demo</title>
    <style>
      body { font: -apple-system-body; margin: 16px; }
      button { display: block; width: 100%; margin: 8px 0; padding: 12px; font: inherit; }
      pre { white-space: pre-wrap; }
    </style>
    <button onclick="getPosts()">fetch GET /posts</button>
    <button onclick="createPost()">fetch POST /posts</button>
    <button onclick="requestPost()">XMLHttpRequest GET /posts/1</button>
    <button onclick="askApp()">Message the app</button>
    <pre id="log"></pre>
    <script>
      const log = (line) => {
        const element = document.getElementById("log");
        element.textContent = line + "\\n" + element.textContent;
      };

      async function getPosts() {
        const response = await fetch("/posts");
        log(`GET /posts → ${response.status}`);
      }

      async function createPost() {
        const response = await fetch("/posts", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ title: "Necto", body: "Sent from a WebView" }),
        });
        log(`POST /posts → ${response.status}`);
      }

      function requestPost() {
        const request = new XMLHttpRequest();
        request.open("GET", "/posts/1");
        request.onloadend = () => log(`XHR /posts/1 → ${request.status}`);
        request.send();
      }

      async function askApp() {
        const reply = await window.webkit.messageHandlers.exampleBridge.postMessage({ action: "greet" });
        log(`The app replied ${JSON.stringify(reply)}`);
      }

      window.receiveFromApp = (message) => {
        log(`The app says: ${message}`);
        return "received";
      };
    </script>
    """
}

/// The app's side of the page's bridge: answers each message with a reply.
@MainActor
private final class ExampleBridge: NSObject, WKScriptMessageHandlerWithReply {
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor (Any?, String?) -> Void
    ) {
        replyHandler(["greeting": "Hello from the app"], nil)
    }
}

private struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}
