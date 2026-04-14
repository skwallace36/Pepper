import Foundation
import os

/// Loads and executes dynamically compiled Swift dylibs inside the running app process.
///
/// Flow: MCP tool compiles Swift source on Mac → copies .dylib to sim container →
/// sends "eval" command → this loader does dlopen + dlsym("pepper_eval") + call →
/// returns result string over WebSocket.
///
/// Each eval gets a unique dylib path to avoid dlopen caching (Darwin caches by path).
final class PepperEvalLoader {
    static let shared = PepperEvalLoader()

    private var logger: Logger { PepperLogger.logger(category: "eval") }

    /// Track loaded dylib handles for cleanup.
    private var loadedHandles: [(path: String, handle: UnsafeMutableRawPointer)] = []
    private let lock = NSLock()

    /// Maximum loaded dylibs before auto-cleanup of oldest.
    private let maxLoadedDylibs = 20

    private init() {}

    // MARK: - Load and Execute

    /// Load a compiled dylib and call its `pepper_eval` entry point.
    /// Returns the result string from the eval function.
    func loadAndExecute(dylib path: String) -> EvalResult {
        logger.info("Loading eval dylib: \(path)")

        // dlopen with RTLD_NOW to resolve all symbols immediately
        guard let handle = dlopen(path, RTLD_NOW) else {
            let error = String(cString: dlerror())
            logger.error("dlopen failed: \(error)")
            return EvalResult(success: false, output: nil, error: "dlopen failed: \(error)")
        }

        // Track handle for cleanup
        lock.lock()
        loadedHandles.append((path: path, handle: handle))
        if loadedHandles.count > maxLoadedDylibs {
            let oldest = loadedHandles.removeFirst()
            dlclose(oldest.handle)
            logger.info("Auto-closed oldest eval dylib: \(oldest.path)")
        }
        lock.unlock()

        // Look up the entry point
        guard let sym = dlsym(handle, "pepper_eval") else {
            let error = String(cString: dlerror())
            logger.error("dlsym pepper_eval failed: \(error)")
            return EvalResult(success: false, output: nil, error: "Entry point 'pepper_eval' not found: \(error)")
        }

        // Cast to function pointer and call
        // Entry point signature: @_cdecl("pepper_eval") func pepperEval() -> UnsafePointer<CChar>
        typealias EvalFunc = @convention(c) () -> UnsafePointer<CChar>
        let evalFunc = unsafeBitCast(sym, to: EvalFunc.self)

        let resultPtr = evalFunc()
        let result = String(cString: resultPtr)

        logger.info("Eval returned \(result.count) chars")

        return EvalResult(success: true, output: result, error: nil)
    }

    /// Unload all cached eval dylibs.
    func cleanup() {
        lock.lock()
        for entry in loadedHandles {
            dlclose(entry.handle)
        }
        loadedHandles.removeAll()
        lock.unlock()
        logger.info("All eval dylibs unloaded")
    }

    var loadedCount: Int {
        lock.lock()
        let count = loadedHandles.count
        lock.unlock()
        return count
    }
}

// MARK: - Result Type

struct EvalResult {
    let success: Bool
    let output: String?
    let error: String?

    func toDictionary() -> [String: AnyCodable] {
        var dict: [String: AnyCodable] = [
            "success": AnyCodable(success)
        ]
        if let output = output {
            dict["output"] = AnyCodable(output)
        }
        if let error = error {
            dict["error"] = AnyCodable(error)
        }
        return dict
    }
}
