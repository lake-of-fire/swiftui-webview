#if os(iOS)
import SwiftUI
import UIKit
import WebKit

extension WebViewCoordinator: UIScrollViewDelegate {
    private func shouldLogLayoutScroll(for scrollView: UIScrollView) -> (WKWebView, WebViewPaginationConfiguration)? {
        guard let webView = navigator.webView, webView.scrollView === scrollView else { return nil }
        let configuration = paginationController.currentState().appliedConfiguration ?? config.paginationConfiguration
        guard webViewLayoutShouldLog(webView: webView, configuration: configuration) else { return nil }
        return (webView, configuration)
    }

    private func layoutPageSignature(scrollView: UIScrollView, configuration: WebViewPaginationConfiguration) -> String {
        let fallbackPageLength = scrollView.contentSize.width > scrollView.bounds.width + 1
            ? scrollView.bounds.width
            : scrollView.bounds.height
        let pageLength = max(configuration.effectivePageLength > 0 ? configuration.effectivePageLength : fallbackPageLength, 1)
        let horizontalPage = Int((scrollView.contentOffset.x / pageLength).rounded())
        let verticalPage = Int((scrollView.contentOffset.y / pageLength).rounded())
        return [
            "\(configuration.mode.rawValue)",
            "\(horizontalPage)",
            "\(verticalPage)",
            "\(Int(scrollView.bounds.width.rounded()))x\(Int(scrollView.bounds.height.rounded()))",
            "\(Int(scrollView.contentSize.width.rounded()))x\(Int(scrollView.contentSize.height.rounded()))"
        ].joined(separator: "|")
    }

    private func logLayoutScroll(_ stage: String, scrollView: UIScrollView, force: Bool = false) {
        guard let (webView, configuration) = shouldLogLayoutScroll(for: scrollView) else { return }
        let signature = layoutPageSignature(scrollView: scrollView, configuration: configuration)
        if !force && signature == lastLayoutScrollPageSignature {
            return
        }
        lastLayoutScrollPageSignature = signature

        var payload = webViewLayoutScrollPayload(webView: webView, configuration: configuration)
        payload["pageSignature"] = signature
        payload["pageCount"] = paginationController.currentState().pageCount ?? -1
        webViewLayoutDebugLog(stage, payload)
    }

    public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        lastContentOffset = scrollView.contentOffset
        accumulatedScrollOffset = 0
        refreshNavigationScrollSemantics(scrollView)
        print(
            "# HIDENAV native.scroll.begin",
            "offsetX=\(String(format: "%.1f", scrollView.contentOffset.x))",
            "offsetY=\(String(format: "%.1f", scrollView.contentOffset.y))",
            "hidden=\(currentHideNavigationDueToScroll)",
            "axis=\(navigationScrollAxis == .horizontal ? "horizontal" : "vertical")"
        )
        logLayoutScroll("scroll.beginDrag", scrollView: scrollView, force: true)
    }

    public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        logLayoutScroll(decelerate ? "scroll.endDrag.decelerating" : "scroll.endDrag", scrollView: scrollView, force: true)
        guard !decelerate else { return }
        accumulatedScrollOffset = 0
        lastContentOffset = scrollView.contentOffset
        refreshPaginationReadback(reason: "scroll.endDrag")
    }

    public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        logLayoutScroll("scroll.endDecelerating", scrollView: scrollView, force: true)
        accumulatedScrollOffset = 0
        lastContentOffset = scrollView.contentOffset
        refreshPaginationReadback(reason: "scroll.endDecelerating")
    }

    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        logLayoutScroll("scroll.pageChanged", scrollView: scrollView)
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
                print(
                    "# HIDENAV native.scroll.threshold",
                    "new=\(newValue)",
                    "old=\(currentHideNavigationDueToScroll)",
                    "offsetX=\(String(format: "%.1f", currentOffset.x))",
                    "offsetY=\(String(format: "%.1f", currentOffset.y))",
                    "deltaX=\(String(format: "%.1f", deltaX))",
                    "deltaY=\(String(format: "%.1f", deltaY))",
                    "resolvedDelta=\(String(format: "%.1f", scrollDifference))",
                    "accumulated=\(String(format: "%.1f", accumulatedScrollOffset))",
                    "threshold=\(String(format: "%.1f", threshold))",
                    "axis=\(navigationScrollAxis == .horizontal ? "horizontal" : "vertical")",
                    "tracking=\(scrollView.isTracking)",
                    "dragging=\(scrollView.isDragging)"
                )
                withAnimation(.easeIn(duration: newValue ? 0.3 : 0.1)) {
                    print(
                        "# HIDENAV native.scroll.apply",
                        "new=\(newValue)",
                        "old=\(self.currentHideNavigationDueToScroll)"
                    )
                    self.setHideNavigationDueToScroll(newValue)
                }
            }
            accumulatedScrollOffset = 0 // Reset after state change
        }

        lastContentOffset = currentOffset
    }

    public func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        logLayoutScroll("scroll.endAnimation", scrollView: scrollView, force: true)
        refreshPaginationReadback(reason: "scroll.endAnimation")
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
        guard let webView = navigator.webView, webView.scrollView === scrollView else { return }
        let script = """
        (() => {
          const body = document.body;
          if (!body) {
            return { axis: 'vertical', horizontalForwardSign: 1 };
          }
          const content = document.getElementById('reader-content') || body;
          const computed = getComputedStyle(content);
          const writingMode = String(computed?.writingMode || '').toLowerCase();
          const resolved = typeof window.manabiResolveReaderWritingDirection === 'function'
            ? window.manabiResolveReaderWritingDirection()
            : null;
          const isReaderMode = body.classList.contains('readability-mode');
          const vertical = Boolean(resolved?.vertical) || writingMode.startsWith('vertical');
          const verticalRTL = Boolean(resolved?.verticalRTL) || writingMode.startsWith('vertical-rl');
          if (isReaderMode && vertical) {
            return {
              axis: 'horizontal',
              horizontalForwardSign: verticalRTL ? -1 : 1
            };
          }
          return {
            axis: 'vertical',
            horizontalForwardSign: 1
          };
        })();
        """
        webView.evaluateJavaScript(script) { [weak self] value, _ in
            guard let self else { return }
            guard let payload = value as? [String: Any] else { return }
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
