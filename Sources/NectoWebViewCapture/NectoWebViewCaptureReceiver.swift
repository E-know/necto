//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoDefaultPlugins
import Foundation
import WebKit

/// Takes what `capture.js` posts and turns it into network records.
///
/// Page JavaScript can call this handler as well as the injected script can, so
/// nothing it sends is trusted beyond being shown: anything that does not decode is
/// dropped, and the record's `source` is always set here, never taken from the page.
@MainActor
final class NectoWebViewCaptureReceiver: NSObject, WKScriptMessageHandler {
    static let name = "nectoWebViewCapture"

    nonisolated static let source = "WebView"

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let network = NectoWebViewReporters.installed?.network,
              let record = Self.record(from: message.body) else { return }
        network.report(record)
    }

    nonisolated static func record(from body: Any) -> NectoNetworkRecord? {
        // Serializing an object JSON cannot hold, a date for one, raises an exception
        // Swift cannot catch, so validity is checked first.
        guard JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body),
              let message = try? JSONDecoder().decode(Message.self, from: data),
              message.kind == "network" else { return nil }

        let record = message.record
        return NectoNetworkRecord(
            id: record.id,
            method: record.method,
            url: record.url,
            startedAtMilliseconds: record.startedAtMilliseconds,
            state: record.state,
            statusCode: record.statusCode,
            durationMilliseconds: record.durationMilliseconds,
            responseByteCount: record.responseByteCount,
            errorSummary: record.errorSummary,
            requestHeaders: record.requestHeaders ?? [:],
            responseHeaders: record.responseHeaders ?? [:],
            requestBody: record.requestBody,
            responseBody: record.responseBody,
            source: source
        )
    }

    /// What `capture.js` posts: `{ "kind": "network", "record": { … } }`, with the
    /// property names of `NectoNetworkRecord`.
    private struct Message: Decodable {
        let kind: String
        let record: Record

        struct Record: Decodable {
            let id: String
            let method: String
            let url: String
            let startedAtMilliseconds: Double
            let state: NectoNetworkRecord.State
            let statusCode: Int?
            let durationMilliseconds: Double?
            let responseByteCount: Int?
            let errorSummary: String?
            let requestHeaders: [String: String]?
            let responseHeaders: [String: String]?
            let requestBody: NectoNetworkRecord.Body?
            let responseBody: NectoNetworkRecord.Body?
        }
    }
}
