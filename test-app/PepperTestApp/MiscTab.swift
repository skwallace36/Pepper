import SwiftUI
import WebKit
import MapKit
import UserNotifications
import os

struct MiscTab: View {
    @Environment(AppState.self) private var state
    @State private var notificationStatus: String = "unknown"

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // MARK: - System Dialogs (for auto-dismiss smoke testing)
                GroupBox("System Dialogs") {
                    VStack(spacing: 8) {
                        Button("Request Notifications Permission") {
                            requestNotificationsPermission()
                        }
                        .accessibilityIdentifier("request_notifications_button")

                        Text("Status: \(notificationStatus)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("notification_permission_status")
                    }
                }
                .onAppear { refreshNotificationStatus() }

                // MARK: - Layers (colors, shadows, gradients)
                GroupBox("Layers") {
                    VStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(
                                LinearGradient(
                                    colors: [.blue, .purple],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(height: 60)
                            .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                            .accessibilityIdentifier("gradient_box")

                        RoundedRectangle(cornerRadius: 12)
                            .fill(.orange)
                            .frame(height: 40)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(.red, lineWidth: 2)
                            )
                            .accessibilityIdentifier("bordered_box")
                    }
                }

                // MARK: - Animation
                GroupBox("Animation") {
                    HStack(spacing: 20) {
                        PulsingDot()
                            .accessibilityIdentifier("pulsing_dot")

                        SpinnerView()
                            .accessibilityIdentifier("spinner")

                        Text("Animated views")
                    }
                }

                // MARK: - Horizontal Scroll
                GroupBox("Horizontal Scroll") {
                    ScrollView(.horizontal, showsIndicators: true) {
                        HStack(spacing: 12) {
                            ForEach(0..<15) { index in
                                VStack {
                                    Image(systemName: "square.fill")
                                        .font(.largeTitle)
                                        .foregroundStyle(
                                            [Color.red, .orange, .yellow, .green, .blue, .purple, .pink][index % 7]
                                        )
                                    Text("Item \(index)")
                                        .font(.caption)
                                }
                                .frame(width: 80, height: 80)
                                .background(.quaternary)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .accessibilityIdentifier("hscroll_item_\(index)")
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .accessibilityIdentifier("horizontal_scroll")
                }

                // MARK: - Timer (for wait_for)
                GroupBox("Timer") {
                    VStack(spacing: 8) {
                        Button("Start 3s Timer") {
                            state.startTimer(seconds: 3)
                        }
                        .accessibilityIdentifier("start_timer_button")

                        if state.timerCountdown > 0 {
                            Text("Countdown: \(state.timerCountdown)")
                                .accessibilityIdentifier("timer_countdown")
                        }

                        Text(state.timerFired ? "Timer: FIRED" : "Timer: waiting")
                            .accessibilityIdentifier("timer_status")
                    }
                }

                // MARK: - NSTimer & CADisplayLink (for timers command)
                GroupBox("NSTimer & CADisplayLink") {
                    VStack(spacing: 8) {
                        HStack(spacing: 12) {
                            Button("Start Timer") {
                                state.startRepeatingTimer()
                            }
                            .accessibilityIdentifier("start_repeating_timer_button")

                            Button("Stop Timer") {
                                state.stopRepeatingTimer()
                            }
                            .accessibilityIdentifier("stop_repeating_timer_button")
                        }

                        Text("Timer ticks: \(state.repeatingTimerCount)")
                            .font(.caption.monospacedDigit())
                            .accessibilityIdentifier("repeating_timer_count")

                        HStack(spacing: 12) {
                            Button("Start Display Link") {
                                state.startDisplayLink()
                            }
                            .accessibilityIdentifier("start_display_link_button")

                            Button("Stop Display Link") {
                                state.stopDisplayLink()
                            }
                            .accessibilityIdentifier("stop_display_link_button")
                        }

                        Text("Display link frames: \(state.displayLinkFrameCount)")
                            .font(.caption.monospacedDigit())
                            .accessibilityIdentifier("display_link_frame_count")
                    }
                }

                // MARK: - NSNotificationCenter Observers (for notifications command)
                GroupBox("NSNotificationCenter Observers") {
                    VStack(spacing: 8) {
                        HStack(spacing: 12) {
                            Button("Register Observer") {
                                state.registerNotificationObserver()
                            }
                            .accessibilityIdentifier("register_observer_button")

                            Button("Remove Observer") {
                                state.removeNotificationObserver()
                            }
                            .accessibilityIdentifier("remove_observer_button")
                        }

                        Button("Post Notification") {
                            state.postTestNotification()
                        }
                        .accessibilityIdentifier("post_notification_button")

                        Text("Received: \(state.notificationReceivedCount)")
                            .font(.caption.monospacedDigit())
                            .accessibilityIdentifier("notification_received_count")
                    }
                }

                // MARK: - Network
                GroupBox("Network") {
                    VStack(spacing: 8) {
                        Button("Fetch HTTP") {
                            state.fetchHTTP()
                        }
                        .accessibilityIdentifier("fetch_button")

                        Text(state.networkResponse.isEmpty ? "No request yet" : state.networkResponse)
                            .accessibilityIdentifier("network_status")
                    }
                }

                // MARK: - Zoomable Image (for gesture/pinch)
                GroupBox("Pinch & Zoom") {
                    ZoomableImage()
                        .frame(height: 150)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .accessibilityIdentifier("zoomable_image")
                }

                // MARK: - Rotation Gesture
                GroupBox("Rotation Gesture") {
                    RotatableView()
                        .frame(height: 100)
                        .accessibilityIdentifier("rotatable_view")
                }

                // MARK: - Web View (with cookie)
                GroupBox("Web View") {
                    CookieWebView(url: URL(string: "https://example.com") ?? URL(fileURLWithPath: "/"))
                        .frame(height: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .accessibilityIdentifier("web_view")
                }

                // MARK: - Map View
                GroupBox("Map") {
                    Map()
                        .frame(height: 150)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .accessibilityIdentifier("map_view")
                }

                // MARK: - UIKit Hosted
                GroupBox("UIKit") {
                    NavigationLink("UIKit Controls Screen") {
                        UIKitControlsWrapper()
                    }
                    .accessibilityIdentifier("uikit_link")
                }

                // MARK: - File Manager
                GroupBox("File Manager") {
                    NavigationLink("File Manager Screen") {
                        FileManagerView()
                    }
                    .accessibilityIdentifier("file_manager_link")
                }

                // MARK: - Context Menu
                GroupBox("Context Menu") {
                    Text("Long press me")
                        .padding()
                        .background(.blue.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .contextMenu {
                            Button("Copy") { print("[PepperTest] Context: Copy") }
                            Button("Share") { print("[PepperTest] Context: Share") }
                            Button(role: .destructive) { print("[PepperTest] Context: Delete") } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .accessibilityIdentifier("context_menu_target")
                }
            }
            .padding()
        }
        .navigationTitle("Misc")
    }

    // MARK: - Notification Permission

    private func requestNotificationsPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in
            DispatchQueue.main.async { refreshNotificationStatus() }
        }
    }

    private func refreshNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                switch settings.authorizationStatus {
                case .authorized: notificationStatus = "authorized"
                case .denied: notificationStatus = "denied"
                case .notDetermined: notificationStatus = "not determined"
                case .provisional: notificationStatus = "provisional"
                case .ephemeral: notificationStatus = "ephemeral"
                @unknown default: notificationStatus = "unknown"
                }
            }
        }
    }
}

