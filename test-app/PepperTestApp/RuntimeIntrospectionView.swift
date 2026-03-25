import SwiftUI
import UIKit

// MARK: - Introspection Objects
// These @objc classes expose properties, methods, and ivars to the ObjC runtime.
// Used by the `explore` command test surface.

/// Leaf user model. Provides the end of the deep chain: controller.model.user.name
@objc class IntrospectionUser: NSObject {
    @objc var name: String
    @objc var email: String
    @objc var age: Int
    @objc var isActive: Bool
    @objc var score: NSNumber
    @objc var joinDate: NSDate
    // Private — not exposed to ObjC runtime, demonstrates private API boundaries
    private var _internalId: String = "internal-id-abc123"
    private var _sessionRef: Int = 7331

    @objc init(name: String, email: String, age: Int) {
        self.name = name
        self.email = email
        self.age = age
        self.isActive = true
        self.score = NSNumber(value: 100.0)
        self.joinDate = NSDate()
        super.init()
    }

    @objc func activate() { isActive = true }
    @objc func deactivate() { isActive = false }
    @objc func resetScore() { score = NSNumber(value: 0) }
}

/// Mid-level model. Provides controller.model chain.
@objc class IntrospectionModel: NSObject {
    @objc var user: IntrospectionUser
    @objc var title: NSString
    @objc var createdAt: NSDate
    @objc var itemCount: NSNumber
    @objc var isPublished: Bool

    @objc init(user: IntrospectionUser, title: String) {
        self.user = user
        self.title = title as NSString
        self.createdAt = NSDate()
        self.itemCount = NSNumber(value: 0)
        self.isPublished = false
        super.init()
    }

    @objc func publish() { isPublished = true }
    @objc func unpublish() { isPublished = false }
}

/// Top-level controller. Entry point for deep chain: controller.model.user.name
@objc class IntrospectionController: NSObject {
    @objc var model: IntrospectionModel
    @objc var label: NSString
    @objc var version: NSNumber
    @objc var tintColor: UIColor
    @objc var bodyFont: UIFont
    @objc var bounds: CGRect

    @objc init(model: IntrospectionModel) {
        self.model = model
        self.label = "IntrospectionController" as NSString
        self.version = NSNumber(value: 1)
        self.tintColor = .systemBlue
        self.bodyFont = .preferredFont(forTextStyle: .body)
        self.bounds = CGRect(x: 0, y: 0, width: 320, height: 240)
        super.init()
    }

    @objc func reset() {
        label = "IntrospectionController" as NSString
        version = NSNumber(value: 1)
        print("[PepperTest] IntrospectionController reset")
    }
}

/// UIView subclass with a rich mix of property types for ObjC runtime enumeration.
/// Demonstrates: CGRect, UIColor, UIFont, NSDate, BOOL, NSString, NSNumber
@objc class IntrospectionWidget: UIView {
    @objc var widgetFrame: CGRect
    @objc var tintOverride: UIColor
    @objc var labelFont: UIFont
    @objc var creationDate: NSDate
    @objc var isWidgetEnabled: Bool
    @objc var caption: NSString
    @objc var score: NSNumber
    // Private ivars — not @objc, won't appear in ObjC runtime property/ivar lists
    private var _secret: String = "widget-secret-key"
    private var _internalState: Int = 0

    override init(frame: CGRect) {
        self.widgetFrame = frame
        self.tintOverride = UIColor.systemIndigo
        self.labelFont = UIFont.preferredFont(forTextStyle: .headline)
        self.creationDate = NSDate()
        self.isWidgetEnabled = true
        self.caption = "IntrospectionWidget" as NSString
        self.score = NSNumber(value: 42)
        super.init(frame: frame)
        self.accessibilityIdentifier = "introspection_widget"
        self.backgroundColor = UIColor.systemIndigo.withAlphaComponent(0.1)
        self.layer.cornerRadius = 12
    }

    required init?(coder: NSCoder) { nil }

    @objc func activate() {
        isWidgetEnabled = true
        print("[PepperTest] IntrospectionWidget activated")
    }

    @objc func deactivate() {
        isWidgetEnabled = false
        print("[PepperTest] IntrospectionWidget deactivated")
    }

    @objc func reset() {
        score = NSNumber(value: 0)
        caption = "reset" as NSString
        print("[PepperTest] IntrospectionWidget reset")
    }

    @objc func incrementScore() {
        score = NSNumber(value: score.intValue + 1)
    }
}

/// Singleton for heap find testing. Access via `heap find IntrospectionSingleton`.
@objc class IntrospectionSingleton: NSObject {
    @objc static let shared = IntrospectionSingleton()

    @objc var sessionTag: NSString = "pepper-introspect-tag-001" as NSString
    @objc var requestCount: NSNumber = NSNumber(value: 0)
    @objc var lastRequestDate: NSDate = NSDate()
    @objc var isInitialized: Bool = false
    @objc var configLabel: NSString = "default" as NSString

