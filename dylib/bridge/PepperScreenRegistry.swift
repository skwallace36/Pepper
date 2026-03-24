import UIKit

/// Derives snake_case screen IDs from view controller class names.
///
/// No hardcoded mappings — all IDs are auto-derived by stripping common
/// suffixes (ViewController, Coordinator, Controller, Screen, View) and
/// converting CamelCase to snake_case. Pure static utility.
enum PepperScreenRegistry {

    /// Get the screen ID for a given view controller instance.
    static func screenID(for viewController: UIViewController) -> String {
        let typeName = String(describing: type(of: viewController))
        return deriveScreenID(from: typeName)
    }

    /// Derive a snake_case screen ID from a class name.
    ///
    /// Handles both UIKit names and SwiftUI generic wrapper types:
    ///
    ///     "UserProfileViewController"       -> "user_profile"
    ///     "HomeScreenTabBarCoordinator"     -> "home_screen_tab_bar"
    ///     "SettingsController"              -> "settings"
    ///     "AppHostingController<ModifiedContent<ModifiedContent<HomeView, _EnvironmentKeyWritingModifier<...>>>>"
    ///                                      -> "home_view"
    ///     "UIHostingController<ContentView>" -> "content_view"
    ///     "UIHostingController<AnyView>"    -> "any_view"
    ///
    static func deriveScreenID(from typeName: String) -> String {
        var name = typeName

        // If the type contains generic brackets, extract the innermost meaningful view name.
        // SwiftUI wraps views in ModifiedContent, _EnvironmentKeyWritingModifier, etc.
        if name.contains("<") {
            name = extractSwiftUIViewName(from: name)
        }

        // Strip common suffixes in order of specificity
        let suffixes = ["ViewController", "Coordinator", "Controller", "Screen"]
        for suffix in suffixes {
            if name.hasSuffix(suffix) && name.count > suffix.count {
                name = String(name.dropLast(suffix.count))
                break
            }
        }

        // Strip module prefix if present (e.g. "MyApp.SettingsVC" -> "SettingsVC")
        if let dotIndex = name.lastIndex(of: ".") {
            name = String(name[name.index(after: dotIndex)...])
        }

        return camelCaseToSnakeCase(name)
    }

