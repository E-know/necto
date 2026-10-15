//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import ObjectiveC
import WebKit

/// The eight places capture hooks into WebKit.
///
/// Each replaces an implementation with one that calls the original and reports around
/// it. They are installed once per process, on the first `install`, and every one
/// passes straight through while no reporters are set: that is how `uninstall` turns
/// capture off without touching WebKit again.
///
/// | Group | Selector |
/// | --- | --- |
/// | WebView creation | `initWithFrame:configuration:`, `initWithCoder:` |
/// | Handler registration | `addScriptMessageHandler:name:`, `addScriptMessageHandler:contentWorld:name:`, `addScriptMessageHandlerWithReply:contentWorld:name:` |
/// | App → page | `evaluateJavaScript:completionHandler:`, `evaluateJavaScript:inFrame:inContentWorld:completionHandler:`, `callAsyncJavaScript:arguments:inFrame:inContentWorld:completionHandler:` |
///
/// WebKit calls all of them on the main thread.
enum NectoWebViewHooks {
    static func install() {
        _ = installed
    }

    private static let installed: Void = {
        hookCreation()
        hookRegistration()
        hookPageCalls()
    }()

    typealias Completion = @convention(block) (AnyObject?, NSError?) -> Void

    // MARK: WebView creation

    /// An initialiser takes ownership of the object it is sent to and returns one the
    /// caller owns. `Unmanaged` passes both through as they are: Swift's own retain
    /// and release rules for blocks and C functions do not match an `init` method's.
    private static func hookCreation() {
        typealias InitWithFrame = @convention(c) (AnyObject, Selector, CGRect, WKWebViewConfiguration) -> Unmanaged<AnyObject>?
        hook(WKWebView.self, "initWithFrame:configuration:", as: InitWithFrame.self) { original, selector in
            let block: @MainActor @convention(block) (AnyObject, CGRect, WKWebViewConfiguration) -> Unmanaged<AnyObject>? = {
                object, frame, configuration in
                let webView = original.invoke(object, selector, frame, configuration)
                NectoWebViewInjection.prepare(webView)
                return webView
            }
            return unsafeBitCast(block, to: AnyObject.self)
        }

        typealias InitWithCoder = @convention(c) (AnyObject, Selector, NSCoder) -> Unmanaged<AnyObject>?
        hook(WKWebView.self, "initWithCoder:", as: InitWithCoder.self) { original, selector in
            let block: @MainActor @convention(block) (AnyObject, NSCoder) -> Unmanaged<AnyObject>? = { object, coder in
                let webView = original.invoke(object, selector, coder)
                NectoWebViewInjection.prepare(webView)
                return webView
            }
            return unsafeBitCast(block, to: AnyObject.self)
        }
    }

    // MARK: Handler registration

    private static func hookRegistration() {
        typealias Add = @convention(c) (WKUserContentController, Selector, AnyObject, NSString) -> Void
        hook(WKUserContentController.self, "addScriptMessageHandler:name:", as: Add.self) { original, selector in
            let block: @MainActor @convention(block) (WKUserContentController, AnyObject, NSString) -> Void = {
                controller, handler, name in
                original.invoke(controller, selector, NectoBridgeRecorder.standingIn(for: handler), name)
            }
            return unsafeBitCast(block, to: AnyObject.self)
        }

        typealias AddInWorld = @convention(c) (WKUserContentController, Selector, AnyObject, WKContentWorld, NSString) -> Void
        hook(WKUserContentController.self, "addScriptMessageHandler:contentWorld:name:", as: AddInWorld.self) {
            original, selector in
            let block: @MainActor @convention(block) (WKUserContentController, AnyObject, WKContentWorld, NSString) -> Void = {
                controller, handler, world, name in
                original.invoke(controller, selector, NectoBridgeRecorder.standingIn(for: handler), world, name)
            }
            return unsafeBitCast(block, to: AnyObject.self)
        }

        hook(WKUserContentController.self, "addScriptMessageHandlerWithReply:contentWorld:name:", as: AddInWorld.self) {
            original, selector in
            let block: @MainActor @convention(block) (WKUserContentController, AnyObject, WKContentWorld, NSString) -> Void = {
                controller, handler, world, name in
                original.invoke(controller, selector, NectoBridgeReplyRecorder.standingIn(for: handler), world, name)
            }
            return unsafeBitCast(block, to: AnyObject.self)
        }
    }

    // MARK: App → page

