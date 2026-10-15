# NectoWebViewCapture design

Date: 2026-10-14
Status: draft for review

## Goal

Show what an app's `WKWebView` pages say, in the Necto panels that already exist:

- `fetch` and `XMLHttpRequest` traffic from the page appears in **Network**, marked as
  coming from a WebView.
- Bridge messages between the page and the app appear in **Event Log**, in both
  directions, under the `WebView` category.

The adopting app changes **native code only, in one place**. Its web code is not
changed, and it does not need to be.

## Constraints

Stated by the requester:

- A separate capture module (option B from the exploration), not a change to the SDK.
- The web code of the adopting app cannot be modified.
- A usage document must let a coding agent (Claude Code) apply this to a real app.
- One call at app start (`install`) rather than one per WebView.

Assumed, and treated as requirements:

- Injecting a script from native code at runtime (`WKUserScript`) is not "modifying web
  code".
- Capture runs in `DEBUG` builds only, like every other Necto call ([setup.md](../../setup.md)).
- The rules in `AGENTS.md` and [harness.md](../../harness.md) hold: no change to
  `NectoSDK`, no new wire message, no Mac code that knows this module exists.

## Non-goals

- Page navigations, images, CSS, `<script>` loads and Service Worker requests. They are
  not made by page JavaScript, so a page-level hook cannot see them. Safari Web Inspector
  (`isInspectable`) already covers them.
- Understanding an app's bridge protocol. Necto records names and payloads; it does not
  pair requests with responses or decode an app's envelope.
- URL-scheme bridges (`decidePolicyFor` interception). The usage document has the app
  report them with one `events.report` line.
- A dedicated bridge panel (option C). Revisit once Event Log proves too thin.
- `SFSafariViewController` and `ASWebAuthenticationSession`. They are not in-app
  `WKWebView`s.

## Shape

A new target, `Sources/NectoWebViewCapture`, beside `NectoURLSessionCapture`:

- Depends on `NectoDefaultPlugins`, `NectoModel`, `NectoSDK` and `WebKit`.
- Ships in the `NectoSDK` product.
- Carries one resource, `capture.js`.

`NectoDefaultPlugins` does not depend on it, so it stays an opt-in implementation of
the reporting interfaces.

```swift
public enum NectoWebViewCapture {
    /// Starts capturing every WKWebView created from now on.
    public static func install(network: any NectoNetworkReporting,
                               events: any NectoEventReporting)

    /// Stops reporting. The hooks stay in place and pass everything through.
    public static func uninstall()
}
```

Adoption:

```swift
#if DEBUG
let network = URLSessionNetworkPlugin()
let events = NectoEventsPlugin()
NectoSDK.register(network)
NectoSDK.register(events)
NectoWebViewCapture.install(network: network.network, events: events)
NectoSDK.start()
#endif
```

`install` must run before the first `WKWebView` is created. A WebView created earlier
is not captured.

## Hooks

The hooks swap implementations with `method_setImplementation` and
`imp_implementationWithBlock`, keeping each original `IMP`. They are installed once per
process on the first `install` call. Every hook passes through untouched when no
reporters are set, which is how `uninstall` disables capture.

| Group | Selector | Added behaviour |
| --- | --- | --- |
| WebView creation | `WKWebView initWithFrame:configuration:` | After the original init, inject `capture.js` and add the `nectoWebViewCapture` receiver to `configuration.userContentController`. Once per controller, tracked with an associated object. |
| | `WKWebView initWithCoder:` | Same, for storyboard and nib WebViews. |
| Handler registration | `WKUserContentController addScriptMessageHandler:name:` | Replace the app's handler with a recorder that reports, then forwards the same `WKScriptMessage` to the app's handler. |
| | `addScriptMessageHandler:contentWorld:name:` | Same. |
| | `addScriptMessageHandlerWithReply:contentWorld:name:` | Same, and wrap `replyHandler` so the reply or error is reported before it reaches the page. |
| Native → page | `WKWebView evaluateJavaScript:completionHandler:` | Pass an internal completion and report when it fires, then call the app's completion if it passed one. |
| | `evaluateJavaScript:inFrame:inContentWorld:completionHandler:` | Same. |
| | `callAsyncJavaScript:arguments:inFrame:inContentWorld:completionHandler:` | Same, and include `arguments`. |

