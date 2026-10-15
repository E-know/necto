//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import NectoDefaultPlugins
import NectoWebViewCapture
import Testing
import WebKit

/// Capture is process-wide, so every test runs alone and installs its own reports.
@MainActor
@Suite("WebView capture", .serialized)
final class NectoWebViewCaptureTests {
    let reports = Reports()

    init() {
        NectoWebViewCapture.install(network: reports, events: reports)
    }

    private func page() -> TestPage {
        TestPage(reports: reports)
    }

    // MARK: fetch

    @Test("fetch reports pending and then completed under one id")
    func fetchGet() async throws {
        let page = try await page().open()
        let text = try await page.run("const response = await fetch('/json'); return await response.text()")
        #expect(text as? String == #"{"hello":"world"}"#)

        let records = try await page.records("/json", count: 2)
        #expect(records.map(\.state) == [.pending, .completed])
        #expect(Set(records.map(\.id)).count == 1)
        #expect(records.allSatisfy { $0.source == "WebView" })

        let completed = try #require(records.last)
        #expect(completed.method == "GET")
        #expect(completed.url == page.url("/json").absoluteString)
        #expect(completed.statusCode == 200)
        #expect(completed.responseHeaders["x-necto-test"] == "yes")
        #expect(completed.responseBody?.text == #"{"hello":"world"}"#)
        #expect(completed.responseBody?.contentType == "application/json")
        #expect(completed.responseByteCount == 17)
        #expect(completed.durationMilliseconds != nil)
        #expect(abs(completed.startedAtMilliseconds - Date().timeIntervalSince1970 * 1000) < 60_000)
    }

    @Test("fetch POST keeps a JSON body as text and a form as its size")
    func fetchBodies() async throws {
        let page = try await page().open()
        try await page.run("""
            await fetch('/created', {
              method: 'POST',
              headers: { 'Content-Type': 'application/json', 'X-Trace': 'abc' },
              body: JSON.stringify({ name: 'necto' }),
            });
            const form = new FormData();
            form.append('name', 'necto');
            form.append('file', new Blob(['12345']), 'file.txt');
            await fetch('/json', { method: 'post', body: form });
            """)

        let json = try #require(try await page.records("/created", count: 2).last)
        #expect(json.method == "POST")
        #expect(json.statusCode == 201)
        #expect(json.requestHeaders["content-type"] == "application/json")
        #expect(json.requestHeaders["x-trace"] == "abc")
        #expect(json.requestBody?.text == #"{"name":"necto"}"#)
        #expect(json.requestBody?.byteCount == 16)

        let form = try #require(try await page.records("/json", count: 2).last)
        #expect(form.method == "POST")
        #expect(form.requestBody?.text == nil)
        #expect((form.requestBody?.byteCount ?? 0) > 0)
    }

    @Test("a failing fetch is reported failed and still rejects in the page")
    func fetchFailure() async throws {
        let page = try await page().open()
        let caught = try await page.run("""
            try { await fetch('/fail'); return 'resolved'; } catch (error) { return error.name; }
            """)
        #expect(caught as? String == "TypeError")

        let records = try await page.records("/fail", count: 2)
        #expect(records.map(\.state) == [.pending, .failed])
        #expect(records.last?.errorSummary?.isEmpty == false)
        #expect(records.last?.durationMilliseconds != nil)
    }

    @Test("a body past the cap is cut, keeps its full size, and is marked")
    func fetchTruncation() async throws {
        let page = try await page().open()
        let length = try await page.run("return (await (await fetch('/large')).text()).length")
        #expect(length as? Int == TestServer.largeByteCount)

        let completed = try #require(try await page.records("/large", count: 2).last)
        let body = try #require(completed.responseBody)
        #expect(body.isTruncated)
        #expect(body.byteCount == TestServer.largeByteCount)
        #expect(body.text?.utf8.count == NectoNetworkRecord.Body.captureLimit)
        #expect(completed.responseByteCount == TestServer.largeByteCount)
    }

    @Test("an event stream completes when its headers arrive, without a body")
    func fetchEventStream() async throws {
        let page = try await page().open()
        let status = try await page.run("return (await fetch('/events')).status")
        #expect(status as? Int == 200)

        let completed = try #require(try await page.records("/events", count: 2).last)
        #expect(completed.state == .completed)
        #expect(completed.statusCode == 200)
        #expect(completed.responseBody == nil)
    }

    // MARK: XMLHttpRequest

