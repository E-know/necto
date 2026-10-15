//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import NectoDefaultPlugins
import Testing

@testable import NectoWebViewCapture

@Suite("Bridge text")
struct NectoBridgeTextTests {
    @Test("a value under the cap is kept whole")
    func underTheCap() {
        let text = String(repeating: "a", count: NectoBridgeText.limit)
        #expect(NectoBridgeText.capped(text) == text)
    }

    @Test("a value over the cap is cut to it and says how large it was")
    func overTheCap() {
        let text = String(repeating: "a", count: 100_000)
        #expect(NectoBridgeText.capped(text)
            == String(repeating: "a", count: NectoBridgeText.limit) + "… (truncated, 100000 bytes)")
    }

    @Test("a cut never splits a character")
    func cutOnABoundary() {
        // Three bytes each, so the limit falls inside one.
        let text = String(repeating: "가", count: 30_000)
        let capped = NectoBridgeText.capped(text)
        let kept = try? #require(capped.components(separatedBy: "…").first)
        #expect(kept == String(repeating: "가", count: NectoBridgeText.limit / 3))
        #expect(capped.hasSuffix("… (truncated, 90000 bytes)"))
    }

    @Test("payloads become sorted JSON, and what JSON cannot hold its description")
    func json() {
        #expect(NectoBridgeText.json(["b": 1, "a": "x/y"]) == #"{"a":"x/y","b":1}"#)
        #expect(NectoBridgeText.json("text") == #""text""#)
        #expect(NectoBridgeText.json(nil) == "null")
        #expect(NectoBridgeText.json(NSNull()) == "null")
        let date = Date(timeIntervalSince1970: 0)
        #expect(NectoBridgeText.json(date) == String(describing: date))
        #expect(NectoBridgeText.json(["when": date]) == String(describing: ["when": date]))
        #expect(NectoBridgeText.json(Double.nan) == String(describing: Double.nan))
    }
}

@Suite("Capture receiver")
struct NectoWebViewCaptureReceiverTests {
    private let valid: [String: Any] = [
        "id": "r1",
        "method": "GET",
        "url": "https://example.com/a",
        "startedAtMilliseconds": 1_000,
        "state": "completed",
        "statusCode": 200,
        "responseBody": ["byteCount": 2, "isTruncated": false, "text": "{}"],
    ]

    @Test("a record from the script becomes a network record from WebView")
    func decodes() throws {
        let record = try #require(NectoWebViewCaptureReceiver.record(from: ["kind": "network", "record": valid]))
        #expect(record.id == "r1")
        #expect(record.statusCode == 200)
        #expect(record.responseBody?.text == "{}")
        #expect(record.requestHeaders.isEmpty)
        #expect(record.source == "WebView")
    }

    /// Page JavaScript can post to the receiver too, so where a record came from is
    /// never the page's to say.
    @Test("the page cannot choose the source")
    func sourceIsNative() throws {
        var forged = valid
        forged["source"] = "App"
        let record = try #require(NectoWebViewCaptureReceiver.record(from: ["kind": "network", "record": forged]))
        #expect(record.source == "WebView")
    }

    @Test("anything else is dropped")
    func dropsMalformed() {
        let record: [String: Any] = ["id": "r1", "method": "GET", "url": "u", "startedAtMilliseconds": 1]
        let malformed: [Any] = [
            "nonsense",
            ["kind": "other"],
            ["record": ["id": "r1"]],
            ["kind": "network", "record": ["id": "r1"]],
            ["kind": "network", "record": record.merging(["state": "odd"]) { _, new in new }],
            ["kind": "network", "record": record.merging(["state": "completed", "startedAtMilliseconds": Date()]) { _, new in new }],
            ["kind": "network", "record": record.merging(["state": "completed", "statusCode": 200.5]) { _, new in new }],
        ]
        for body in malformed {
            #expect(NectoWebViewCaptureReceiver.record(from: body) == nil, "\(body)")
        }
    }

    @Test("a valid record of another kind is dropped")
    func dropsOtherKinds() {
        #expect(NectoWebViewCaptureReceiver.record(from: ["kind": "other", "record": valid]) == nil)
    }
}
