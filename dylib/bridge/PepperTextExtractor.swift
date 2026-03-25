import UIKit

// MARK: - SwiftUI Text Extraction via Mirror

/// Extracts visible text from SwiftUI views when the accessibility system doesn't
/// expose labels. Walks hosting views' body graphs via Mirror to find Text views
/// and extract their string content.
///
/// Bug #504: SwiftUI Text views that don't set .accessibilityLabel() produce
/// empty accessibility elements. This fallback recovers the text content
/// directly from SwiftUI's internal view storage.

extension ElementDiscoveryBridge {

    /// Extract visible text from a UIView's content using Mirror-based reflection
    /// on SwiftUI hosting views, with UIKit text property fallback.
    ///
    /// Returns combined text from all Text views found, or nil if no text extracted.
    func extractTextFromView(_ view: UIView, maxTexts: Int = 20) -> String? {
        var texts: [String] = []

        // Strategy 1: UIKit text views (UILabel, UITextView, UITextField)
        extractUIKitText(from: view, into: &texts, depth: 0, maxDepth: 8)

        // Strategy 2: SwiftUI hosting views — Mirror body graph for Text values
        if texts.isEmpty {
            extractSwiftUITextFromHostingViews(in: view, into: &texts, maxTexts: maxTexts)
        }

        guard !texts.isEmpty else { return nil }
        let combined = texts.joined(separator: ", ")
        // Truncate to prevent huge labels from a single cell
        if combined.count > 500 {
            return String(combined.prefix(500))
        }
        return combined
    }

    // MARK: - UIKit text extraction

    /// Walk subviews looking for UIKit text-bearing views.
    private func extractUIKitText(from view: UIView, into texts: inout [String], depth: Int, maxDepth: Int) {
        guard depth < maxDepth, texts.count < 20 else { return }

        if let label = view as? UILabel, let text = label.text, !text.isEmpty {
            texts.append(text)
            return  // UILabel is a leaf — don't walk its subviews
        }
        if let tf = view as? UITextField, let text = tf.text ?? tf.placeholder, !text.isEmpty {
            texts.append(text)
            return
        }
        if let tv = view as? UITextView, let text = tv.text, !text.isEmpty {
            texts.append(text)
            return
        }

        for subview in view.subviews {
            extractUIKitText(from: subview, into: &texts, depth: depth + 1, maxDepth: maxDepth)
        }
    }

    // MARK: - SwiftUI Mirror-based text extraction

    /// Find hosting views inside the given view and extract Text content via Mirror.
    private func extractSwiftUITextFromHostingViews(in view: UIView, into texts: inout [String], maxTexts: Int) {
        let typeName = String(describing: type(of: view))

        if typeName.contains("_UIHostingView") || typeName.contains("PlatformViewHost") {
            let mirror = Mirror(reflecting: view)
            for child in mirror.children {
                guard let label = child.label else { continue }
                if label.contains("rootView") || label.contains("content") || label == "_rootView" {
                    extractTextFromSwiftUIValue(child.value, into: &texts, depth: 0, maxTexts: maxTexts)
                }
            }
            return  // Don't recurse into hosting view subviews — body graph is authoritative
        }

        for subview in view.subviews {
            extractSwiftUITextFromHostingViews(in: subview, into: &texts, maxTexts: maxTexts)
        }
    }

