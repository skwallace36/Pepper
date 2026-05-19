import UIKit

/// IMP-chain swizzle helper for UIViewController lifecycle methods with signature
/// `func (Bool) -> Void` (viewWillAppear:, viewDidAppear:, viewWillDisappear:, viewDidDisappear:).
///
/// Captures the current IMP and installs a wrapper via `method_setImplementation`.
/// The wrapper invokes the captured original (preserving `_cmd` as the real selector)
/// and then runs the observer closure on the main thread.
///
/// Unlike `method_exchangeImplementations`, this does NOT rename the selector or
/// introduce an alternate selector-entry into the captured IMP. Instrumentation agents
/// like New Relic's mobile agent assume `_cmd` equals the selector their handler was
/// attached to and throw `NRInvalidArgumentException` when exchange-based swizzling
/// violates that assumption. IMP chaining composes cleanly in either load order.
enum PepperVCLifecycleSwizzle {
    typealias Observer = (UIViewController, Bool) -> Void

    /// Install a chain wrapper on `UIViewController.<selector>`. The observer runs
    /// after the original IMP returns.
    static func install(selector: Selector, observer: @escaping Observer) {
        guard let method = class_getInstanceMethod(UIViewController.self, selector) else {
            pepperLog.error("Failed to resolve UIViewController.\(NSStringFromSelector(selector)) for swizzle", category: .bridge)
            return
        }

        let originalIMP = method_getImplementation(method)
        typealias OrigFunc = @convention(c) (AnyObject, Selector, Bool) -> Void
        let callOriginal = unsafeBitCast(originalIMP, to: OrigFunc.self)

        let block: @convention(block) (AnyObject, Bool) -> Void = { receiver, animated in
            callOriginal(receiver, selector, animated)
            if let vc = receiver as? UIViewController {
                observer(vc, animated)
            }
        }

        method_setImplementation(method, imp_implementationWithBlock(block))
    }
}
