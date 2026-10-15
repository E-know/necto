//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import NectoDefaultPlugins
import Testing
import WebKit

@testable import NectoWebViewCapture

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
        #expect(Set(records.map(\.startedAtMilliseconds)).count == 1)
        #expect(records.allSatisfy { $0.source == "WebView" })

        let pending = try #require(records.first)
        #expect(pending.statusCode == nil)
        #expect(pending.durationMilliseconds == nil)
        #expect(pending.responseBody == nil)

        let completed = try #require(records.last)
        #expect(completed.method == "GET")
        #expect(completed.url == page.url("/json").absoluteString)
        #expect(completed.statusCode == 200)
        #expect(completed.responseHeaders["x-necto-test"] == "yes")
        #expect(completed.responseBody?.text == #"{"hello":"world"}"#)
        #expect(completed.responseBody?.contentType == "application/json")
        #expect(completed.responseByteCount == 17)
        #expect((0 ..< 10_000).contains(completed.durationMilliseconds ?? -1))
        #expect(abs(completed.startedAtMilliseconds - Date().timeIntervalSince1970 * 1000) < 60_000)

        // The script's own channel is not an app bridge, so it never reaches Event Log.
        #expect(!reports.events.contains { $0.message.contains("nectoWebViewCapture") })
    }

    @Test("requests made at once get ids of their own")
    func distinctIDs() async throws {
        let page = try await page().open()
        try await page.run("await Promise.all([fetch('/json'), fetch('/json'), fetch('/json')])")

        let records = try await page.records("/json", count: 6)
        #expect(Set(records.map(\.id)).count == 3)
    }

    /// `crypto.randomUUID` exists only in a secure context. A page from plain HTTP
    /// falls back to ids of the script's own making.
    @Test("a page outside a secure context still gets distinct ids")
    func distinctIDsWithoutRandomUUID() async throws {
        let page = page()
        page.webView.loadHTMLString("<p>insecure</p>", baseURL: URL(string: "http://\(page.host).invalid/"))
        try await waitUntil("the page") { !page.webView.isLoading && page.webView.url != nil }
        let secure = try await page.run("return window.isSecureContext")
        #expect(secure as? Bool == false)

        try await page.run("await Promise.allSettled([fetch('/one'), fetch('/two')])")
        try await waitUntil("both requests to fail") {
            reports.records.filter { $0.url.contains(page.host) && $0.state == .failed }.count == 2
        }
        let ids = Set(reports.records.filter { $0.url.contains(page.host) }.map(\.id))
        #expect(ids.count == 2)
    }

    @Test("a Request object gives the method, URL and headers, and init replaces its headers")
    func fetchRequestObject() async throws {
        let page = try await page().open()
        try await page.run("""
            await fetch(new Request('/json', { method: 'PUT', headers: { 'X-From': 'request' } }));
            await fetch(new Request('/created', { headers: { 'X-From': 'request' } }), { headers: { 'X-Other': 'init' } });
            """)

        let put = try #require(try await page.records("/json", count: 2).last)
        #expect(put.method == "PUT")
        #expect(put.url == page.url("/json").absoluteString)
        #expect(put.requestHeaders["x-from"] == "request")

        let replaced = try #require(try await page.records("/created", count: 2).last)
        #expect(replaced.requestHeaders == ["x-other": "init"])
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
        // The fields' own sizes: "necto" and "12345".
        #expect(form.requestBody?.byteCount == 10)
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
        #expect(records.last?.errorSummary?.hasPrefix("TypeError") == true)
        #expect((0 ..< 10_000).contains(records.last?.durationMilliseconds ?? -1))
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

    /// The cap falls inside a three-byte character. The half character is held back
    /// rather than turning the whole body into binary.
    @Test("a body cut inside a character keeps its text")
    func fetchTruncationInsideCharacter() async throws {
        let page = try await page().open()
        try await page.run("await (await fetch('/wide')).text()")

        let body = try #require(try await page.records("/wide", count: 2).last?.responseBody)
        #expect(body.isTruncated)
        #expect(body.byteCount == TestServer.wideCharacterCount * 3)
        #expect(body.text?.count == NectoNetworkRecord.Body.captureLimit / 3)
    }

    @Test("a binary body keeps its size, and an empty one is left out")
    func fetchBinaryAndEmpty() async throws {
        let page = try await page().open()
        try await page.run("await (await fetch('/binary')).text(); await fetch('/empty')")

        let binary = try #require(try await page.records("/binary", count: 2).last)
        #expect(binary.responseBody?.byteCount == 6)
        #expect(binary.responseBody?.text == nil)
        #expect(binary.responseBody?.contentType == "application/octet-stream")

        let empty = try #require(try await page.records("/empty", count: 2).last)
        #expect(empty.state == .completed)
        #expect(empty.statusCode == 204)
        #expect(empty.responseBody == nil)
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
        #expect(failure.last?.errorSummary == "The request failed.")

        #expect(!reports.events.contains { $0.message.contains("nectoWebViewCapture") })
    }

    @Test("an XHR used again from its own onload reports both requests")
    func xhrReusedFromOnload() async throws {
        let page = try await page().open()
        let status = try await page.run("""
            return await new Promise((resolve) => {
              const request = new XMLHttpRequest();
              let loads = 0;
              request.onload = () => {
                if (loads++ === 0) {
                  request.open('GET', '/created');
                  request.send();
                } else {
                  resolve(request.status);
                }
              };
              request.open('GET', '/json');
              request.send();
            });
            """)
        #expect(status as? Int == 201)

        let first = try #require(try await page.records("/json", count: 2).last)
        #expect(first.state == .completed)
        #expect(first.statusCode == 200)
        #expect(first.responseBody?.text == #"{"hello":"world"}"#)
        let second = try #require(try await page.records("/created", count: 2).last)
        #expect(second.state == .completed)
        #expect(second.statusCode == 201)
    }

    @Test("aborting an XHR that has finished keeps its answer")
    func xhrAbortedAfterLoad() async throws {
        let page = try await page().open()
        try await page.run("""
            await new Promise((resolve) => {
              const request = new XMLHttpRequest();
              request.onload = () => { request.abort(); resolve(); };
              request.open('GET', '/json');
              request.send();
            });
            """)
        let record = try #require(try await page.records("/json", count: 2).last)
        #expect(record.state == .completed)
        #expect(record.statusCode == 200)
    }

    @Test("opening an XHR again while it is in flight ends the first request")
    func xhrReopenedInFlight() async throws {
        let page = try await page().open()
        try await page.run("""
            await new Promise((resolve) => {
              const request = new XMLHttpRequest();
              request.open('GET', '/events');
              request.send();
              request.open('GET', '/json');
              request.onloadend = resolve;
              request.send();
            });
            """)
        let abandoned = try #require(try await page.records("/events", count: 2).last)
        #expect(abandoned.state == .failed)
        #expect(abandoned.errorSummary == "The request was aborted.")
        let current = try #require(try await page.records("/json", count: 2).last)
        #expect(current.state == .completed)
        #expect(current.responseBody?.text == #"{"hello":"world"}"#)
    }

    @Test("a synchronous XHR that fails is reported failed once")
    func syncXHRFailure() async throws {
        let page = try await page().open()
        let thrown = try await page.run("""
            const request = new XMLHttpRequest();
            request.open('GET', '/fail', false);
            try { request.send(); return 'sent'; } catch (error) { return error.name; }
            """)
        #expect(thrown as? String == "NetworkError")
        let records = try await page.records("/fail", count: 2)
        #expect(records.map(\.state) == [.pending, .failed])
    }

    /// The text is decoded with the response's charset, then kept as UTF-8, so a body
    /// can cross the cap only once it is text.
    @Test("a large XHR text body in another charset keeps its text")
    func xhrLargeTextInAnotherCharset() async throws {
        let page = try await page().open()
        let length = try await page.run("""
            return await new Promise((resolve) => {
              const request = new XMLHttpRequest();
              request.onload = () => resolve(request.responseText.length);
              request.open('GET', '/euc-kr');
              request.send();
            });
            """)
        #expect(length as? Int == TestServer.eucKRCharacterCount)

        let body = try #require(try await page.records("/euc-kr", count: 2).last?.responseBody)
        #expect(body.isTruncated)
        #expect(body.text?.hasPrefix("가가가") == true)
    }

    /// Status 0 means no response arrived, except for a response that is not HTTP,
    /// which an app's own scheme handler often sends for local files.
    @Test("an XHR answered without an HTTP status still completes")
    func xhrWithoutHTTPStatus() async throws {
        let page = try await page().open()
        let text = try await page.run("""
            return await new Promise((resolve) => {
              const request = new XMLHttpRequest();
              request.onload = () => resolve(request.status + ':' + request.responseText);
              request.open('GET', '/local');
              request.send();
            });
            """)
        let record = try #require(try await page.records("/local", count: 2).last)
        #expect(text as? String == "\(record.statusCode ?? -1):local")
        #expect(record.state == .completed)
        #expect(record.responseBody?.text == "local")
    }

    // MARK: What the page sees

    @Test("a request body with a lone surrogate is still reported")
    func loneSurrogate() async throws {
        let page = try await page().open()
        try await page.run(#"await fetch('/created', { method: 'POST', body: 'a\ud800b' })"#)
        let record = try #require(try await page.records("/created", count: 2).last)
        #expect(record.state == .completed)
        #expect(record.requestBody?.text == "a\u{FFFD}b")
    }

    @Test("the page gets its own abort reason back")
    func abortReason() async throws {
        let page = try await page().open()
        let same = try await page.run("""
            const controller = new AbortController();
            const reason = Object.create(null);
            controller.abort(reason);
            try { await fetch('/json', { signal: controller.signal }); return false; } catch (error) { return error === reason; }
            """)
        #expect(same as? Bool == true)
        #expect(try await page.records("/json", count: 2).last?.state == .failed)
    }

    @Test("headers given as a generator still reach the network")
    func generatorHeaders() async throws {
        let page = try await page().open()
        let sent = try await page.run("""
            function* headers() { yield ['X-Generated', 'yes']; }
            return (await (await fetch('/echo-headers', { headers: headers() })).json())['x-generated'];
            """)
        #expect(sent as? String == "yes")
        _ = try await page.records("/echo-headers", count: 2)
    }

    @Test("a page that replaces globals still gets a complete record")
    func replacedGlobals() async throws {
        let page = try await page().open()
        try await page.run("""
            window.Blob = function () {};
            window.TextDecoder = undefined;
            await (await fetch('/created', { method: 'POST', body: new Uint8Array(3) })).text();
            """)
        let record = try #require(try await page.records("/created", count: 2).last)
        #expect(record.state == .completed)
        #expect(record.requestBody?.byteCount == 3)
        #expect(record.responseBody?.text == #"{"created":true}"#)
    }

    @Test("fetch is still no constructor")
    func fetchIsNoConstructor() async throws {
        let page = try await page().open()
        let thrown = try await page.run("try { new fetch('/json'); return 'constructed'; } catch (error) { return error.name; }")
        #expect(thrown as? String == "TypeError")
        try await settle()
        #expect(page.records("/json").isEmpty)
    }

    /// A copy of the body keeps the stream alive, so a page that cancels its reader
    /// would wait for the copy.
    @Test("a page can cancel a stream that is not server-sent events")
    func cancelStream() async throws {
        let page = try await page().open()
        let outcome = try await page.run("""
            const reader = (await fetch('/ndjson')).body.getReader();
            await reader.read();
            return await Promise.race([
              reader.cancel().then(() => 'cancelled'),
              new Promise((resolve) => setTimeout(() => resolve('waiting'), 2000)),
            ]);
            """)
        #expect(outcome as? String == "cancelled")
        let record = try #require(try await page.records("/ndjson", count: 2).last)
        #expect(record.state == .completed)
        #expect(record.responseBody == nil)
    }

    @Test("bytes that are not valid UTF-8 are binary, as in Swift")
    func brokenUTF8() async throws {
        let page = try await page().open()
        try await page.run("await (await fetch('/broken-utf8')).arrayBuffer()")
        let body = try #require(try await page.records("/broken-utf8", count: 2).last?.responseBody)
        #expect(body.byteCount == 4)
        #expect(body.text == nil)
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
        let capturedPage = try await page().open()
        let captured = try await capturedPage.run(script) as? String
        _ = try await capturedPage.records("/large", count: 2)

        NectoWebViewCapture.uninstall()
        let plainPage = try await page().open()
        let plain = try await plainPage.run(script) as? String
        #expect(plainPage.webView.configuration.userContentController.userScripts.isEmpty)

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

    /// Serializing a date raises an exception Swift cannot catch, which would end the
    /// app. A value JSON cannot hold is shown by its description instead.
    @Test("a message JSON cannot hold reaches the app and is still reported")
    func messageJSONCannotHold() async throws {
        let configuration = TestPage.configuration()
        let plain = AppHandler()
        configuration.userContentController.add(plain, name: "plain")
        let page = try await TestPage(reports: reports, configuration: configuration).open()

        try await page.run("""
            window.webkit.messageHandlers.plain.postMessage(new Date(0));
            window.webkit.messageHandlers.plain.postMessage({ when: new Date(0), ratio: NaN });
            """)
        try await waitUntil("both messages") { plain.bodies.count == 2 }

        let bodies = page.events.filter { $0.message == "web → app · plain" }.compactMap { $0.detail["body"] }
        #expect(bodies.count == 2)
        #expect(bodies.allSatisfy { !$0.isEmpty })
    }

    @Test("a message from a frame says so")
    func messageFromFrame() async throws {
        let configuration = TestPage.configuration()
        let plain = AppHandler()
        configuration.userContentController.add(plain, name: "plain")
        let page = try await TestPage(reports: reports, configuration: configuration).open("/frames")

        try await waitUntil("the frame's message") { plain.bodies.count == 1 }
        let message = try #require(reports.events.first { $0.message == "web → app · plain" })
        #expect(message.detail["frame"] == "sub")
        #expect(message.detail["page"] == "\(TestServer.scheme)://frame-\(page.host)/frame")
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

        // Reported before the reply reaches the page, so already here.
        let bridge = page.events.filter { $0.message.contains("ask") }
        try #require(bridge.map(\.message) == [
            "web → app · ask", "app → web · ask reply", "web → app · ask", "app → web · ask reply",
        ])
        #expect(bridge[1].detail["reply"] == #"{"answer":42}"#)
        #expect(bridge[1].level == .info)
        #expect(bridge[3].detail["error"] == "refused")
        #expect(bridge[3].level == .error)
        try await settle()
        #expect(page.events.filter { $0.message.contains("ask") }.count == 4)
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

        try await settle()
        let calls = page.events.filter { $0.detail["script"] == "6 * 7" }
        #expect(calls.count == 1)
        let reported = try #require(calls.first)
        #expect(reported.message == "app → web · evaluateJavaScript")
        #expect(reported.tag == "WebView")
        #expect(reported.level == .info)
        #expect(reported.detail["result"] == "42")
        #expect(reported.detail["page"] == page.url("/page").absoluteString)
        #expect(reported.detail["durationMs"].flatMap(Int.init) != nil)
        #expect(page.events.first { $0.detail["script"] == "document.title = 'changed'" }?.detail["result"] == #""changed""#)
    }

    /// One event, sent when the call finishes, but dated when it was made.
    @Test("an app → page call is dated when it was made")
    func evaluateDatedAtCall() async throws {
        let page = try await page().open()
        let script = "const start = Date.now(); while (Date.now() - start < 300) {} 1"

        var finished: Date?
        page.webView.evaluate(script) { _, _ in finished = Date() }
        try await waitUntil("the completion") { finished != nil }

        let reported = try #require(page.events.first { $0.detail["script"] == script })
        let duration = try #require(reported.detail["durationMs"].flatMap(Int.init))
        #expect(duration >= 250)
        #expect(try #require(finished).timeIntervalSince(reported.at) >= 0.25)
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
        #expect(reported.level == .info)
    }

    @Test("each app → page selector reports exactly one event per call")
    func oneEventPerCall() async throws {
        let page = try await page().open()

        _ = try await page.webView.evaluateJavaScript("'one'")
        _ = try await page.webView.evaluateJavaScript("'two'", in: nil, contentWorld: .page)
        _ = try await page.webView.callAsyncJavaScript("return 'three'", contentWorld: .page)
        // Without a completion: the capture still has to see it finish.
        page.webView.callAsyncJavaScript("return 'four'", in: nil, in: .defaultClient)
        try await waitUntil("the call without a completion") {
            page.events.contains { $0.detail["script"] == "return 'four'" }
        }

        try await settle()
        for script in ["'one'", "'two'", "return 'three'", "return 'four'"] {
            #expect(page.events.filter { $0.detail["script"] == script }.count == 1, "\(script)")
        }
    }

    /// macOS and iOS WebKit route no selector through another, so this drives the
    /// guard directly: a WebKit build that did would otherwise report one call twice.
    @Test("an app → page call made inside another is reported once")
    func nestedPageCall() {
        NectoPageCall.run("evaluateJavaScript", script: "outer", arguments: nil, page: nil, completion: nil) { outer in
            NectoPageCall.run("evaluateJavaScript", script: "inner", arguments: nil, page: nil, completion: nil) { inner in
                inner?(nil, nil)
            }
            outer?(NSNumber(value: 1), nil)
        }
        #expect(reports.events.map { $0.detail["script"] } == ["outer"])
        #expect(reports.events.first?.detail["result"] == "1")
    }

    // MARK: Safety

    @Test("a malformed capture message reports nothing")
    func malformedMessages() async throws {
        let page = try await page().open()
        try await page.run("""
            const post = (body) => window.webkit.messageHandlers.nectoWebViewCapture.postMessage(body);
            const record = { id: 'x', method: 'GET', url: new URL('/bad', location.href).href, startedAtMilliseconds: 1 };
            post('nonsense');
            post({ kind: 'other', record: { ...record, state: 'completed' } });
            post({ kind: 'network', record: { id: 'x' } });
            post({ kind: 'network', record: { ...record, state: 'odd' } });
            post({ kind: 'network', record: { ...record, state: 'completed', startedAtMilliseconds: new Date() } });
            await fetch('/json');
            """)

        _ = try await page.records("/json", count: 2)
        #expect(page.records("/bad").isEmpty)
    }

    @Test("after uninstall nothing is reported and the app's code behaves as before")
    func uninstall() async throws {
        let configuration = TestPage.configuration()
        let handler = AppHandler()
        let replies = AppReplyHandler()
        configuration.userContentController.add(handler, name: "early")
        let page = try await TestPage(reports: reports, configuration: configuration).open()

        // Captured while installed, so the silence afterwards means something.
        try await page.run("window.webkit.messageHandlers.early.postMessage('captured'); await fetch('/json')")
        _ = try await page.records("/json", count: 2)
        try await waitUntil("the captured message") { handler.bodies.count == 1 }
        let recordsBefore = reports.records.count
        let eventsBefore = reports.events.count
        #expect(eventsBefore >= 2)

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
        try await waitUntil("the completion") { result != nil && handler.bodies.count == 2 }
        #expect(result as? String == "done")
        #expect(handler.bodies.last as? String == "still delivered")

        try await settle()
        #expect(reports.records.count == recordsBefore)
        #expect(reports.events.count == eventsBefore)
    }

    @Test("installing again sends captures to the new reporters only")
    func installAgain() async throws {
        let replacement = Reports()
        NectoWebViewCapture.install(network: replacement, events: replacement)
        let page = try await TestPage(reports: replacement).open()
        try await page.run("await fetch('/json')")

        _ = try await page.records("/json", count: 2)
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

        try await first.run("await fetch('/json')")
        try await second.run("await fetch('/json')")
        _ = try await first.records("/json", count: 2)
        _ = try await second.records("/json", count: 2)
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
