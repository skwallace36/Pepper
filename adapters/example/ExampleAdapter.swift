import UIKit

/// Minimal example adapter. Copy this directory, rename the class, and point
/// ADAPTER_PATH in your .env at the new directory.
///
/// The build script picks up this file automatically: it looks for the file
/// containing `static func registerAdapter()`, uses the filename as the class
/// name, and generates a shim that calls it at startup.
///
/// To activate:
///   APP_ADAPTER_TYPE=example
///   ADAPTER_PATH=/path/to/this/directory
final class ExampleAdapter {

    /// Called once at dylib startup. Populate PepperAppConfig with your
    /// app-specific values. Only set the fields you need — everything else
    /// falls back to sensible defaults.
    static func registerAdapter() {
        let config = PepperAppConfig.shared

        // OSLog subsystem shown in Console.app and `make logs`.
        config.logSubsystem = "com.example.myapp.pepper"

        // URL scheme for deep links (the part before "://").
        // e.g. "myapp" lets Pepper navigate via myapp://home
        config.deeplinkScheme = "myapp"

        // Deep link catalog. Paths ending in ?param= document accepted params.
        config.deeplinks = [
            "myapp://home",
            "myapp://profile?userId=",
            "myapp://settings",
        ]

        // Module prefix(es) for heap inspection (HeapHandler class resolution).
        // Match the Swift module name(s) in your app target.
        config.classLookupPrefixes = ["MyApp"]

        // Asset bundle name for icon catalog extraction (optional).
        // Leave unset to use the main bundle.
        // config.assetBundleName = "MyAppAssets"

        // Pre-main hook: runs at dylib load time, BEFORE main() and all app init.
        // Use for feature flag overrides that must apply before the app reads them.
        // config.preMainHook = {
        //     UserDefaults.standard.set(true, forKey: "pepper_testing")
        // }

        // App bootstrap hook: runs once inside PepperPlane.start(), after the
        // control plane is initialised. Use for anything that needs UIKit ready.
        // config.appBootstrap = {
        //     // e.g. register a custom TabBarProvider
        // }
    }
}
