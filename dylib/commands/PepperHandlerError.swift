import Foundation

/// Throwing error type for command handlers.
///
/// Handlers throw these from inside `do/catch` blocks for early-exit validation
/// (missing window, bad params, broken view hierarchy). The dispatcher's
/// `safeExecute` catches anything that propagates, but handler-level catches
/// produce more specific error messages.
enum PepperHandlerError: LocalizedError {
    case noKeyWindow
    case noViewController
    case missingParam(String)
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .noKeyWindow: return "No key window available"
        case .noViewController: return "No visible view controller"
        case .missingParam(let name): return "Missing required param: \(name)"
        case .operationFailed(let detail): return detail
        }
    }
}