// MARK: - Pulsing Dot

struct PulsingDot: View {
    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(.green)
            .frame(width: 20, height: 20)
            .scaleEffect(isPulsing ? 1.5 : 1.0)
            .opacity(isPulsing ? 0.5 : 1.0)
            .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: isPulsing)
            .onAppear { isPulsing = true }
    }
}

// MARK: - Spinner

struct SpinnerView: View {
    @State private var rotation: Double = 0

    var body: some View {
        Image(systemName: "arrow.trianglehead.2.counterclockwise")
            .font(.title2)
            .rotationEffect(.degrees(rotation))
            .animation(.linear(duration: 2).repeatForever(autoreverses: false), value: rotation)
            .onAppear { rotation = 360 }
    }
}

// MARK: - Zoomable Image

struct ZoomableImage: UIViewRepresentable {
    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = 4.0
        scrollView.delegate = context.coordinator

        let imageView = UIImageView(image: UIImage(systemName: "photo.artframe"))
        imageView.contentMode = .scaleAspectFit
        imageView.tag = 100
        scrollView.addSubview(imageView)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])

        return scrollView
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject, UIScrollViewDelegate {
        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            scrollView.viewWithTag(100)
        }
    }
}

// MARK: - Rotatable View

struct RotatableView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .systemTeal.withAlphaComponent(0.2)
        container.layer.cornerRadius = 12

        let shapeLabel = UILabel()
        shapeLabel.text = "⬡"
        shapeLabel.font = .systemFont(ofSize: 36)
        shapeLabel.textAlignment = .center
        shapeLabel.translatesAutoresizingMaskIntoConstraints = false
        shapeLabel.accessibilityIdentifier = "rotation_shape"
        container.addSubview(shapeLabel)

        let angleLabel = UILabel()
        angleLabel.text = "0°"
        angleLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        angleLabel.textColor = .secondaryLabel
        angleLabel.textAlignment = .center
        angleLabel.translatesAutoresizingMaskIntoConstraints = false
        angleLabel.accessibilityIdentifier = "rotation_angle"
        container.addSubview(angleLabel)

        NSLayoutConstraint.activate([
            shapeLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            shapeLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor, constant: -10),
            angleLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            angleLabel.topAnchor.constraint(equalTo: shapeLabel.bottomAnchor, constant: 4),
        ])

        context.coordinator.shapeLabel = shapeLabel
        context.coordinator.angleLabel = angleLabel

        let rotationGesture = UIRotationGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handleRotation(_:))
        )
        container.addGestureRecognizer(rotationGesture)
        container.isUserInteractionEnabled = true

        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject {
        weak var shapeLabel: UILabel?
        weak var angleLabel: UILabel?
        private var cumulativeAngle: CGFloat = 0

        @objc func handleRotation(_ gesture: UIRotationGestureRecognizer) {
            guard let shape = shapeLabel else { return }
            cumulativeAngle += gesture.rotation
            shape.transform = CGAffineTransform(rotationAngle: cumulativeAngle)
            let degrees = Int((cumulativeAngle * 180 / .pi).truncatingRemainder(dividingBy: 360))
            angleLabel?.text = "\(degrees)°"
            gesture.rotation = 0
            print("[PepperTest] Rotation: \(degrees)°")
        }
    }
}

// MARK: - Web View (with cookie)

struct CookieWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)

        // Seed a test cookie
        if let cookie = HTTPCookie(properties: [
            .name: "pepper_session",
            .value: "test-session-abc123",
            .domain: "example.com",
            .path: "/",
            .expires: Date().addingTimeInterval(86400),
        ]) {
            webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) {
                print("[PepperTest] Cookie seeded: pepper_session")
                webView.load(URLRequest(url: self.url))
            }
        } else {
            webView.load(URLRequest(url: self.url))
        }

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