Rules the hooks keep:

- The recorder never wraps the `nectoWebViewCapture` receiver or another recorder.
- A hook entered while another native → page hook is already active on the same call
  stack passes through without reporting. On macOS WebKit no selector routes through
  another (see Probe findings), but this keeps a different WebKit build from reporting
  twice.
- The recorder keeps the app's handler alive exactly as `WKUserContentController`
  already does. `removeScriptMessageHandler(forName:)` removes the recorder, which
  releases the app's handler, so lifetimes do not change.
- All hooks run on the main thread, where WebKit calls them. The reporters are already
  thread-safe.

## Injected script

`capture.js` is injected at `atDocumentStart` into every frame
(`forMainFrameOnly: false`), in the `.page` content world. It has to share the page's
world to wrap the page's own `fetch`.

At start the script:

- returns at once if `window.__nectoWebViewCapture` is already set for this frame;
- takes `window.webkit.messageHandlers.nectoWebViewCapture.postMessage` and binds it,
  so a page that later replaces globals cannot cut the channel;
- wraps `window.fetch` and `XMLHttpRequest.prototype`.

| Wrapped | Request side | Response side |
| --- | --- | --- |
| `window.fetch` | method, absolute URL, headers from both the `Request` and `init`. Body: strings and `URLSearchParams` as text; `FormData`, `Blob`, `ArrayBuffer` and typed arrays as size only; streams not read. | Reads `response.clone()` for status, headers and body. The page receives the original response, untouched. |
| `XMLHttpRequest` | `open`, `setRequestHeader`, `send` | On `loadend`: status, `getAllResponseHeaders()`, body by `responseType`. Status 0 is reported as failed. |

- Each request is posted twice with one id (`crypto.randomUUID()`): `pending` at the
  start and `completed` or `failed` at the end. The plugin replaces rather than appends,
  as for `URLSession` records.
- `startedAtMilliseconds` comes from `Date.now()`, the same epoch milliseconds the Swift
  capture uses. `durationMilliseconds` is a `performance.now()` difference.
- The body cap matches `NectoNetworkRecord.Body.captureLimit` (512 KB). The script cuts
  the body before posting and sets `isTruncated`; `byteCount` stays the full size.
- The script decides whether a body is text with the same rule as
  `NectoNetworkRecord.Body.looksTextual`: json, text, xml, javascript,
  x-www-form-urlencoded, or no type at all. A comment in each place points at the other.
- A `text/event-stream` response is reported `completed` when its headers arrive,
  without a body. Reading the clone of an endless stream would leave the row pending
  forever.
- A rejected `fetch` is reported `failed` with the error's message, and the page still
  receives the same rejection.

The message posted to `nectoWebViewCapture` is
`{ "kind": "network", "record": { … } }`. The record uses the property names of
`NectoNetworkRecord`.

## Native side

`nectoWebViewCapture` receiver:

- Converts `message.body` to JSON data, decodes a private DTO with `JSONDecoder`, and
  builds a `NectoNetworkRecord` with `source: "WebView"`. The source is always set
  natively and never taken from the page.
- Silently drops anything that does not decode. Page JavaScript can call this handler
  too, so nothing from it is trusted beyond being shown.

Bridge events are all `NectoEvent(tag: "WebView")`. `detail` values are JSON text,
capped at 64 KB each with a `… (truncated, N bytes)` suffix. Event Log is meant to stay
small.

| When | `message` | `detail` | `level` |
| --- | --- | --- | --- |
| The page posts to an app handler | `web → app · <name>` | `body`, `page` (frame URL), `frame` (`main` or `sub`) | info |
| A reply handler answers | `app → web · <name> reply` | `reply`, or `error` | info, or error |
| `evaluateJavaScript` finishes | `app → web · evaluateJavaScript` | `script`, `result` or `error`, `page`, `durationMs` | info, or error |
| `callAsyncJavaScript` finishes | `app → web · callAsyncJavaScript` | `script`, `arguments`, `result` or `error`, `page`, `durationMs` | info, or error |

- Native → page calls are reported once, when they finish. The event's `at` is the time
  of the call. Reporting both the start and the end would double the log of an app that
  polls its page.
