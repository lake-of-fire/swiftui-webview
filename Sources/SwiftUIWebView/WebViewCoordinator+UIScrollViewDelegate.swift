#if os(iOS)
import SwiftUI
import UIKit
import WebKit

extension WebViewCoordinator: UIScrollViewDelegate {
    public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        guard let webView = navigator.webView, webView.scrollView === scrollView else { return }
        let ownsCallback = beginScrollCallback(for: webView)
        publishScrollBottomState(for: scrollView)
        guard ownsCallback() else { return }
        lastContentOffset = scrollView.contentOffset
        accumulatedScrollOffset = 0
        refreshNavigationScrollSemantics(scrollView)
    }

    public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard let webView = navigator.webView, webView.scrollView === scrollView else { return }
        let ownsCallback = beginScrollCallback(for: webView)
        publishScrollBottomState(for: scrollView)
        guard ownsCallback() else { return }
        guard !decelerate else { return }
        accumulatedScrollOffset = 0
        lastContentOffset = scrollView.contentOffset
        refreshPaginationReadback(reason: "scroll.endDrag")
    }

    public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard let webView = navigator.webView, webView.scrollView === scrollView else { return }
        let ownsCallback = beginScrollCallback(for: webView)
        publishScrollBottomState(for: scrollView)
        guard ownsCallback() else { return }
        accumulatedScrollOffset = 0
        lastContentOffset = scrollView.contentOffset
        refreshPaginationReadback(reason: "scroll.endDecelerating")
    }

    public func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        guard let webView = navigator.webView, webView.scrollView === scrollView else { return }
        let ownsCallback = beginScrollCallback(for: webView)
        publishScrollBottomState(for: scrollView)
        guard ownsCallback() else { return }
        refreshPaginationReadback(reason: "scroll.endAnimation")
    }

    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard let webView = navigator.webView, webView.scrollView === scrollView else { return }
        let ownsCallback = beginScrollCallback(for: webView)
        publishScrollBottomState(for: scrollView)
        guard ownsCallback() else { return }
        guard scrollView.isTracking || scrollView.isDragging else { return }

        let currentOffset = scrollView.contentOffset
        let threshold: CGFloat = accumulatedScrollOffset > 0 ? 50.0 : 10.0
        let deltaX = currentOffset.x - lastContentOffset.x
        let deltaY = currentOffset.y - lastContentOffset.y
        let scrollDifference = resolvedScrollDifference(deltaX: deltaX, deltaY: deltaY)
        accumulatedScrollOffset += scrollDifference

        if abs(accumulatedScrollOffset) >= threshold {
            let newValue = accumulatedScrollOffset > 0
            if newValue != currentHideNavigationDueToScroll {
#if DEBUG
                debugPrint(
                    "# TABBAR webScrollHideNav",
                    "new=\(newValue)",
                    "old=\(currentHideNavigationDueToScroll)",
                    "offsetX=\(String(format: "%.1f", currentOffset.x))",
                    "offsetY=\(String(format: "%.1f", currentOffset.y))",
                    "axis=\(navigationScrollAxis == .horizontal ? "horizontal" : "vertical")",
                    "horizontalSign=\(String(format: "%.1f", horizontalForwardSign))",
                    "delta=\(String(format: "%.1f", scrollDifference))",
                    "accumulated=\(String(format: "%.1f", accumulatedScrollOffset))",
                    "threshold=\(String(format: "%.1f", threshold))"
                )
#endif
                withAnimation(.easeIn(duration: newValue ? 0.3 : 0.1)) {
                    self.setHideNavigationDueToScroll(newValue)
                }
            }
            guard ownsCallback() else { return }
            accumulatedScrollOffset = 0 // Reset after state change
        }

        lastContentOffset = currentOffset
    }

    /// Both bottom-state and navigation bindings can synchronously reenter the delegate.
    private func beginScrollCallback(for webView: WKWebView) -> () -> Bool {
        scrollCallbackGeneration &+= 1
        let generation = scrollCallbackGeneration
        let context = captureDocumentCallbackContext(for: webView)
        let binding = javaScriptBindingToken(for: webView)
        return { [weak self, weak webView] in
            guard let self, let webView else { return false }
            return self.navigator.webView === webView
                && self.scrollCallbackGeneration == generation
                && self.captureDocumentCallbackContext(for: webView) == context
                && self.javaScriptBindingToken(for: webView) == binding
        }
    }

    @MainActor
    internal func installScrollBottomStateObservations(for scrollView: UIScrollView) {
        guard onScrollBottomStateChanged != nil else {
            scrollBottomContentSizeObservation?.invalidate()
            scrollBottomContentSizeObservation = nil
            scrollBottomBoundsObservation?.invalidate()
            scrollBottomBoundsObservation = nil
            scrollBottomContentInsetObservation?.invalidate()
            scrollBottomContentInsetObservation = nil
            scrollBottomObservedScrollView = nil
            lastPublishedScrollBottomState = nil
            return
        }
        guard scrollBottomObservedScrollView !== scrollView else { return }

        scrollBottomObservedScrollView = scrollView
        lastPublishedScrollBottomState = nil
        scrollBottomContentSizeObservation = scrollView.observe(\.contentSize, options: [.initial, .new]) { [weak self, weak scrollView] _, _ in
            Task { @MainActor in
                guard let scrollView else { return }
                self?.publishScrollBottomState(for: scrollView)
            }
        }
        scrollBottomBoundsObservation = scrollView.observe(\.bounds, options: [.initial, .new]) { [weak self, weak scrollView] _, _ in
            Task { @MainActor in
                guard let scrollView else { return }
                self?.publishScrollBottomState(for: scrollView)
            }
        }
        scrollBottomContentInsetObservation = scrollView.observe(\.contentInset, options: [.initial, .new]) { [weak self, weak scrollView] _, _ in
            Task { @MainActor in
                guard let scrollView else { return }
                self?.publishScrollBottomState(for: scrollView)
            }
        }
    }

    @MainActor
    internal func publishScrollBottomState(for scrollView: UIScrollView) {
        guard navigator.webView?.scrollView === scrollView,
              let onScrollBottomStateChanged else {
            return
        }

        let isAtEnd: Bool
        switch navigationScrollAxis {
        case .vertical:
            let minimumOffset = -scrollView.adjustedContentInset.top
            let maximumOffset = max(
                minimumOffset,
                scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
            )
            isAtEnd = maximumOffset - minimumOffset <= 1
                || scrollView.contentOffset.y >= maximumOffset - 2
        case .horizontal:
            let minimumOffset = -scrollView.adjustedContentInset.left
            let maximumOffset = max(
                minimumOffset,
                scrollView.contentSize.width - scrollView.bounds.width + scrollView.adjustedContentInset.right
            )
            if maximumOffset - minimumOffset <= 1 {
                isAtEnd = true
            } else if horizontalForwardSign < 0 {
                isAtEnd = scrollView.contentOffset.x <= minimumOffset + 2
            } else {
                isAtEnd = scrollView.contentOffset.x >= maximumOffset - 2
            }
        }

        guard lastPublishedScrollBottomState != isAtEnd else { return }
        lastPublishedScrollBottomState = isAtEnd
        onScrollBottomStateChanged(isAtEnd)
    }

    private func resolvedScrollDifference(deltaX: CGFloat, deltaY: CGFloat) -> CGFloat {
        let xMagnitude = abs(deltaX)
        let yMagnitude = abs(deltaY)
        switch navigationScrollAxis {
        case .vertical:
            return yMagnitude >= xMagnitude ? deltaY : deltaX
        case .horizontal:
            if xMagnitude >= yMagnitude {
                return deltaX * horizontalForwardSign
            }
            // Keep nav behavior responsive if a gesture jitters across axes.
            return deltaY
        }
    }

    private func refreshNavigationScrollSemantics(_ scrollView: UIScrollView) {
        guard let webView = navigator.webView,
              webView.scrollView === scrollView,
              let documentContext = captureDocumentCallbackContext(for: webView) else { return }
        navigationScrollSemanticsGeneration &+= 1
        let semanticsGeneration = navigationScrollSemanticsGeneration
        let bindingToken = javaScriptBindingToken(for: webView)
        let script = """
        (() => {
          // A page may explicitly override both reader and ordinary document inference.
          try {
            const supplied = window.__swiftUIWebViewNavigationScrollSemantics;
            const value = typeof supplied === 'function' ? supplied() : supplied;
            if (value && (value.axis === 'horizontal' || value.axis === 'vertical')) {
              return {
                axis: value.axis,
                horizontalForwardSign: typeof value.horizontalForwardSign === 'number'
                  && Number.isFinite(value.horizontalForwardSign)
                  && value.horizontalForwardSign < 0 ? -1 : 1
              };
            }
          } catch (_) {
            // A broken optional provider must not suppress document inference.
          }
          const body = document.body;
          const content = document.getElementById('reader-content') || body;
          const computed = content ? getComputedStyle(content) : null;
          const writingMode = String(computed?.writingMode || '').toLowerCase();
          let resolved = null;
          try {
            if (typeof window.manabiResolveReaderWritingDirection === 'function') {
              resolved = window.manabiResolveReaderWritingDirection();
            }
          } catch (_) {
            // Preserve computed-style inference when the optional reader helper fails.
          }
          const isReaderMode = Boolean(body?.classList.contains('readability-mode'));
          const vertical = Boolean(resolved?.vertical) || writingMode.startsWith('vertical');
          const verticalRTL = Boolean(resolved?.verticalRTL) || writingMode.startsWith('vertical-rl');
          if (isReaderMode && vertical) {
            return {
              axis: 'horizontal',
              horizontalForwardSign: verticalRTL ? -1 : 1
            };
          }
          const roots = [document.scrollingElement, body, document.documentElement];
          for (const root of roots) {
            if (!root) continue;
            const mode = String(getComputedStyle(root)?.writingMode || '').toLowerCase();
            if (!mode.startsWith('vertical')) continue;
            return {
              axis: 'horizontal',
              horizontalForwardSign: mode.startsWith('vertical-rl') ? -1 : 1
            };
          }
          return {
            axis: 'vertical',
            horizontalForwardSign: 1
          };
        })();
        """
        webView.evaluateJavaScript(script) { [weak self, weak webView, weak scrollView] value, _ in
            guard let self,
                  let webView,
                  let scrollView,
                  self.navigationScrollSemanticsGeneration == semanticsGeneration,
                  self.ownsDocumentCallbackContext(documentContext),
                  self.javaScriptBindingToken(for: webView) == bindingToken,
                  self.navigator.webView === webView,
                  webView.scrollView === scrollView,
                  let payload = value as? [String: Any] else {
                return
            }
            if let axisRaw = payload["axis"] as? String, axisRaw == "horizontal" {
                self.navigationScrollAxis = .horizontal
            } else {
                self.navigationScrollAxis = .vertical
            }
            if let sign = payload["horizontalForwardSign"] as? Double, sign < 0 {
                self.horizontalForwardSign = -1
            } else {
                self.horizontalForwardSign = 1
            }
        }
    }
}
#endif
