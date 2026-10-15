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
- No dependency changes. `NectoWebViewCapture` ships in the `NectoSDK` product the app
  already links. With Tuist, `.external(name: "NectoSDK")` brings it; do not add a
  separate product for it.
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
  `install` needs both: bridge messages go to the events plugin, requests to the
  network plugin.

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

`install` captures only what is set up after it runs: WebViews created later, and
message handlers registered later. Search for `WKWebView(`, `WKWebViewConfiguration(`
and `.add(` on a `WKUserContentController`, and for WebViews in storyboards and nibs,
and confirm that none of them runs before this code. Look at stored properties and
singletons too: a property initializer of the `App` type or the app delegate, or a
shared WebView pool, runs before the start-up code in its `init`. Start-up code in the
`App` initializer or in `application(_:didFinishLaunchingWithOptions:)` normally comes
first. If something creates a WebView or registers a handler earlier, move the Necto
block before it.

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
every Necto call still inside `#if DEBUG`. A Release build may still contain the module
and its script, as with the rest of the SDK; without the `install` call nothing in it
runs.

## Verify

Run a Debug build on a simulator with the Necto app open. Open a screen with a WebView
and use it until the page sends a request and talks to the app.

In the Necto app:

- **Network** lists the page's requests with a `WebView` badge.
- **Event Log**, filtered to the `WebView` category, lists `web → app · …` and
  `app → web · …` lines.

With `necto` (also installed as `necto-cli`), find the device and app:

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

## What it records

Network rows carry `"source": "WebView"`. Event Log rows have the `WebView` tag, and
their detail holds:

| Event | Detail |
| --- | --- |
| `web → app · <name>` | `body` (JSON), `page` (the frame's URL), `frame` (`main` or `sub`) |
| `app → web · <name> reply` | `reply` (JSON) or `error`, `page` |
| `app → web · evaluateJavaScript` | `script`, `result` (JSON) or `error`, `page`, `durationMs` |
| `app → web · callAsyncJavaScript` | `script`, `arguments` (JSON), `result` (JSON) or `error`, `page`, `durationMs` |

- A call from the app into a page is one event, sent when it finishes and dated when
  it was made.
- A value JSON cannot hold, such as a date, is shown by its description. Each value is
  cut at 64 KB, with a note of its full size.
- Results and payloads are recorded as they are. A script that reads `document.cookie`
  puts the cookies in Event Log.
- An `XMLHttpRequest` hands over its body already decoded, so its size is that of the
  text, not of the bytes on the wire.

## What it cannot see

- Page navigations and what the browser loads by itself: HTML documents, images, CSS,
  `<script>` files and fonts.
- Requests made inside a Web Worker or a Service Worker, and traffic that is not
  `fetch` or `XMLHttpRequest`: WebSocket, `EventSource` and `navigator.sendBeacon`.
- The body of a streaming response. Server-sent events, NDJSON and similar streams are
  recorded as completed when their headers arrive.
- Headers the browser adds, such as `Cookie` and `User-Agent`.
- Response headers of cross-origin requests that CORS does not expose.

Safari Web Inspector shows all of these. In Debug builds, make the WebView inspectable
and open the page from Safari's Develop menu:

```swift
#if DEBUG
if #available(iOS 16.4, *) {
    webView.isInspectable = true
}
#endif
```

While capture is on, a page can tell: `window.__nectoWebViewCapture` is set and
`fetch.toString()` is not the browser's own. A page that stops reading a response
body part way waits for the rest to arrive before its `cancel()` completes.

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| Nothing from any WebView | `install` ran after the WebView was created, or the build being run is not Debug. |
| Requests appear, bridge messages do not | The bridge uses a URL scheme or a library, see step 4, or its handler was registered before `install` ran, see step 3. |
| A page behaves differently with capture on | The page checks whether `fetch` is the browser's own. Call `NectoWebViewCapture.uninstall()` for that run, and report the page. |
| A request body shows only its size | The body was `FormData`, a `Blob` or binary data. Only text bodies are recorded. |
| A request shows no body | The body was a stream, or travelled inside a `Request` object. Neither is read, so the page's upload is never consumed twice. |
| Capture stops for a WebView after it is set up | The app calls `removeAllUserScripts()` or `removeAllScriptMessageHandlers()` on the WebView's content controller after creating it, which removes Necto's script and receiver too. |

## Turning it off

`NectoWebViewCapture.uninstall()` stops reporting. Pages that are already open keep
working normally.
