//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import NectoDefaultPlugins
import Testing
import WebKit

/// Takes what the capture reports, in the order it arrives.
final class Reports: NectoNetworkReporting, NectoEventReporting, @unchecked Sendable {
    private let lock = NSLock()
    private var reportedRecords: [NectoNetworkRecord] = []
    private var reportedEvents: [NectoEvent] = []

    var records: [NectoNetworkRecord] { lock.withLock { reportedRecords } }
    var events: [NectoEvent] { lock.withLock { reportedEvents } }

    func report(_ record: NectoNetworkRecord) {
        lock.withLock { reportedRecords.append(record) }
    }

    func report(_ event: NectoEvent) {
        lock.withLock { reportedEvents.append(event) }
    }
}

struct TimedOut: Error {}

/// Polls rather than spinning the run loop: a test runs as a main actor job, and the
/// main queue does not drain inside one, so WebKit's callbacks would never arrive.
@MainActor
func waitUntil(
    _ description: String,
    timeout: Duration = .seconds(10),
    _ condition: () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
        guard clock.now < deadline else {
            Issue.record("Timed out waiting for \(description)")
            throw TimedOut()
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

/// Lets a stray report arrive before a test says that none did.
@MainActor
func settle() async throws {
    try await Task.sleep(for: .milliseconds(300))
}

/// Serves the test pages and endpoints on a scheme of their own, so the tests open no
/// sockets and need no network.
@MainActor
final class TestServer: NSObject, WKURLSchemeHandler {
    static let scheme = "necto-test"
    static let largeByteCount = NectoNetworkRecord.Body.captureLimit + 100_000

    private var stopped: Set<ObjectIdentifier> = []

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }

        switch url.path {
        case "/page":
            respond(task, url: url, type: "text/html", body: "<!doctype html><title>Necto</title><p>page</p>")

        case "/frames":
            // The frame is served from another host, so it is a cross-origin frame.
            let frame = "\(Self.scheme)://frame-\(url.host ?? "")/frame"
            respond(task, url: url, type: "text/html", body: "<!doctype html><iframe src=\"\(frame)\"></iframe>")

        case "/frame":
            respond(task, url: url, type: "text/html", body: "<!doctype html><script>fetch('/json?from=frame')</script>")

        case "/json":
            respond(task, url: url, type: "application/json", headers: ["X-Necto-Test": "yes"], body: #"{"hello":"world"}"#)

        case "/created":
            respond(task, url: url, status: 201, type: "application/json", body: #"{"created":true}"#)

        case "/large":
            respond(task, url: url, type: "text/plain", body: String(repeating: "a", count: Self.largeByteCount))

        case "/events":
            // Headers and one event, then held open the way a live stream is.
            send(task, url: url, status: 200, headers: ["Content-Type": "text/event-stream"])
            task.didReceive(Data("data: hello\n\n".utf8))

        case "/fail":
            task.didFailWithError(URLError(.cannotConnectToHost))

        default:
            respond(task, url: url, status: 404, type: "application/json", body: #"{"error":"no route"}"#)
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        stopped.insert(ObjectIdentifier(task))
    }

    private func respond(
        _ task: any WKURLSchemeTask,
        url: URL,
        status: Int = 200,
        type: String,
        headers: [String: String] = [:],
        body: String
    ) {
        guard !stopped.contains(ObjectIdentifier(task)) else { return }
        send(task, url: url, status: status, headers: headers.merging(["Content-Type": type]) { first, _ in first })
        task.didReceive(Data(body.utf8))
        task.didFinish()
    }

    private func send(_ task: any WKURLSchemeTask, url: URL, status: Int, headers: [String: String]) {
        var headers = headers
        headers["Access-Control-Allow-Origin"] = "*"
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
        task.didReceive(response ?? URLResponse())
    }
}

/// One WebView on a host of its own.
///
/// Reports are filtered by host, so a request still finishing from an earlier test
/// cannot be counted in this one.
@MainActor
final class TestPage: NSObject, WKNavigationDelegate {
    let host = "t\(UUID().uuidString.prefix(8).lowercased())"
    let webView: WKWebView
    let reports: Reports

    private var finished = false

    init(reports: Reports, configuration: WKWebViewConfiguration = TestPage.configuration()) {
        self.reports = reports
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    static func configuration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(TestServer(), forURLScheme: TestServer.scheme)
        return configuration
    }

    func url(_ path: String) -> URL {
        URL(string: "\(TestServer.scheme)://\(host)\(path)")!
    }

    /// Opens a page and waits until it has loaded.
    @discardableResult
    func open(_ path: String = "/page") async throws -> TestPage {
        finished = false
        webView.load(URLRequest(url: url(path)))
        try await waitUntil("\(path) to load") { finished }
        return self
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finished = true
    }

    /// Runs an async function body in the page and returns what it returns.
    @discardableResult
    func run(_ body: String) async throws -> Any? {
        try await webView.callAsyncJavaScript(body, contentWorld: .page)
    }

    /// The records for one path on this page's host, waiting until there are `count`.
    func records(_ path: String, count: Int) async throws -> [NectoNetworkRecord] {
        try await waitUntil("\(count) records for \(path)") { records(path).count >= count }
        return records(path)
    }

    func records(_ path: String) -> [NectoNetworkRecord] {
        reports.records.filter { URL(string: $0.url)?.path == path && $0.url.contains(host) }
    }

    /// The bridge events whose page is this one.
    var events: [NectoEvent] {
        reports.events.filter { $0.detail["page"]?.contains(host) == true }
    }
}

extension WKWebView {
    /// The completion handler form, called from a synchronous context so that Swift
    /// does not steer it to the `async` overload. Apps call both.
    func evaluate(_ script: String, completion: (@MainActor (Any?, (any Error)?) -> Void)?) {
        evaluateJavaScript(script, completionHandler: completion)
    }
}

/// Records what reaches the app's own handler, the way an app's bridge would.
@MainActor
final class AppHandler: NSObject, WKScriptMessageHandler {
    private(set) var bodies: [Any] = []

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        bodies.append(message.body)
    }
}

/// Answers each message with its reply, or with an error when it is asked to fail.
@MainActor
final class AppReplyHandler: NSObject, WKScriptMessageHandlerWithReply {
    private(set) var bodies: [Any] = []

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor (Any?, String?) -> Void
    ) {
        bodies.append(message.body)
        if (message.body as? [String: Any])?["fail"] as? Bool == true {
            replyHandler(nil, "refused")
        } else {
            replyHandler(["answer": 42], nil)
        }
    }
}
