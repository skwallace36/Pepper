import UIKit

/// Debug command that scans all visible unlabeled icon buttons and identifies them
/// against the app's icon asset catalog.
///
/// Usage: {"cmd": "identify_icons"}
///
/// Returns each unlabeled small-square element with:
/// - frame, center, className
/// - matched icon_name (or null)
/// - distance (hamming) and confidence ("exact" / "fuzzy" / "none")
/// - catalog stats (built, icon_count, bundle path)
struct IdentifyIconsHandler: PepperHandler {
    let commandName = "identify_icons"

    func handle(_ command: PepperCommand) -> PepperResponse {
        guard UIWindow.pepper_keyWindow != nil else {
            return .error(id: command.id, message: "No key window")
        }

        // Ensure catalog is built
        PepperIconCatalog.shared.ensureBuilt()
        let info = PepperIconCatalog.shared.catalogInfo()

        // Get all interactive elements
        let elements = PepperSwiftUIBridge.shared.discoverInteractiveElements()
        let screenBounds = UIScreen.main.bounds

        // Filter to unlabeled small-square elements (potential icon buttons)
        var icons: [[String: AnyCodable]] = []

        for element in elements {
            guard !element.labeled else { continue }
            guard element.frame.width < 60 && element.frame.height < 60 else { continue }
            guard element.frame.width >= 6 && element.frame.height >= 6 else { continue }
            // Skip off-screen elements
            guard screenBounds.contains(element.center) else { continue }

            let debug = PepperIconCatalog.shared.identifyDebug(frame: element.frame)

            var entry: [String: AnyCodable] = [
                "class": AnyCodable(element.className),
                "center": AnyCodable([
                    "x": AnyCodable(Double(element.center.x)),
                    "y": AnyCodable(Double(element.center.y)),
                ]),
                "frame": AnyCodable([
                    "x": AnyCodable(Double(element.frame.origin.x)),
                    "y": AnyCodable(Double(element.frame.origin.y)),
                    "width": AnyCodable(Double(element.frame.size.width)),
                    "height": AnyCodable(Double(element.frame.size.height)),
                ]),
            ]

            if let debug = debug {
                entry["hash"] = AnyCodable(debug.hashHex)
                if let match = debug.match {
                    entry["icon_name"] = AnyCodable(match.iconName)
                    entry["heuristic"] = AnyCodable(match.heuristic as Any)
                    entry["distance"] = AnyCodable(match.distance)
                    entry["confidence"] = AnyCodable(match.distance == 0 ? "exact" : "fuzzy")
                } else {
                    entry["icon_name"] = AnyCodable(NSNull())
                    entry["best_candidate"] = AnyCodable(debug.bestName as Any)
                    entry["best_distance"] = AnyCodable(debug.bestDistance)
                    entry["confidence"] = AnyCodable("none")
                }
                // Per-scale debug output
                let scales = debug.scaleResults.map { sr in
                    AnyCodable(
                        [
                            "scale": AnyCodable(sr.scale),
                            "method": AnyCodable(sr.method),
                            "hash": AnyCodable(sr.hashHex),
                            "best": AnyCodable(sr.bestName),
                            "dist": AnyCodable(sr.bestDistance),
                        ] as [String: AnyCodable])
                }
                entry["scales"] = AnyCodable(scales)
            } else {
                entry["icon_name"] = AnyCodable(NSNull())
                entry["confidence"] = AnyCodable("none")
            }

            icons.append(entry)
        }

        // If target_icon specified, dump catalog hashes for it
        var targetInfo: [String: AnyCodable]?
        if let target = command.params?["target_icon"]?.stringValue {
            targetInfo = PepperIconCatalog.shared.catalogHashesForIcon(name: target)
        }

        var data: [String: AnyCodable] = [
            "icons": AnyCodable(icons),
            "count": AnyCodable(icons.count),
            "catalog": AnyCodable(
                [
                    "built": AnyCodable(info.built),
                    "icon_count": AnyCodable(info.iconCount),
                    "bundle": AnyCodable(info.bundlePath as Any),
                ] as [String: AnyCodable]),
        ]
        if let ti = targetInfo { data["target_icon"] = AnyCodable(ti) }
        return .ok(id: command.id, data: data)
    }
}