- When the app passed no completion handler, the hook still passes one to read the
  result. The app sees no difference.
- `WKError.javaScriptResultTypeIsUnsupported` is reported as info with
  `result: "unsupported result type"`. A script whose return value the app throws away
  often returns a DOM object, so this is not a failure.
- Payloads become JSON with `JSONSerialization` (`.fragmentsAllowed`, `.sortedKeys`,
  `.withoutEscapingSlashes`). A value it rejects, such as `NSDate`, falls back to
  `String(describing:)`.

## Network record source

`NectoNetworkRecord` gains one optional property:

```swift
/// Where the request came from when it was not the app's own networking,
/// for example `WebView`. Absent for requests the app reports itself.
public let source: String?
```

- `init` gains `source: String? = nil` as its last parameter, so existing callers
  compile unchanged.
- `NectoNetworkRecordCoding.summary` adds `"source"` when it is set. `detail` inherits
  it from the summary.
- `network-logger/public/manifest.json` declares `source: { "type": "string" }` in the
  record items of `records.list`, `records.detail` and `records.observe`. The binding
  version stays at 1: adding a field is not a breaking change.

Network panel (`WebPackages/BuiltInPlugins/src/network-logger`):

- `RecordSummary` gains `source?: string`.
- The URL cell shows the source with the existing `.necto-badge` component, next to the
  host. Before styling, read every place the network table appears in
  `docs/design/gallery.js` and add a WebView row to the gallery.
- The filter matches `method url source`. The placeholder becomes "Filter by method,
  host, path or source" (ko: "메서드, 호스트, 경로 또는 출처 필터").
- The summary tab shows a `Source` pair (ko: "출처") when it is set.
- `mock.ts` gains WebView records: completed, pending, failed, and one with a
  truncated body.

`necto-cli` and agents see the field in `records.list` with no further change.

## Errors and safety

| Case | Behaviour |
| --- | --- |
| `install` called twice | Replaces the reporters. Hooks are not installed twice. |
| `uninstall` | Reporters cleared. Hooks pass through, and injected scripts keep posting to a receiver that drops everything. |
| WebView created before `install` | Not captured. Documented. |
| One `userContentController` shared by several WebViews | Injected once. |
| Malformed message to `nectoWebViewCapture` | Dropped. |
| Page detects wrapped `fetch` (for example by `fetch.toString()`) | Possible. Debug builds only, documented. |
| Page CSP | Does not apply to `WKUserScript`. |
| Release builds | The adopting app keeps every Necto call inside `#if DEBUG`. |

## Testing

New test target `Tests/NectoWebViewCaptureTests` (Swift Testing, macOS, real
`WKWebView`). Pages and endpoints are served by a `WKURLSchemeHandler` on a test
scheme, so the tests open no sockets and need no network.

1. `fetch` GET reports `pending` and then `completed` with the same id, status,
   headers, body and `source == "WebView"`.
2. `fetch` POST with a JSON string records the body as text. `FormData` records size
   only.
3. A failing `fetch` is reported `failed`, and the page still sees the rejection.
4. A response larger than the cap is truncated with `isTruncated` set and the full
   `byteCount`.
5. `text/event-stream` completes when its headers arrive, with no body.
6. XHR GET, POST and error cases.
7. The page reads the same response text with capture installed as without it.
8. `add(_:name:)` and `add(_:contentWorld:name:)`: the app's handler receives the
   message, and one event is reported with name, body, page and frame.
9. `addScriptMessageHandler(_:contentWorld:name:)` (with reply): the page gets the
   reply, and both the message and reply events are reported. A reply error is reported
   at error level.
10. `evaluateJavaScript` with and without a completion handler, with an error, and with
    an unsupported result type.
11. `callAsyncJavaScript` reports its arguments.
12. Exactly one event per call, for each native → page selector.
13. A malformed message to `nectoWebViewCapture` reports nothing.
14. After `uninstall`, nothing is reported and the app's handlers and completions
    behave as before.
15. Two WebViews sharing one `userContentController` inject the script once.

Elsewhere:

- `DefaultPluginTests`: the coding includes `source` when set and omits it when nil.
- `ManifestContractTests` keep the coding and the manifest schema in agreement.
- `script/tests/package.test.mjs`: add `NectoWebViewCapture` to the opt-in capture list
  that `NectoDefaultPlugins` must not reach.
