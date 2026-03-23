import SwiftUI

struct ControlsView: View {
    @Environment(AppState.self) private var state

    @State private var showSheet = false
    @State private var showAlert = false
    // showShareSheet removed — share sheet is presented via UIKit directly
    // so the Pepper dialog interceptor can detect it

    var body: some View {
        @Bindable var state = state

        ScrollView {
            VStack(spacing: 24) {
                // MARK: - Buttons
                GroupBox("Buttons") {
                    VStack(spacing: 12) {
                        Button("Tap Me") {
                            state.incrementTap()
                        }
                        .accessibilityIdentifier("tap_button")

                        Text("Count: \(state.tapCount)")
                            .accessibilityIdentifier("tap_count_label")

                        Button("Reset") {
                            state.resetCount()
                        }
                        .accessibilityIdentifier("reset_button")

                        // Icon-only buttons (for identify_icons)
                        HStack(spacing: 20) {
                            Button(action: { state.incrementTap() }) {
                                Image(systemName: "heart.fill")
                            }
                            .accessibilityIdentifier("heart_button")

                            Button(action: { state.incrementTap() }) {
                                Image(systemName: "star.fill")
                            }
                            .accessibilityIdentifier("star_button")

                            Button(action: { state.incrementTap() }) {
                                Image(systemName: "bell.fill")
                            }
                            .accessibilityIdentifier("bell_button")

                            Button(action: { presentShareSheet() }) {
                                Image(systemName: "square.and.arrow.up")
                            }
                            .accessibilityIdentifier("share_button")
                        }
                        .font(.title2)
                    }
                }

                // MARK: - Toggles
                GroupBox("Toggles") {
                    VStack(spacing: 12) {
                        Toggle("Notifications", isOn: $state.notificationsEnabled)
                            .accessibilityIdentifier("notifications_toggle")

                        Toggle("Dark Mode", isOn: $state.darkModeEnabled)
                            .accessibilityIdentifier("dark_mode_toggle")

                        Toggle("Airplane Mode", isOn: $state.airplaneMode)
                            .accessibilityIdentifier("airplane_toggle")
                    }
                }

                // MARK: - Segmented Control
                GroupBox("Segmented Control") {
                    Picker("Sort", selection: $state.selectedSegment) {
                        Text("Name").tag(0)
                        Text("Date").tag(1)
                        Text("Size").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("sort_picker")

                    Text("Selected: \(["Name", "Date", "Size"][state.selectedSegment])")
                        .accessibilityIdentifier("segment_label")
                }

                // MARK: - Slider
                GroupBox("Slider") {
                    VStack {
                        Slider(value: $state.sliderValue, in: 0...1)
                            .accessibilityIdentifier("value_slider")
                        Text("Value: \(state.sliderValue, specifier: "%.2f")")
                            .accessibilityIdentifier("slider_label")
                    }
                }

                // MARK: - Text Input
                GroupBox("Text Input") {
                    VStack(spacing: 12) {
                        TextField("Enter text here", text: $state.textFieldValue)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("text_field")

                        TextEditor(text: $state.textViewValue)
                            .frame(height: 60)
                            .border(Color.gray.opacity(0.3))
                            .accessibilityIdentifier("text_view")
                    }
                }

                // MARK: - Date Picker & Stepper
                GroupBox("Date & Stepper") {
                    VStack(spacing: 12) {
                        DatePicker("Pick Date", selection: $state.selectedDate, displayedComponents: .date)
                            .accessibilityIdentifier("date_picker")

                        Stepper("Value: \(state.stepperValue)", value: $state.stepperValue, in: 0...20)
                            .accessibilityIdentifier("stepper")
                    }
                }

                // MARK: - Navigation
                GroupBox("Navigation") {
                    VStack(spacing: 12) {
                        NavigationLink("Push Detail") {
                            DetailView()
                        }
                        .accessibilityIdentifier("push_detail_link")

                        Button("Show Sheet") {
                            showSheet = true
                        }
                        .accessibilityIdentifier("show_sheet_button")

                        Button("Show Alert") {
                            showAlert = true
                        }
                        .accessibilityIdentifier("show_alert_button")
                    }
                }

                // MARK: - Long Press
                GroupBox("Long Press") {
                    Button("Hold Me") {
                        // normal tap does nothing
                    }
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: 0.5)
                            .onEnded { _ in
                                state.tapCount += 100
                                print("[PepperTest] Long press detected!")
                            }
                    )
                    .accessibilityIdentifier("long_press_button")
                }
            }
            .padding()
        }
        .navigationTitle("Controls")
        .sheet(isPresented: $showSheet) {
            SheetView()
        }
        .alert("Test Alert", isPresented: $showAlert) {
            Button("OK") {
                print("[PepperTest] Alert OK tapped")
            }
            Button("Cancel", role: .cancel) {
                print("[PepperTest] Alert cancelled")
            }
        } message: {
            Text("This is a test alert dialog")
        }
    }
}

// MARK: - Share Sheet (UIKit presentation)

/// Present UIActivityViewController directly via UIKit so the Pepper dialog
/// interceptor's swizzled `present(_:animated:completion:)` can detect it.
private func presentShareSheet() {
    guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
          let root = scene.windows.first?.rootViewController else { return }
    // Walk to the topmost presented controller
    var top = root
    while let presented = top.presentedViewController { top = presented }
    let vc = UIActivityViewController(activityItems: ["Shared from PepperTestApp" as Any], applicationActivities: nil)
    top.present(vc, animated: true)
}
