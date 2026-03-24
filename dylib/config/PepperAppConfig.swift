import Foundation

/// Central configuration for app-specific behavior.
/// Populated at startup by the app adapter's bootstrap.
/// Pepper core code reads from this config instead of hardcoding app-specific logic.
final class PepperAppConfig {
    static let shared = PepperAppConfig()

    /// App-specific tab bar behavior (custom tab bar discovery, selection, naming).
    var tabBarProvider: TabBarProvider?

    /// URL scheme for deep links (e.g. "myapp" for myapp:// URLs).
    var deeplinkScheme: String = ""

    /// Deep link catalog — self-documenting URL strings.
    /// Paths are readable (myapp://home, myapp://settings?userId=).
    /// The ?param= suffix indicates accepted parameters.
    var deeplinks: [String] = []

    /// Deep link catalog for the deeplinks discovery command (legacy rich format).
    /// Prefer populating `deeplinks` instead.
    var deeplinkCatalog: [[String: String]] = []

    /// Name of the asset bundle containing app icons (e.g. "MyAppAssets").
    var assetBundleName: String?

    /// All icon asset names for the icon catalog.
    var iconNames: [String] = []

    /// Icon name to heuristic label mapping for element discovery.
    var iconHeuristics: [String: String] = [:]

    /// Suffix filter for icon discovery (e.g. "-icon"). If nil, accept all image names.
    var iconNameSuffix: String? = nil

    /// Module prefixes for HeapHandler class resolution (e.g. ["MyApp", "MyAppKit"]).
    var classLookupPrefixes: [String] = []

    /// OSLog subsystem identifier for logging.
    var logSubsystem: String = "com.pepper.control"

    /// Known deep link paths for validation.
    /// If `deeplinks` is populated, paths are derived from those URLs automatically.
    var knownDeeplinks: [String] = []

    /// Resolved deep link paths: prefers derived paths from `deeplinks`, falls back to `knownDeeplinks`.
    var resolvedDeeplinkPaths: [String] {
        if !deeplinks.isEmpty {
            return deeplinks.compactMap { url in
                guard let idx = url.range(of: "://") else { return url }
                let pathAndQuery = String(url[idx.upperBound...])
                return pathAndQuery.components(separatedBy: "?").first ?? pathAndQuery
            }
        }
        return knownDeeplinks
    }

    /// Pre-main hook, called at dylib load time BEFORE main() runs.
    /// Used for early setup like feature flag overrides that must apply
    /// before the app's own initialization code reads them.
    var preMainHook: (() -> Void)?

    /// App-specific bootstrap hook, called once during PepperPlane.start().
    /// Set by the app adapter before the control plane starts.
    var appBootstrap: (() -> Void)?

    /// Additional command handlers registered by the app adapter.
    /// Registered into the dispatcher after built-in handlers.
    var additionalHandlers: [Any] = []  // [PepperHandler] — uses Any to avoid circular dep

    private init() {}
}