    private static func hookPageCalls() {
        typealias Evaluate = @convention(c) (WKWebView, Selector, NSString, Completion?) -> Void
        hook(WKWebView.self, "evaluateJavaScript:completionHandler:", as: Evaluate.self) { original, selector in
            let block: @MainActor @convention(block) (WKWebView, NSString, Completion?) -> Void = {
                webView, script, completion in
                NectoPageCall.run(
                    "evaluateJavaScript", script: script as String, arguments: nil,
                    page: webView.url, completion: completion
                ) { completion in
                    original.invoke(webView, selector, script, completion)
                }
            }
            return unsafeBitCast(block, to: AnyObject.self)
        }

        typealias EvaluateInFrame = @convention(c) (WKWebView, Selector, NSString, WKFrameInfo?, WKContentWorld, Completion?) -> Void
        hook(WKWebView.self, "evaluateJavaScript:inFrame:inContentWorld:completionHandler:", as: EvaluateInFrame.self) {
            original, selector in
            let block: @MainActor @convention(block) (WKWebView, NSString, WKFrameInfo?, WKContentWorld, Completion?) -> Void = {
                webView, script, frame, world, completion in
                NectoPageCall.run(
                    "evaluateJavaScript", script: script as String, arguments: nil,
                    page: frame?.request.url ?? webView.url, completion: completion
                ) { completion in
                    original.invoke(webView, selector, script, frame, world, completion)
                }
            }
            return unsafeBitCast(block, to: AnyObject.self)
        }

        typealias CallAsync = @convention(c) (WKWebView, Selector, NSString, NSDictionary?, WKFrameInfo?, WKContentWorld, Completion?) -> Void
        hook(
            WKWebView.self,
            "callAsyncJavaScript:arguments:inFrame:inContentWorld:completionHandler:",
            as: CallAsync.self
        ) { original, selector in
            let block: @MainActor @convention(block) (WKWebView, NSString, NSDictionary?, WKFrameInfo?, WKContentWorld, Completion?) -> Void = {
                webView, body, arguments, frame, world, completion in
                // A copy, so the event shows the arguments of the call even if a mutable
                // dictionary changes before it finishes.
                NectoPageCall.run(
                    "callAsyncJavaScript", script: body as String, arguments: (arguments?.copy() as? NSDictionary) ?? [:],
                    page: frame?.request.url ?? webView.url, completion: completion
                ) { completion in
                    original.invoke(webView, selector, body, arguments, frame, world, completion)
                }
            }
            return unsafeBitCast(block, to: AnyObject.self)
        }
    }

    // MARK: Swapping

    /// Replaces the implementation of `name` on `type`, keeping the original to call.
    ///
    /// `class_replaceMethod` changes `type` alone: had `type` only inherited the method,
    /// it gains its own copy rather than changing it for every other subclass.
    private static func hook<Function>(
        _ type: AnyClass,
        _ name: String,
        as _: Function.Type,
        _ makeBlock: (Original<Function>, Selector) -> AnyObject
    ) {
        let selector = NSSelectorFromString(name)
        guard let method = class_getInstanceMethod(type, selector) else { return }

        let original = Original(invoke: unsafeBitCast(method_getImplementation(method), to: Function.self))
        let implementation = imp_implementationWithBlock(makeBlock(original, selector))
        class_replaceMethod(type, selector, implementation, method_getTypeEncoding(method))
    }

    /// An original implementation, called from the main thread only. A C function
    /// pointer captures nothing, but Swift does not count its type as `Sendable`.
    struct Original<Function>: @unchecked Sendable {
        let invoke: Function
    }
}

/// Adds the capture script and its receiver to a new WebView's content controller.
@MainActor
enum NectoWebViewInjection {
    private static var preparedKey: UInt8 = 0

    private static let source: String? = Bundle.module
        .url(forResource: "capture", withExtension: "js")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    static func prepare(_ initialized: Unmanaged<AnyObject>?) {
        guard NectoWebViewReporters.installed != nil,
              let source,
              let webView = initialized?.takeUnretainedValue() as? WKWebView else { return }

        // Several WebViews can share one controller, and it must hold one script and
        // one receiver: WebKit refuses a second handler under the same name.
        let controller = webView.configuration.userContentController
        guard objc_getAssociatedObject(controller, &preparedKey) == nil else { return }
        objc_setAssociatedObject(controller, &preparedKey, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        // The page's own world, because the script has to wrap the page's own `fetch`.
        controller.addUserScript(WKUserScript(
            source: source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: .page
        ))
        controller.add(NectoWebViewCaptureReceiver(), contentWorld: .page, name: NectoWebViewCaptureReceiver.name)
    }
}

/// Reports one call from the app into a page, once, when it finishes.
@MainActor
enum NectoPageCall {
    /// How many app → page hooks are on the call stack. One WebKit build may route a
    /// selector through another; the outer call is the one the app made.
    private static var depth = 0

    static func run(
        _ method: String,
        script: String,
        arguments: NSDictionary?,
        page: URL?,
        completion: NectoWebViewHooks.Completion?,
        call: (NectoWebViewHooks.Completion?) -> Void
    ) {
        guard depth == 0, NectoWebViewReporters.installed != nil else {
            call(completion)
            return
        }
        depth += 1
        defer { depth -= 1 }

        // The app may pass no completion at all. One is passed anyway, to read the
        // result, and the app sees no difference.
        let calledAt = Date()
        call { result, error in
            NectoBridgeEvents.called(
                method,
                script: script,
                arguments: arguments,
                page: page,
                at: calledAt,
                result: result,
                error: error
            )
            completion?(result, error)
        }
    }
}
