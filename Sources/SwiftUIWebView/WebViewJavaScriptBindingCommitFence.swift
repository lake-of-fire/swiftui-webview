import Foundation

/// Thread-safe revocation for work admitted by one JavaScript binding. This
/// carries no document data and never permits an expired binding to revive.
final class WebViewJavaScriptBindingCommitFence: @unchecked Sendable {
    private let lock = NSLock()
    private var current = true

    var isCurrent: Bool {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        current = false
    }
}
