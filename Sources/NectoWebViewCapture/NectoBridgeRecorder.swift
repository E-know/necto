//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoDefaultPlugins
import Foundation
import WebKit

/// Stands in for an app's message handler: reports each message, then hands the same
/// `WKScriptMessage` to the app's handler.
///
/// It holds the app's handler exactly as `WKUserContentController` would have, and
/// `removeScriptMessageHandler(forName:)` releases both, so lifetimes do not change.
@MainActor
final class NectoBridgeRecorder: NSObject, WKScriptMessageHandler {
    private let handler: any WKScriptMessageHandler

    private init(_ handler: any WKScriptMessageHandler) {
        self.handler = handler
    }

    /// What to register in place of `handler`: a recorder while capture is on, and the
    /// handler itself otherwise.
    static func standingIn(for handler: AnyObject) -> AnyObject {
        guard NectoWebViewReporters.installed != nil,
              !NectoBridgeEvents.isCapture(handler),
              let handler = handler as? any WKScriptMessageHandler else { return handler }
        return NectoBridgeRecorder(handler)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        NectoBridgeEvents.received(message)
        handler.userContentController(userContentController, didReceive: message)
    }
}

/// The same, for a handler that replies. The reply, or the error, is reported before
/// it reaches the page.
@MainActor
final class NectoBridgeReplyRecorder: NSObject, WKScriptMessageHandlerWithReply {
    private let handler: any WKScriptMessageHandlerWithReply

    private init(_ handler: any WKScriptMessageHandlerWithReply) {
        self.handler = handler
    }

    static func standingIn(for handler: AnyObject) -> AnyObject {
        guard NectoWebViewReporters.installed != nil,
              !NectoBridgeEvents.isCapture(handler),
              let handler = handler as? any WKScriptMessageHandlerWithReply else { return handler }
        return NectoBridgeReplyRecorder(handler)
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor (Any?, String?) -> Void
    ) {
        NectoBridgeEvents.received(message)

        let name = message.name
        let page = message.frameInfo.request.url
        handler.userContentController(userContentController, didReceive: message) { reply, error in
            NectoBridgeEvents.replied(name, page: page, reply: reply, error: error)
            replyHandler(reply, error)
        }
    }
}

/// The `WebView` events, one shape per direction.
///
/// Necto records names and payloads. It does not pair a request with its response or
/// decode an app's envelope: that is the app's protocol, not Necto's.
@MainActor
enum NectoBridgeEvents {
    static let tag = "WebView"

    /// Capture's own objects are never wrapped, or a message would be reported twice.
    static func isCapture(_ handler: AnyObject) -> Bool {
        handler is NectoBridgeRecorder || handler is NectoBridgeReplyRecorder || handler is NectoWebViewCaptureReceiver
    }

    static func received(_ message: WKScriptMessage) {
        report(.info, "web → app · \(message.name)", at: Date(), [
            "body": NectoBridgeText.json(message.body),
            "page": message.frameInfo.request.url?.absoluteString ?? "",
            "frame": message.frameInfo.isMainFrame ? "main" : "sub",
        ])
    }

    static func replied(_ name: String, page: URL?, reply: Any?, error: String?) {
        var detail = ["page": page?.absoluteString ?? ""]
        if let error {
            detail["error"] = error
        } else {
            detail["reply"] = NectoBridgeText.json(reply)
        }
        report(error == nil ? .info : .error, "app → web · \(name) reply", at: Date(), detail)
    }

    static func called(
        _ method: String,
        script: String,
        arguments: NSDictionary?,
        page: URL?,
        at calledAt: Date,
        result: Any?,
        error: NSError?
    ) {
        var detail = [
            "script": script,
            "page": page?.absoluteString ?? "",
            "durationMs": String(Int((Date().timeIntervalSince(calledAt) * 1000).rounded())),
        ]
        if let arguments {
            detail["arguments"] = NectoBridgeText.json(arguments)
        }

        var level = NectoEvent.Level.info
        if let error, error.domain == WKError.errorDomain,
           error.code == WKError.Code.javaScriptResultTypeIsUnsupported.rawValue {
            // A script whose return value the app throws away often returns a DOM
            // object. That is not a failure.
            detail["result"] = "unsupported result type"
        } else if let error {
            level = .error
            detail["error"] = NectoBridgeText.describe(error)
        } else {
            detail["result"] = NectoBridgeText.json(result)
        }
        report(level, "app → web · \(method)", at: calledAt, detail)
    }

    private static func report(_ level: NectoEvent.Level, _ message: String, at: Date, _ detail: [String: String]) {
        guard let events = NectoWebViewReporters.installed?.events else { return }
        events.report(NectoEvent(
            at: at,
            level: level,
            tag: tag,
            message: message,
            detail: detail.mapValues(NectoBridgeText.capped)
        ))
    }
}

/// Turns bridge payloads into text an event can carry.
enum NectoBridgeText {
    /// Event Log is meant to stay small, so no one value carries more than this.
    static let limit = 64 * 1024

    /// JSON text for anything WebKit hands over. A value JSON cannot hold, such as a
    /// date, falls back to its description rather than being lost.
    static func json(_ value: Any?) -> String {
        guard let value else { return "null" }
        // `isValidJSONObject` rejects a bare string or number, so ask about an array
        // holding it. Serializing an invalid object raises an exception Swift cannot
        // catch, so the check is not optional.
        guard JSONSerialization.isValidJSONObject([value]),
              let data = try? JSONSerialization.data(
                withJSONObject: value,
                options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]
              ) else { return String(describing: value) }
        return String(decoding: data, as: UTF8.self)
    }

    /// Cuts a value past `limit` bytes of UTF-8 on a character boundary, and says so.
    static func capped(_ text: String) -> String {
        let byteCount = text.utf8.count
        guard byteCount > limit else { return text }

        var end = text.utf8.index(text.utf8.startIndex, offsetBy: limit)
        while end.samePosition(in: text.unicodeScalars) == nil {
            text.utf8.formIndex(before: &end)
        }
        return "\(text.unicodeScalars[..<end])… (truncated, \(byteCount) bytes)"
    }

    /// The exception's own message when WebKit passes one along, which is what a
    /// developer needs; WebKit's description alone only says that one occurred.
    static func describe(_ error: NSError) -> String {
        if let message = error.userInfo["WKJavaScriptExceptionMessage"] as? String, !message.isEmpty {
            return "\(error.localizedDescription): \(message)"
        }
        return error.localizedDescription
    }
}
