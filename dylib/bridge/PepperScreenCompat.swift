import UIKit

/// Compatibility shims for APIs deprecated in iOS 26.
extension UIScreen {
    static var pepper_screen: UIScreen {
        if #available(iOS 26.0, *),
           let scene = UIApplication.shared.connectedScenes
               .first(where: { $0 is UIWindowScene }) as? UIWindowScene {
            return scene.screen
        }
        if #unavailable(iOS 26.0) {
            return .main
        }
        fatalError("No connected UIWindowScene found")
    }
}

extension UIWindow {
    static func pepper_makeWindow() -> UIWindow {
        if #available(iOS 26.0, *),
           let scene = UIApplication.shared.connectedScenes
               .first(where: { $0 is UIWindowScene }) as? UIWindowScene {
            return UIWindow(windowScene: scene)
        }
        if #unavailable(iOS 26.0) {
            return UIWindow()
        }
        fatalError("No connected UIWindowScene found")
    }
}