    @Test("XHR GET, POST and a failure are each reported once finished")
    func xhr() async throws {
        let page = try await page().open()
        let outcome = try await page.run("""
            const send = (method, path, body) => new Promise((resolve) => {
              const request = new XMLHttpRequest();
              request.open(method, path);
              request.setRequestHeader('X-Trace', 'xhr');
              if (body) request.setRequestHeader('Content-Type', 'application/json');
              request.onloadend = () => resolve(request.status + ':' + request.responseText.length);
              request.send(body);
            });
            return [
              await send('GET', '/json'),
              await send('POST', '/created', JSON.stringify({ name: 'necto' })),
              await send('GET', '/fail'),
            ].join(',');
            """)
        #expect(outcome as? String == "200:17,201:16,0:0")

        let get = try #require(try await page.records("/json", count: 2).last)
        #expect(get.state == .completed)
        #expect(get.statusCode == 200)
        #expect(get.requestHeaders["x-trace"] == "xhr")
        #expect(get.responseHeaders["x-necto-test"] == "yes")
        #expect(get.responseBody?.text == #"{"hello":"world"}"#)
        #expect(get.source == "WebView")

        let post = try #require(try await page.records("/created", count: 2).last)
        #expect(post.method == "POST")
        #expect(post.requestBody?.text == #"{"name":"necto"}"#)
        #expect(post.statusCode == 201)

        let failure = try await page.records("/fail", count: 2)
        #expect(failure.map(\.state) == [.pending, .failed])
        #expect(Set(failure.map(\.id)).count == 1)
    }

    @Test("the page reads the same response with capture as without it")
    func pageSeesTheSameResponse() async throws {
        let script = """
            const fetched = await (await fetch('/json')).text();
            const requested = await new Promise((resolve) => {
              const request = new XMLHttpRequest();
              request.open('GET', '/large');
              request.onload = () => resolve(request.responseText.length);
              request.send();
            });
            return fetched + '|' + requested;
            """
        let captured = try await page().open().run(script) as? String

        NectoWebViewCapture.uninstall()
        let plain = try await page().open().run(script) as? String

        #expect(captured != nil)
        #expect(captured == plain)
    }

    /// `forMainFrameOnly: false` asks for every frame. Whether that reaches a frame from
    /// another origin is WebKit's decision, so this pins what it does.
    @Test("a request from a cross-origin frame is captured")
    func crossOriginFrame() async throws {
        let page = try await page().open("/frames")
        try await waitUntil("the frame's request") {
            reports.records.contains { $0.url.contains("frame-\(page.host)") && $0.state == .completed }
        }
    }

    // MARK: Messages from the page

    @Test("a message to an app handler reaches it and is reported once")
    func messageHandler() async throws {
        let configuration = TestPage.configuration()
        let plain = AppHandler()
        let world = AppHandler()
        configuration.userContentController.add(plain, name: "plain")
        configuration.userContentController.add(world, contentWorld: .page, name: "world")
        let page = try await TestPage(reports: reports, configuration: configuration).open()

        try await page.run("""
            window.webkit.messageHandlers.plain.postMessage({ step: 1, path: '/a' });
            window.webkit.messageHandlers.world.postMessage('two');
            """)
        try await waitUntil("both handlers") { plain.bodies.count == 1 && world.bodies.count == 1 }
        #expect((plain.bodies.first as? [String: Any])?["step"] as? Int == 1)
        #expect(world.bodies.first as? String == "two")

        try await settle()
        let messages = page.events.filter { $0.message.hasPrefix("web → app") }
        #expect(messages.map(\.message) == ["web → app · plain", "web → app · world"])
        #expect(messages.allSatisfy { $0.tag == "WebView" && $0.level == .info })
        #expect(messages.first?.detail["body"] == #"{"path":"/a","step":1}"#)
        #expect(messages.last?.detail["body"] == #""two""#)
        #expect(messages.first?.detail["page"] == page.url("/page").absoluteString)
        #expect(messages.first?.detail["frame"] == "main")
    }