- `Tests/Fixtures/SDKConsumer`: import `NectoWebViewCapture` and reference `install`, so
  a consumer of the single product is shown to compile.
- Network panel: run the dev mock at narrow and wide widths with the new WebView rows
  (Rule 6).

Example app:

- A **WebView** screen loads a bundled page from `LocalAPI.origin`. Its buttons send
  `fetch` GET and POST, an XHR, and a `postMessage` to an `exampleBridge` reply handler.
  A native button calls `evaluateJavaScript` on the page.
- `ExampleApp.swift` calls `NectoWebViewCapture.install` before any WebView.

Device check: the probe below ran on macOS WebKit. Before calling this done, run the
example app on an iOS device and confirm that each native → page selector reports
exactly once.

## Documentation

- New `docs/webview-capture.md` and `docs/ko/webview-capture.md`: the adoption guide,
  written so a person or a coding agent can follow it step by step in an app's
  repository.
- `docs/.vitepress/config.mts`: done with this spec. The guide is under "Start" in both
  sidebars, and `superpowers/**` is in `srcExclude` so design specs are not published.
  Ship the guide in the same release as the module: it describes an API that does not
  exist until then.
- `docs/setup.md` and the ko version: point to the guide from "Where to start".
- `docs/architecture.md` and the ko version: add a module boundary row. **Owns:** one
  capture mechanism, for `WKWebView` traffic and bridge messages. **Must not contain:**
  capture an app cannot disable, or knowledge of an app's bridge protocol.
- `docs/harness.md` and the ko version: add `NectoWebViewCapture` to the Rule 2
  example.

## Files

| Area | Path |
| --- | --- |
| Module | `Sources/NectoWebViewCapture/NectoWebViewCapture.swift` (API, install state) |
| | `Sources/NectoWebViewCapture/NectoWebViewHooks.swift` (the eight hooks) |
| | `Sources/NectoWebViewCapture/NectoBridgeRecorder.swift` (handler and reply recorders) |
| | `Sources/NectoWebViewCapture/NectoWebViewCaptureReceiver.swift` (`nectoWebViewCapture` → records) |
| | `Sources/NectoWebViewCapture/capture.js` |
| Package | `Package.swift` (target, test target, product) |
| Record | `Sources/NectoDefaultPlugins/NectoNetworkRecord.swift`, `NectoNetworkRecordCoding.swift` |
| Panel | `WebPackages/BuiltInPlugins/src/network-logger/{public/manifest.json,src/main.ts,src/necto.ts,src/localization.ts,src/mock.ts}`, rebuilt into `Sources/NectoDefaultPlugins/Panels/network-logger` |
| Gallery | `docs/design/gallery.js` |
| Tests | `Tests/NectoWebViewCaptureTests/`, `Tests/NectoSDKTests/DefaultPluginTests.swift`, `script/tests/package.test.mjs`, `Tests/Fixtures/SDKConsumer` |
| Example | `ExampleApp/ExampleApp.swift`, new `ExampleApp/WebViewDemoView.swift` |
| Docs | listed under Documentation |

## Probe findings (2026-10-14, macOS WebKit, throwaway code)

- `addScriptMessageHandler:name:` did not call
  `addScriptMessageHandler:contentWorld:name:`.
- `evaluateJavaScript:completionHandler:` did not call
  `evaluateJavaScript:inFrame:inContentWorld:completionHandler:`.
- `callAsyncJavaScript:…` was hit once.
- A `WKWebView` loaded a page and ran JavaScript in a plain command-line process.
- A `WKUserScript` added through `webView.configuration.userContentController` after
  init still ran on the next load and reached a message handler.

## Verify during implementation

- The selector findings above on iOS, on a device.
- `WKWebView` under `swift test`. If it cannot run there, move
  `NectoWebViewCaptureTests` into `NectoAppTests`, which already drives real WebViews
  through `xcodebuild`.
- `fetch` and XHR from a custom-scheme page to the same scheme. If WebKit refuses,
  serve the tests from a loopback socket the way `LocalAPI` does.
- Whether a script injected with `forMainFrameOnly: false` runs in cross-origin
  iframes.
- Whether the example app's ATS settings let the WebView load from `127.0.0.1`.