    private override init() {
        super.init()
    }

    /// Call this at app launch to register the singleton in the heap.
    @objc func initialize() {
        isInitialized = true
        print("[PepperTest] IntrospectionSingleton initialized — find via: heap find IntrospectionSingleton")
    }

    @objc func incrementRequest() {
        requestCount = NSNumber(value: requestCount.intValue + 1)
        lastRequestDate = NSDate()
    }
}

// MARK: - SwiftUI View

struct RuntimeIntrospectionView: View {
    private let controller: IntrospectionController = {
        let user = IntrospectionUser(name: "Alice", email: "alice@example.com", age: 30)
        let model = IntrospectionModel(user: user, title: "Pepper Introspection Model")
        return IntrospectionController(model: model)
    }()

    @State private var widgetScore: Int = 42
    @State private var lastAction: String = "none"

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {

                // MARK: - Deep Chain
                GroupBox("Deep Property Chain") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("controller.label: \(controller.label)")
                            .font(.caption.monospaced())
                            .accessibilityIdentifier("chain_controller_label")
                        Text("controller.model.title: \(controller.model.title)")
                            .font(.caption.monospaced())
                            .accessibilityIdentifier("chain_model_title")
                        Text("controller.model.user.name: \(controller.model.user.name)")
                            .font(.caption.monospaced())
                            .accessibilityIdentifier("chain_user_name")
                        Text("controller.model.user.email: \(controller.model.user.email)")
                            .font(.caption.monospaced())
                            .accessibilityIdentifier("chain_user_email")
                        Text("controller.model.user.score: \(controller.model.user.score)")
                            .font(.caption.monospaced())
                            .accessibilityIdentifier("chain_user_score")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                // MARK: - Widget (UIView subclass)
                GroupBox("IntrospectionWidget (UIView subclass)") {
                    VStack(spacing: 10) {
                        WidgetView(score: widgetScore)
                            .frame(height: 80)
                            .accessibilityIdentifier("introspection_widget_container")

                        HStack(spacing: 12) {
                            Button("Activate") {
                                lastAction = "activate"
                                print("[PepperTest] Widget activate tapped")
                            }
                            .accessibilityIdentifier("widget_activate_button")

                            Button("Deactivate") {
                                lastAction = "deactivate"
                                print("[PepperTest] Widget deactivate tapped")
                            }
                            .accessibilityIdentifier("widget_deactivate_button")

                            Button("Increment") {
                                widgetScore += 1
                                lastAction = "increment"
                                print("[PepperTest] Widget increment tapped")
                            }
                            .accessibilityIdentifier("widget_increment_button")
                        }
                        .buttonStyle(.bordered)

                        Text("Last action: \(lastAction)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("widget_last_action")
                    }
                }

                // MARK: - Singleton
                GroupBox("IntrospectionSingleton") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("sessionTag: \(IntrospectionSingleton.shared.sessionTag)")
                            .font(.caption.monospaced())
                            .accessibilityIdentifier("singleton_session_tag")
                        Text("requestCount: \(IntrospectionSingleton.shared.requestCount)")
                            .font(.caption.monospaced())
                            .accessibilityIdentifier("singleton_request_count")
                        Text("isInitialized: \(IntrospectionSingleton.shared.isInitialized ? "true" : "false")")
                            .font(.caption.monospaced())
                            .accessibilityIdentifier("singleton_is_initialized")

                        Button("Increment Request Count") {
                            IntrospectionSingleton.shared.incrementRequest()
                            print("[PepperTest] Singleton requestCount: \(IntrospectionSingleton.shared.requestCount)")
                        }
                        .accessibilityIdentifier("singleton_increment_button")
                        .buttonStyle(.bordered)
                        .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                // MARK: - Type Reference
                GroupBox("Class Hierarchy") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("IntrospectionSingleton : NSObject")
                            .font(.caption.monospaced())
                        Text("IntrospectionController : NSObject")
                            .font(.caption.monospaced())
                        Text("IntrospectionModel : NSObject")
                            .font(.caption.monospaced())
                        Text("IntrospectionUser : NSObject")
                            .font(.caption.monospaced())
                        Text("IntrospectionWidget : UIView : UIResponder : NSObject")
                            .font(.caption.monospaced())
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("class_hierarchy_list")
                }
            }
            .padding()
        }
        .navigationTitle("Runtime Introspection")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - UIViewRepresentable wrapper for IntrospectionWidget

struct WidgetView: UIViewRepresentable {
    let score: Int

    func makeUIView(context: Context) -> IntrospectionWidget {
        IntrospectionWidget(frame: .zero)
    }

    func updateUIView(_ uiView: IntrospectionWidget, context: Context) {
        uiView.score = NSNumber(value: score)
        uiView.caption = "score: \(score)" as NSString
    }
}