    @Test("a reply handler answers the page, and both directions are reported")
    func replyHandler() async throws {
        let configuration = TestPage.configuration()
        let handler = AppReplyHandler()
        configuration.userContentController.addScriptMessageHandler(handler, contentWorld: .page, name: "ask")
        let page = try await TestPage(reports: reports, configuration: configuration).open()

        let answer = try await page.run("""
            const reply = await window.webkit.messageHandlers.ask.postMessage({ question: 1 });
            let error = '';
            try { await window.webkit.messageHandlers.ask.postMessage({ fail: true }); } catch (e) { error = e.message; }
            return reply.answer + ':' + error;
            """)
        #expect(answer as? String == "42:refused")
        #expect(handler.bodies.count == 2)

        try await settle()
        let bridge = page.events.filter { $0.message.contains("ask") }
        try #require(bridge.map(\.message) == [
            "web → app · ask", "app → web · ask reply", "web → app · ask", "app → web · ask reply",
        ])
        #expect(bridge[1].detail["reply"] == #"{"answer":42}"#)
        #expect(bridge[1].level == .info)
        #expect(bridge[3].detail["error"] == "refused")
        #expect(bridge[3].level == .error)
    }

    @Test("a removed handler is released, as it is without capture")
    func removedHandlerIsReleased() async throws {
        let controller = WKUserContentController()
        weak var released: AppHandler?
        do {
            let handler = AppHandler()
            released = handler
            controller.add(handler, name: "gone")
        }
        #expect(released != nil)

        controller.removeScriptMessageHandler(forName: "gone")
        #expect(released == nil)
    }

    // MARK: Calls from the app

    @Test("evaluateJavaScript is reported with its result, with or without a completion")
    func evaluate() async throws {
        let page = try await page().open()

        var completed: (Any?, (any Error)?)?
        page.webView.evaluate("6 * 7") { result, error in completed = (result, error) }
        try await waitUntil("the completion") { completed != nil }
        #expect(completed?.0 as? Int == 42)

        page.webView.evaluate("document.title = 'changed'", completion: nil)
        try await waitUntil("the call without a completion") {
            page.events.filter { $0.detail["script"] == "document.title = 'changed'" }.count == 1
        }

        let reported = try #require(page.events.first { $0.detail["script"] == "6 * 7" })
        #expect(reported.message == "app → web · evaluateJavaScript")
        #expect(reported.tag == "WebView")
        #expect(reported.level == .info)
        #expect(reported.detail["result"] == "42")
        #expect(reported.detail["page"] == page.url("/page").absoluteString)
        #expect(reported.detail["durationMs"] != nil)
        #expect(page.events.first { $0.detail["script"] == "document.title = 'changed'" }?.detail["result"] == #""changed""#)
    }

    @Test("a script that throws is reported as an error, and the app still gets it")
    func evaluateError() async throws {
        let page = try await page().open()

        var received: (any Error)?
        page.webView.evaluate("throw new Error('broken')") { _, error in received = error }
        try await waitUntil("the completion") { received != nil }

        let reported = try #require(page.events.first { $0.detail["script"] == "throw new Error('broken')" })
        #expect(reported.level == .error)
        #expect(reported.detail["error"]?.contains("broken") == true)
        #expect(reported.detail["result"] == nil)
    }

    /// A script whose result the app throws away often returns a DOM node.
    @Test("an unsupported result type is not reported as a failure")
    func evaluateUnsupportedResult() async throws {
        let page = try await page().open()

        var received: (any Error)?
        page.webView.evaluate("document.body") { _, error in received = error }
        try await waitUntil("the completion") { received != nil }
        #expect((received as? WKError)?.code == .javaScriptResultTypeIsUnsupported)

        let reported = try #require(page.events.first { $0.detail["script"] == "document.body" })
        #expect(reported.level == .info)
        #expect(reported.detail["result"] == "unsupported result type")
        #expect(reported.detail["error"] == nil)
    }

    @Test("callAsyncJavaScript is reported with its arguments")
    func callAsync() async throws {
        let page = try await page().open()
        let sum = try await page.webView.callAsyncJavaScript(
            "return a + b",
            arguments: ["a": 1, "b": 2],
            contentWorld: .page
        )
        #expect(sum as? Int == 3)

        try await settle()
        let reported = try #require(page.events.first { $0.detail["script"] == "return a + b" })
        #expect(reported.message == "app → web · callAsyncJavaScript")
        #expect(reported.detail["arguments"] == #"{"a":1,"b":2}"#)
        #expect(reported.detail["result"] == "3")
    }

    @Test("each app → page selector reports exactly one event per call")
    func oneEventPerCall() async throws {
        let page = try await page().open()

        _ = try await page.webView.evaluateJavaScript("'one'")
        _ = try await page.webView.evaluateJavaScript("'two'", in: nil, contentWorld: .page)
        _ = try await page.webView.callAsyncJavaScript("return 'three'", contentWorld: .page)
        // Without a completion: the capture still has to see it finish.
        page.webView.callAsyncJavaScript("return 'four'", in: nil, in: .defaultClient)

        try await settle()
        for script in ["'one'", "'two'", "return 'three'", "return 'four'"] {
            #expect(page.events.filter { $0.detail["script"] == script }.count == 1, "\(script)")
        }
    }

    // MARK: Safety

    @Test("a malformed capture message reports nothing")
    func malformedMessages() async throws {
        let page = try await page().open()
        try await page.run("""
            const post = (body) => window.webkit.messageHandlers.nectoWebViewCapture.postMessage(body);
            post('nonsense');
            post({ kind: 'other', record: {} });
            post({ kind: 'network', record: { id: 'x' } });
            post({ kind: 'network', record: { id: 'x', method: 'GET', url: '/bad', startedAtMilliseconds: 1, state: 'odd' } });
            post({ kind: 'network', record: { id: 'x', method: 'GET', url: '/bad', startedAtMilliseconds: new Date(), state: 'completed' } });
            await fetch('/json');
            """)

        _ = try await page.records("/json", count: 2)
        try await settle()
        #expect(reports.records.filter { $0.id == "x" || $0.url == "/bad" }.isEmpty)
    }

    @Test("after uninstall nothing is reported and the app's code behaves as before")
    func uninstall() async throws {
        let configuration = TestPage.configuration()
        let handler = AppHandler()
        let replies = AppReplyHandler()
        configuration.userContentController.add(handler, name: "early")
        let page = try await TestPage(reports: reports, configuration: configuration).open()

        NectoWebViewCapture.uninstall()
        configuration.userContentController.addScriptMessageHandler(replies, contentWorld: .page, name: "late")

        let answer = try await page.run("""
            window.webkit.messageHandlers.early.postMessage('still delivered');
            await fetch('/json');
            return (await window.webkit.messageHandlers.late.postMessage({})).answer;
            """)
        #expect(answer as? Int == 42)

        var result: Any?
        page.webView.evaluate("'done'") { value, _ in result = value }
        try await waitUntil("the completion") { result != nil && handler.bodies.count == 1 }
        #expect(result as? String == "done")
        #expect(handler.bodies.first as? String == "still delivered")

        try await settle()
        #expect(reports.records.isEmpty)
        #expect(reports.events.isEmpty)
    }

    @Test("WebViews that share a content controller get the script once")
    func sharedController() async throws {
        let configuration = TestPage.configuration()
        let first = try await TestPage(reports: reports, configuration: configuration).open()
        let second = try await TestPage(reports: reports, configuration: configuration).open()

        let scripts = configuration.userContentController.userScripts.filter {
            $0.source.contains("__nectoWebViewCapture")
        }
        #expect(scripts.count == 1)

        try await second.run("await fetch('/json')")
        #expect(try await second.records("/json", count: 2).count == 2)
        #expect(first.records("/json").isEmpty)
    }

    // MARK: How apps create WebViews

    /// Apps commonly subclass `WKWebView` and call `super.init(frame:configuration:)`.
    @Test("a WKWebView subclass is captured")
    func subclass() async throws {
        let configuration = TestPage.configuration()
        let webView = AppWebView(frame: .zero, configuration: configuration)
        #expect(webView.prepared)
        #expect(webView.configuration.userContentController.userScripts.contains {
            $0.source.contains("__nectoWebViewCapture")
        })
    }

    @Test("a WKWebView decoded from an archive is captured")
    func decoded() throws {
        // Archived without capture, so the script can only come from decoding.
        NectoWebViewCapture.uninstall()
        let archive = try NSKeyedArchiver.archivedData(
            withRootObject: WKWebView(frame: .zero, configuration: WKWebViewConfiguration()),
            requiringSecureCoding: false
        )
        NectoWebViewCapture.install(network: reports, events: reports)
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: archive)
        unarchiver.requiresSecureCoding = false
        let webView = try #require(unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? WKWebView)
        #expect(webView.configuration.userContentController.userScripts.contains {
            $0.source.contains("__nectoWebViewCapture")
        })
    }

    /// The creation hooks pass an initialiser's ownership through by hand. Getting it
    /// wrong either leaks every WebView or releases one twice.
    @Test("a captured WebView is released like any other")
    func webViewsAreReleased() async throws {
        let archive = try NSKeyedArchiver.archivedData(
            withRootObject: WKWebView(frame: .zero, configuration: WKWebViewConfiguration()),
            requiringSecureCoding: false
        )
        weak var framed: WKWebView?
        weak var subclassed: WKWebView?
        weak var decoded: WKWebView?
        try autoreleasepool {
            framed = WKWebView(frame: .zero, configuration: TestPage.configuration())
            subclassed = AppWebView(frame: .zero, configuration: TestPage.configuration())
            let unarchiver = try NSKeyedUnarchiver(forReadingFrom: archive)
            unarchiver.requiresSecureCoding = false
            decoded = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? WKWebView
            #expect(decoded != nil)
        }
        try await waitUntil("the WebViews to be released") { framed == nil && subclassed == nil && decoded == nil }
    }
}

private final class AppWebView: WKWebView {
    private(set) var prepared = false

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        prepared = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }
}
