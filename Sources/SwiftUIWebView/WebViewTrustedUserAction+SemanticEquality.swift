import Foundation

public extension WebViewTrustedUserAction {
    /// Trusted-action identity is semantic. The observed click timestamp is
    /// admission metadata used only to bound lifetime; it must not make the
    /// same action/scope/source compare unequal merely because transport
    /// timing differed.
    static func == (
        lhs: WebViewTrustedUserAction,
        rhs: WebViewTrustedUserAction
    ) -> Bool {
        lhs.action == rhs.action
            && lhs.scope == rhs.scope
            && lhs.source == rhs.source
    }
}
