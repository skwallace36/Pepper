import SwiftUI
import UIKit

struct AppearanceView: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {

                // MARK: - Current Mode
                GroupBox("Current Appearance") {
                    VStack(spacing: 12) {
                        Image(systemName: colorScheme == .dark
                              ? "moon.stars.fill" : "sun.max.fill")
                            .font(.system(size: 48))
                            .symbolRenderingMode(.multicolor)
                            .accessibilityIdentifier("appearance_mode_icon")

                        Text(colorScheme == .dark ? "dark" : "light")
                            .font(.title2.bold())
                            .accessibilityIdentifier("appearance_mode_label")

                        Text("SwiftUI colorScheme: \(colorScheme == .dark ? "dark" : "light")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("appearance_swiftui_value")

                        UIKitStyleLabel()
                            .frame(height: 20)
                            .accessibilityIdentifier("appearance_uikit_value")
                    }
                    .frame(maxWidth: .infinity)
                }

                // MARK: - Semantic Color Swatches
                GroupBox("Semantic Colors") {
                    VStack(spacing: 8) {
                        ColorSwatchRow(name: "systemBackground",
                                       color: Color(uiColor: .systemBackground))
                        ColorSwatchRow(name: "label",
                                       color: Color(uiColor: .label))
                        ColorSwatchRow(name: "secondaryLabel",
                                       color: Color(uiColor: .secondaryLabel))
                        ColorSwatchRow(name: "tertiarySystemGroupedBackground",
                                       color: Color(uiColor: .tertiarySystemGroupedBackground))
                        ColorSwatchRow(name: "systemFill",
                                       color: Color(uiColor: .systemFill))
                        ColorSwatchRow(name: "separator",
                                       color: Color(uiColor: .separator))
                        ColorSwatchRow(name: "systemRed",
                                       color: Color(uiColor: .systemRed))
                        ColorSwatchRow(name: "systemBlue",
                                       color: Color(uiColor: .systemBlue))
                    }
                }

                // MARK: - Adaptive Cards
                GroupBox("Adaptive Cards") {
                    VStack(spacing: 12) {
                        AdaptiveCard(
                            title: "Primary Card",
                            subtitle: "Uses systemBackground + label colors",
                            background: Color(uiColor: .systemBackground),
                            foreground: Color(uiColor: .label)
                        )
                        AdaptiveCard(
                            title: "Grouped Card",
                            subtitle: "Uses grouped background + secondary label",
                            background: Color(uiColor: .secondarySystemGroupedBackground),
                            foreground: Color(uiColor: .secondaryLabel)
                        )
                        AdaptiveCard(
                            title: "Elevated Card",
                            subtitle: "Uses tertiary fill + primary label",
                            background: Color(uiColor: .tertiarySystemFill),
                            foreground: Color(uiColor: .label)
                        )
                    }
                }

                // MARK: - SF Symbols
                GroupBox("SF Symbols") {
                    HStack(spacing: 20) {
                        VStack {
                            Image(systemName: "heart.fill")
                                .font(.largeTitle)
                                .foregroundStyle(.red)
                            Text("Filled")
                                .font(.caption2)
                        }
                        VStack {
                            Image(systemName: "star.fill")
                                .font(.largeTitle)
                                .foregroundStyle(.yellow)
                            Text("Star")
                                .font(.caption2)
                        }
                        VStack {
                            Image(systemName: "cloud.sun.fill")
                                .font(.largeTitle)
                                .symbolRenderingMode(.multicolor)
                            Text("Multi")
                                .font(.caption2)
                        }
                        VStack {
                            Image(systemName: "circle.lefthalf.filled")
                                .font(.largeTitle)
                                .foregroundStyle(Color(uiColor: .label))
                            Text("Half")
                                .font(.caption2)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("appearance_sf_symbols")
                }
            }
            .padding()
        }
        .navigationTitle("Appearance")
    }
}

// MARK: - Color Swatch Row

private struct ColorSwatchRow: View {
    let name: String
    let color: Color

    var body: some View {
        HStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(color)
                .frame(width: 32, height: 32)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(uiColor: .separator), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.caption.bold())
                Text(color.resolvedHex)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .accessibilityIdentifier("swatch_\(name)")
    }
}

// MARK: - Adaptive Card

private struct AdaptiveCard: View {
    let title: String
    let subtitle: String
    let background: Color
    let foreground: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
                .foregroundStyle(foreground)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(foreground.opacity(0.7))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(uiColor: .separator), lineWidth: 0.5)
        )
    }
}

// MARK: - UIKit Style Label (traitCollection approach)

private struct UIKitStyleLabel: UIViewRepresentable {
    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .caption1)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        return label
    }

    func updateUIView(_ label: UILabel, context: Context) {
        let style = label.traitCollection.userInterfaceStyle
        let name: String
        switch style {
        case .dark: name = "dark"
        case .light: name = "light"
        case .unspecified: name = "unspecified"
        @unknown default: name = "unknown"
        }
        label.text = "UIKit traitCollection: \(name)"
    }
}

// MARK: - Color Hex Resolution

private extension Color {
    var resolvedHex: String {
        let uiColor = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(
            format: "#%02X%02X%02X",
            Int(r * 255), Int(g * 255), Int(b * 255)
        )
    }
}