    /// Recursively walk a SwiftUI view value type via Mirror, extracting strings
    /// from Text views found in the body graph.
    private func extractTextFromSwiftUIValue(_ value: Any, into texts: inout [String], depth: Int, maxTexts: Int) {
        guard depth < 25, texts.count < maxTexts else { return }

        let typeName = String(describing: type(of: value))

        // Found a Text view — extract its string content
        if typeName == "Text" || typeName.hasSuffix(".Text") {
            if let text = extractStringFromTextView(value), !text.isEmpty {
                texts.append(text)
            }
            return
        }

        // Skip types that can't contain user-visible text
        if typeName.contains("Gesture") || typeName.contains("Animation")
            || typeName.contains("Preference") || typeName.contains("Transaction")
        {
            return
        }

        let mirror = Mirror(reflecting: value)

        for child in mirror.children {
            guard texts.count < maxTexts else { return }
            let label = child.label ?? ""
            let childType = String(describing: type(of: child.value))

            // Recurse into structural SwiftUI children
            if label == "content" || label == "body" || label == "modifier" || label == "storage"
                || label == "view" || label == "source" || label == "some" || label == "label"
                || label == "_tree" || label == "_root" || label == "destination"
                || label.hasPrefix(".")  // Tuple children: .0, .1, .2, ...
                || childType.contains("View") || childType.contains("Text")
                || childType.contains("ModifiedContent") || childType.contains("TupleView")
                || childType.contains("ForEach") || childType.contains("Group")
                || childType.contains("_ConditionalContent") || childType.contains("Optional")
            {
                extractTextFromSwiftUIValue(child.value, into: &texts, depth: depth + 1, maxTexts: maxTexts)
            } else if label.hasPrefix("_") {
                // Internal SwiftUI properties — recurse if they look view-like
                if childType.contains("View") || childType.contains("Text") || childType.contains("Button")
                    || childType.contains("Stack") || childType.contains("Label")
                {
                    extractTextFromSwiftUIValue(child.value, into: &texts, depth: depth + 1, maxTexts: maxTexts)
                }
            }
        }
    }

    // MARK: - Text string extraction

    /// Extract the string value from a SwiftUI Text view's internal storage.
    ///
    /// SwiftUI Text stores content as:
    ///   - Storage.verbatim(String) → direct string
    ///   - Storage.anyTextStorage(LocalizedTextStorage) → LocalizedStringKey.key
    ///   - Concatenation of two Text values
    private func extractStringFromTextView(_ textView: Any) -> String? {
        let mirror = Mirror(reflecting: textView)

        for child in mirror.children {
            if child.label == "storage" || child.label == "_storage" {
                return extractStringFromStorage(child.value)
            }
            // Direct string property (some iOS versions)
            if let str = child.value as? String, !str.isEmpty {
                return str
            }
        }

        return nil
    }

    /// Walk Text.Storage enum to find the actual string.
    private func extractStringFromStorage(_ storage: Any) -> String? {
        // Direct string case
        if let str = storage as? String, !str.isEmpty { return str }

        let mirror = Mirror(reflecting: storage)

        // Check for concatenated text (Text + Text)
        var concatenated: [String] = []
        var isConcatenated = false

        for child in mirror.children {
            // Verbatim storage: String directly
            if let str = child.value as? String, !str.isEmpty {
                return str
            }

            // NSAttributedString
            if let attrStr = child.value as? NSAttributedString, !attrStr.string.isEmpty {
                return attrStr.string
            }

            let childType = String(describing: type(of: child.value))

            // LocalizedStringKey — dig into its key
            if childType.contains("LocalizedStringKey") || child.label == "key" {
                if let str = extractFromLocalizedStringKey(child.value) {
                    return str
                }
            }

            // Concatenated text: two Text children
            if childType == "Text" || childType.hasSuffix(".Text") {
                isConcatenated = true
                if let str = extractStringFromTextView(child.value) {
                    concatenated.append(str)
                }
            }

            // Nested storage types
            if childType.contains("Storage") || childType.contains("Resolved") {
                if let str = extractStringFromStorage(child.value) {
                    return str
                }
            }
        }

        if isConcatenated && !concatenated.isEmpty {
            return concatenated.joined()
        }

        return nil
    }

    /// Extract the key string from a LocalizedStringKey.
    private func extractFromLocalizedStringKey(_ lsk: Any) -> String? {
        let mirror = Mirror(reflecting: lsk)
        for child in mirror.children {
            if child.label == "key", let str = child.value as? String, !str.isEmpty {
                return str
            }
            // Recurse one level for nested key storage
            if child.label == "key" {
                let innerMirror = Mirror(reflecting: child.value)
                for inner in innerMirror.children {
                    if let str = inner.value as? String, !str.isEmpty {
                        return str
                    }
                }
            }
        }
        return nil
    }
}
