# Capturing WebView traffic

`NectoWebViewCapture` shows what the `WKWebView` pages in your app say, in panels you
already have:

| What | Where it appears |
| --- | --- |
| `fetch` and `XMLHttpRequest` from a page | **Network**, with a `WebView` badge |
| A page posting to an app message handler, and the handler's reply | **Event Log**, category `WebView` |
| The app running JavaScript in a page (`evaluateJavaScript`, `callAsyncJavaScript`) | **Event Log**, category `WebView` |

You change native code in one place. Web code does not change: Necto injects its own
script into each page at runtime.

> **For coding agents.** Apply this guide in the app's repository by following
> [Steps](#steps) in order. Do not edit web code: HTML, JavaScript, TypeScript, or
> anything else the WebView loads. Keep every Necto call inside `#if DEBUG`. Finish with
> [Verify](#verify) and [Done when](#done-when).

## Before you start

- The app is set up for Necto as described in [setup.md](setup.md), and its start-up
  code calls `NectoSDK.start()`.
- The app's pages run in `WKWebView`. `SFSafariViewController` and
  `ASWebAuthenticationSession` are separate browsers and are not captured.

## Steps

### 1. Find the Necto start-up code

Search the app for `NectoSDK.start(`. If it is missing, set up Necto with
[setup.md](setup.md) first, then continue.

### 2. Keep the network and events plugins as values

`install` takes the two plugins that receive what it captures. If the start-up code
registers them inline, give them names:

```swift
// Before
NectoSDK.register(URLSessionNetworkPlugin())
NectoSDK.register(NectoEventsPlugin())

// After
let network = URLSessionNetworkPlugin()
let events = NectoEventsPlugin()
NectoSDK.register(network)
NectoSDK.register(events)
```

- An app that registers `NectoNetworkPlugin` instead of `URLSessionNetworkPlugin` passes
  that plugin where the examples below pass `network.network`.
- If either plugin is not registered yet, register it. Register each one only once.

### 3. Install the capture

Add the import, and the call inside the same `#if DEBUG` block, before
`NectoSDK.start()`:

```swift
import NectoWebViewCapture

#if DEBUG
let network = URLSessionNetworkPlugin()
let events = NectoEventsPlugin()
NectoSDK.register(network)
NectoSDK.register(events)
NectoWebViewCapture.install(network: network.network, events: events)
NectoSDK.start()
#endif
```

`install` captures only the WebViews created after it runs. Search for `WKWebView(` and
`WKWebViewConfiguration(`, and for WebViews in storyboards and nibs, and confirm that
none of them is created before this code. Start-up code in the `App` initializer or in
`application(_:didFinishLaunchingWithOptions:)` normally comes first. If something
creates a WebView earlier, a preloading service for example, move the Necto block
before it.

### 4. Check how the app's bridge works

Search the app's native code for each pattern and follow the matching row. An app can
use more than one.

| Search for | Bridge | What to do |
| --- | --- | --- |
| `WKScriptMessageHandler`, `.add(` on a `WKUserContentController` | Message handler | Nothing. Captured automatically. |
| `WKScriptMessageHandlerWithReply`, `addScriptMessageHandler(` | Message handler with reply | Nothing. Captured automatically, replies included. |
| `evaluateJavaScript(`, `callAsyncJavaScript(` | App → page calls | Nothing. Captured automatically. |
| `decidePolicyFor navigationAction` checking a custom scheme or host | URL-scheme bridge | Add the line in [URL-scheme bridges](#url-scheme-bridges). |
| `WebViewJavascriptBridge`, `WKWebViewJavascriptBridge` or a similar library | Library bridge | See [Bridge libraries](#bridge-libraries). |

Do not modify the sources of third-party libraries.

#### URL-scheme bridges

Where the app's navigation delegate recognizes a bridge URL, report it before handling
it:

```swift
func webView(_ webView: WKWebView,
             decidePolicyFor navigationAction: WKNavigationAction,
             decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    if let url = navigationAction.request.url, url.scheme == "myapp" {
        #if DEBUG
        events.report(NectoEvent(
            level: .info,
            tag: "WebView",
            message: "web → app · \(url.host ?? url.absoluteString)",
            detail: ["url": url.absoluteString, "page": webView.url?.absoluteString ?? ""]
        ))
        #endif
        // The app's existing handling continues here.
    }
    // …
}
```

`events` is the instance registered in step 2. If it cannot be reached from the
delegate, keep a reference to it where the app's other debug-only code can read it. Use
the `WebView` tag and the `web → app · …` form, so these lines sit with the captured
ones.

#### Bridge libraries

Check how the library carries messages:

- Through a message handler (`window.webkit.messageHandlers`): captured automatically.
- Through URL interception: the library usually collects queued messages with
  `evaluateJavaScript`, so they appear as `app → web · evaluateJavaScript` events whose
  `result` holds the queue. To see one line per message, report from the handlers the
  app registers with the library, in the form shown above.

### 5. Build

Build the Debug configuration. Build Release too, and confirm that it compiles with
every Necto call still inside `#if DEBUG`.

## Verify

Run a Debug build on a simulator with the Necto app open. Open a screen with a WebView
and use it until the page sends a request and talks to the app.

In the Necto app:

- **Network** lists the page's requests with a `WebView` badge.
- **Event Log**, filtered to the `WebView` category, lists `web → app · …` and
  `app → web · …` lines.

With `necto` (`necto-cli` for a development build of Necto), find the device and app:

```bash
necto device list --json
```

Then read the records. At least one should have `"source": "WebView"`:

```bash
necto plugin send network-logger records.list --device <device-id> --app <bundle-id> --input '{"limit":100}'
```

And the events. At least one should have `"tag": "WebView"`:

```bash
necto plugin send event-log events.list --device <device-id> --app <bundle-id> --input '{"limit":100}'
```

## Done when

- [ ] `NectoWebViewCapture.install(network:events:)` runs inside `#if DEBUG`, before
      `NectoSDK.start()` and before any `WKWebView` is created.
- [ ] The plugins passed to `install` are the registered instances, each registered once.
- [ ] Every URL-scheme bridge found in step 4 reports with the `WebView` tag.
- [ ] No web code changed.
- [ ] Debug and Release both build.
- [ ] Network shows WebView records, and Event Log shows `WebView` events.

## What it cannot see

- Page navigations and what the browser loads by itself: HTML documents, images, CSS,
  `<script>` files and fonts.
- Requests made inside a Service Worker.
- Headers the browser adds, such as `Cookie` and `User-Agent`.
- Response headers of cross-origin requests that CORS does not expose.

Safari Web Inspector shows all of these. In Debug builds, set
`webView.isInspectable = true` (iOS 16.4 and later) and open the page from Safari's
Develop menu.

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| Nothing from any WebView | `install` ran after the WebView was created, or the build being run is not Debug. |
| Requests appear, bridge messages do not | The bridge uses a URL scheme or a library. See step 4. |
| A page behaves differently with capture on | The page checks whether `fetch` is the browser's own. Call `NectoWebViewCapture.uninstall()` for that run, and report the page. |
| A request body shows only its size | The body was `FormData`, a `Blob` or binary data. Only text bodies are recorded. |
| A request shows no body | The body was a stream, or travelled inside a `Request` object. Neither is read, so the page's upload is never consumed twice. |
| Capture stops for a WebView after it is set up | The app calls `removeAllUserScripts()` or `removeAllScriptMessageHandlers()` on the WebView's content controller after creating it, which removes Necto's script and receiver too. |

## Turning it off

`NectoWebViewCapture.uninstall()` stops reporting. Pages that are already open keep
working normally.
