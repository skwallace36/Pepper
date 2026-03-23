import Foundation
import UIKit
import WebKit

/// Handles {"cmd": "webview"} commands for hybrid app web content inspection.
///
/// Walks the view hierarchy for WKWebView instances and enables JavaScript
/// execution and DOM inspection inside embedded web content.
///
/// Actions:
///   - "evaluate": Execute JavaScript and return the result. Params: script, index (0)
///   - "url":      Return current URL and state for all WebViews found.
///   - "dom":      Return a simplified DOM element listing. Params: selector ("*"), limit (50), index (0)
///
/// Main-thread safety: WKWebView JS evaluation must be called on the main thread,
/// but the completion handler is also delivered on the main thread. To avoid
/// deadlock, we spin the RunLoop while waiting (standard pattern for in-process
/// WebKit testing).
struct WebViewHandler: PepperHandler {
    let commandName = "webview"
    let timeout: TimeInterval = 15.0

    func handle(_ command: PepperCommand) -> PepperResponse {
        let action = command.params?["action"]?.stringValue ?? "evaluate"

        switch action {
        case "evaluate":
            return handleEvaluate(command)
        case "url":
            return handleURL(command)
        case "dom":
            return handleDOM(command)
        default:
            return .error(
                id: command.id,
                message: "Unknown action '\(action)'. Available: evaluate, url, dom")
        }
    }

    // MARK: - WebView Discovery

    private func findWebViews() -> [WKWebView] {
        guard let window = UIWindow.pepper_keyWindow else { return [] }
        return collectWebViews(in: window)
    }

    private func collectWebViews(in view: UIView) -> [WKWebView] {
        var result: [WKWebView] = []
        if let wk = view as? WKWebView {
            result.append(wk)
        }
        for subview in view.subviews {
            result += collectWebViews(in: subview)
        }
        return result
    }

    // MARK: - Actions

    private func handleEvaluate(_ command: PepperCommand) -> PepperResponse {
        guard let script = command.params?["script"]?.stringValue else {
            return .error(id: command.id, message: "Missing 'script' param.")
        }

        let webViews = findWebViews()
        guard !webViews.isEmpty else {
            return .error(id: command.id, message: "No WKWebView found in the view hierarchy.")
        }

        let index = command.params?["index"]?.intValue ?? 0
        guard index < webViews.count else {
            return .error(
                id: command.id,
                message: "WebView index \(index) out of range (found \(webViews.count)).")
        }

        return evaluateJS(script: script, on: webViews[index], commandId: command.id)
    }

    private func handleURL(_ command: PepperCommand) -> PepperResponse {
        let webViews = findWebViews()
        guard !webViews.isEmpty else {
            return .error(id: command.id, message: "No WKWebView found in the view hierarchy.")
        }

        let info = webViews.enumerated().map { (i, wv) -> [String: AnyCodable] in
            [
                "index": AnyCodable(i),
                "url": AnyCodable(wv.url?.absoluteString ?? ""),
                "title": AnyCodable(wv.title ?? ""),
                "loading": AnyCodable(wv.isLoading),
                "can_go_back": AnyCodable(wv.canGoBack),
                "can_go_forward": AnyCodable(wv.canGoForward),
            ]
        }

        return .ok(
            id: command.id,
            data: [
                "count": AnyCodable(webViews.count),
                "webviews": AnyCodable(info),
            ])
    }

    private func handleDOM(_ command: PepperCommand) -> PepperResponse {
        let webViews = findWebViews()
        guard !webViews.isEmpty else {
            return .error(id: command.id, message: "No WKWebView found in the view hierarchy.")
        }

        let index = command.params?["index"]?.intValue ?? 0
        guard index < webViews.count else {
            return .error(
                id: command.id,
                message: "WebView index \(index) out of range (found \(webViews.count)).")
        }

        let webView = webViews[index]
        let rawSelector = command.params?["selector"]?.stringValue ?? "*"
        let limit = command.params?["limit"]?.intValue ?? 50

        // Escape single quotes in selector to prevent script injection
        let safeSelector = rawSelector.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")

        let domScript = """
            (function() {
                var nodes = document.querySelectorAll('\(safeSelector)');
                var result = [];
                var count = Math.min(nodes.length, \(limit));
                for (var i = 0; i < count; i++) {
                    var el = nodes[i];
                    result.push({
                        tag: el.tagName ? el.tagName.toLowerCase() : '',
                        id: el.id || '',
                        class: el.className || '',
                        text: (el.textContent || '').trim().substring(0, 100),
                        href: el.href || '',
                        src: el.src || '',
                        type: el.type || '',
                        value: el.value !== undefined ? String(el.value) : ''
                    });
                }
                return JSON.stringify({total: nodes.length, shown: result.length, elements: result});
            })()
            """

        let jsResponse = evaluateJS(script: domScript, on: webView, commandId: command.id)
        guard jsResponse.status == .ok, let resultStr = jsResponse.data?["result"]?.stringValue
        else {
            return jsResponse
        }

        if let data = resultStr.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            return .ok(
                id: command.id,
                data: [
                    "url": AnyCodable(webView.url?.absoluteString ?? ""),
                    "total": AnyCodable(json["total"] ?? 0),
                    "shown": AnyCodable(json["shown"] ?? 0),
                    "elements": AnyCodable(json["elements"] ?? []),
                ])
        }

        return .ok(
            id: command.id,
            data: [
                "url": AnyCodable(webView.url?.absoluteString ?? ""),
                "raw": AnyCodable(resultStr),
            ])
    }

    // MARK: - JS Evaluation

    /// Evaluate JavaScript on a WKWebView synchronously from the main thread.
    ///
    /// WKWebView's JS completion handler is delivered on the main thread, so we
    /// cannot use a semaphore (that would deadlock). Instead we spin the RunLoop,
    /// which lets the completion handler fire while this call is still on the stack.
    private func evaluateJS(script: String, on webView: WKWebView, commandId: String)
        -> PepperResponse
    {
        var jsResult: Any?
        var jsError: Error?
        var completed = false

        webView.evaluateJavaScript(script) { result, error in
            jsResult = result
            jsError = error
            completed = true
        }

        let deadline = Date().addingTimeInterval(10.0)
        while !completed && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        guard completed else {
            return .error(id: commandId, message: "JavaScript evaluation timed out after 10s.")
        }

        if let error = jsError {
            return .error(id: commandId, message: "JavaScript error: \(error.localizedDescription)")
        }

        let resultString: String
        switch jsResult {
        case let s as String:
            resultString = s
        case let n as NSNumber:
            resultString = n.stringValue
        case is NSNull, nil:
            resultString = "null"
        default:
            resultString = jsResult.map { "\($0)" } ?? "null"
        }

        return .ok(
            id: commandId,
            data: [
                "result": AnyCodable(resultString),
                "url": AnyCodable(webView.url?.absoluteString ?? ""),
            ])
    }
}
