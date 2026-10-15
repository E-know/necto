//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoDefaultPlugins
import Foundation

/// Shows what an app's `WKWebView` pages say, in panels the app already has.
///
/// - `fetch` and `XMLHttpRequest` from a page go to the network reporter, with
///   `source` set to `WebView`.
/// - Messages between a page and the app's message handlers, and the app's own calls
///   into a page, go to the event reporter under the `WebView` tag.
///
/// One capture mechanism among others, for apps whose screens include web pages. It
/// is a module of its own, like `NectoURLSessionCapture`, so an app without WebViews
/// never links it and nothing in Necto assumes how an app's pages talk to it.
///
/// ```swift
/// #if DEBUG
/// let network = URLSessionNetworkPlugin()
/// let events = NectoEventsPlugin()
/// NectoSDK.register(network)
/// NectoSDK.register(events)
/// NectoWebViewCapture.install(network: network.network, events: events)
/// NectoSDK.start()
/// #endif
/// ```
///
/// The app's web code does not change. Necto injects a script of its own into each
/// page at runtime, and records names and payloads without decoding the app's bridge.
public enum NectoWebViewCapture {
    /// Starts capturing every `WKWebView` created from now on.
    ///
    /// Call it before the first `WKWebView` is created: one created earlier is not
    /// captured. Calling it again replaces the reporters.
    ///
    /// Takes anything that reports, not the shipped plugins specifically, so an app
    /// that registers `NectoNetworkPlugin` itself passes that instance.
    public static func install(network: any NectoNetworkReporting, events: any NectoEventReporting) {
        NectoWebViewReporters.set(NectoWebViewReporters(network: network, events: events))
        NectoWebViewHooks.install()
    }

    /// Stops reporting. The hooks stay in place and pass everything through, so pages
    /// that are already open keep working as they did.
    public static func uninstall() {
        NectoWebViewReporters.set(nil)
    }
}

/// Where captured traffic goes. Absent while capture is off, which is the one thing
/// every hook checks before doing anything of its own.
struct NectoWebViewReporters: Sendable {
    let network: any NectoNetworkReporting
    let events: any NectoEventReporting

    /// Hooks read this on the main thread while `install` may run on any other.
    private final class Current: @unchecked Sendable {
        private let lock = NSLock()
        private var reporters: NectoWebViewReporters?

        var value: NectoWebViewReporters? {
            get { lock.withLock { reporters } }
            set { lock.withLock { reporters = newValue } }
        }
    }

    private static let current = Current()

    static var installed: NectoWebViewReporters? { current.value }

    static func set(_ reporters: NectoWebViewReporters?) {
        current.value = reporters
    }
}