    /// Extract the meaningful SwiftUI view name from generic wrapper types.
    ///
    /// SwiftUI hosting controllers have types like:
    ///   UIHostingController<ModifiedContent<ModifiedContent<HomeView, _EnvironmentKeyWritingModifier<...>>, ...>>
    ///
    /// The actual view name (HomeView) is buried inside layers of ModifiedContent wrappers.
    /// This function extracts it by recursively unwrapping known wrapper types.
    // swiftlint:disable:next cyclomatic_complexity
    private static func extractSwiftUIViewName(from typeName: String) -> String {
        // Known SwiftUI wrapper types that should be stripped to find the real view
        let wrapperPrefixes = [
            "ModifiedContent<",
            "_EnvironmentKeyWritingModifier<",
            "_TraitWritingModifier<",
            "_ViewModifier_Content<",
            "_PaddingLayout<",
            "_BackgroundModifier<",
            "_OverlayModifier<",
            "_FrameLayout<",
            "_FlexFrameLayout<",
            "_SafeAreaIgnoringLayout<",
            "_ClipEffect<",
            "_PreferenceWritingModifier<",
            "_AnchorWritingModifier<",
            "_TransformEffect<",
            "_OffsetEffect<",
            "Optional<",
        ]

        var current = typeName
        var hostingControllerName: String?

        // Strip hosting controller wrapper, but remember the name
        if let angleBracket = current.firstIndex(of: "<") {
            let prefix = String(current[current.startIndex..<angleBracket])
            if prefix.hasSuffix("HostingController") || prefix == "UIHostingController" {
                hostingControllerName = prefix
                current = String(current[current.index(after: angleBracket)...])
                if current.hasSuffix(">") {
                    current = String(current.dropLast())
                }
            }
        }

        // Collect all modifier type names as we unwrap — if the view name is generic,
        // we can use the last meaningful modifier's ViewModel type as context
        var lastViewModelType: String?

        // Iteratively unwrap SwiftUI modifier wrappers.
        // ModifiedContent<ActualView, SomeModifier> → extract first generic arg
        var changed = true
        while changed {
            changed = false
            for prefix in wrapperPrefixes {
                if current.hasPrefix(prefix) {
                    // For _EnvironmentKeyWritingModifier, capture the ViewModel type
                    if prefix == "_EnvironmentKeyWritingModifier<" {
                        let rest = String(current.dropFirst(prefix.count))
                        let modifierArg = firstGenericArg(rest)
                        // Extract from Optional<SomeViewModel> → SomeViewModel
                        var vmType = modifierArg
                        if vmType.hasPrefix("Optional<") {
                            vmType = String(vmType.dropFirst("Optional<".count))
                            while vmType.hasSuffix(">") { vmType = String(vmType.dropLast()) }
                        }
                        if !vmType.isEmpty && vmType != "Any" {
                            lastViewModelType = vmType
                        }
                    }

                    // For ModifiedContent, the second arg is the modifier — skip to first arg (the view)
                    if prefix == "ModifiedContent<" {
                        let rest = String(current.dropFirst(prefix.count))
                        current = firstGenericArg(rest)
                    } else {
                        current = String(current.dropFirst(prefix.count))
                        current = firstGenericArg(current)
                    }
                    changed = true
                    break
                }
            }
        }

        // Clean up any remaining trailing brackets
        while current.hasSuffix(">") {
            current = String(current.dropLast())
        }

        // If the extracted name is too generic ("View", "AnyView", "ViewModel", empty),
        // try to use the ViewModel type for a more useful screen ID
        let genericNames = ["View", "AnyView", "ViewModel", "Content", "Body", ""]
        if genericNames.contains(current) {
            if let vmType = lastViewModelType {
                // Use ViewModel name: "UserDetailsObservableService" → "UserDetailsObservable"
                var vm = vmType
                for suffix in ["Service", "ObservableService", "ViewModel", "Model"] {
                    if vm.hasSuffix(suffix) && vm.count > suffix.count {
                        vm = String(vm.dropLast(suffix.count))
                        break
                    }
                }
                return vm.isEmpty ? typeName : vm
            }
            // Fall back to hosting controller name without "HostingController"
            if let hc = hostingControllerName {
                var name = hc
                if name.hasSuffix("HostingController") {
                    name = String(name.dropLast("HostingController".count))
                }
                return name.isEmpty ? typeName : name
            }
            return typeName
        }

        return current
    }

    /// Extract the first generic argument from a type string.
    /// Given "HomeView, _EnvironmentKeyWritingModifier<...>>",
    /// returns "HomeView".
    private static func firstGenericArg(_ input: String) -> String {
        var depth = 0
        for (i, char) in input.enumerated() {
            if char == "<" {
                depth += 1
            } else if char == ">" {
                depth -= 1
            } else if char == "," && depth == 0 {
                return String(input.prefix(i)).trimmingCharacters(in: .whitespaces)
            }
        }
        // No comma found — return the whole thing (minus trailing >)
        var result = input
        while result.hasSuffix(">") { result = String(result.dropLast()) }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Convert a CamelCase string to snake_case.
    private static func camelCaseToSnakeCase(_ input: String) -> String {
        guard !input.isEmpty else { return input }

        var result = ""
        var previousWasUppercase = false

        for (index, char) in input.enumerated() {
            if char.isUppercase {
                if index > 0 {
                    if !previousWasUppercase {
                        result.append("_")
                    } else {
                        let nextIndex = input.index(input.startIndex, offsetBy: index + 1)
                        if nextIndex < input.endIndex && input[nextIndex].isLowercase {
                            result.append("_")
                        }
                    }
                }
                result.append(char.lowercased())
                previousWasUppercase = true
            } else {
                result.append(char)
                previousWasUppercase = false
            }
        }

        return result
    }
}
