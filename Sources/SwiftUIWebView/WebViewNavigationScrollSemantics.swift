/// Shared JavaScript expression for the active document’s primary scroll axis and forward sign.
/// Evaluate in the page content world to use the document’s Reader and explicit-provider overrides.
public enum WebViewNavigationScrollSemantics {
    public static let javaScript: String = """
    (() => {
      // A page may explicitly override both reader and ordinary document inference.
      try {
        const supplied = window.__swiftUIWebViewNavigationScrollSemantics
        const value = typeof supplied === 'function' ? supplied() : supplied
        if (value && (value.axis === 'horizontal' || value.axis === 'vertical')) {
          return {
            axis: value.axis,
            horizontalForwardSign: typeof value.horizontalForwardSign === 'number'
              && Number.isFinite(value.horizontalForwardSign)
              && value.horizontalForwardSign < 0 ? -1 : 1
          }
        }
      } catch (_) {
        // A broken optional provider must not suppress document inference.
      }
      const body = document.body
      const content = document.getElementById('reader-content') || body
      const computed = content ? getComputedStyle(content) : null
      const writingMode = String(computed?.writingMode || '').toLowerCase()
      let resolved = null
      try {
        if (typeof window.manabiResolveReaderWritingDirection === 'function') {
          resolved = window.manabiResolveReaderWritingDirection()
        }
      } catch (_) {
        // Preserve computed-style inference when the optional reader helper fails.
      }
      const isReaderMode = Boolean(body?.classList.contains('readability-mode'))
      const vertical = Boolean(resolved?.vertical) || writingMode.startsWith('vertical')
      const verticalRTL = Boolean(resolved?.verticalRTL) || writingMode.startsWith('vertical-rl')
      if (isReaderMode && vertical) {
        return {
          axis: 'horizontal',
          horizontalForwardSign: verticalRTL ? -1 : 1
        }
      }
      const roots = [document.scrollingElement, body, document.documentElement]
      for (const root of roots) {
        if (!root) continue
        const mode = String(getComputedStyle(root)?.writingMode || '').toLowerCase()
        if (!mode.startsWith('vertical')) continue
        return {
          axis: 'horizontal',
          horizontalForwardSign: mode.startsWith('vertical-rl') ? -1 : 1
        }
      }
      return {
        axis: 'vertical',
        horizontalForwardSign: 1
      }
    })()
    """
}
