#if os(iOS)
import SwiftUI
import UIKit
import WebKit

extension WebViewCoordinator: UIScrollViewDelegate {
    public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        lastContentOffset = scrollView.contentOffset
        accumulatedScrollOffset = 0
        refreshNavigationScrollSemantics(scrollView)
    }

    public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard !decelerate else { return }
        accumulatedScrollOffset = 0
        lastContentOffset = scrollView.contentOffset
    }

    public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        accumulatedScrollOffset = 0
        lastContentOffset = scrollView.contentOffset
    }

    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView.isTracking || scrollView.isDragging else { return }

        let currentOffset = scrollView.contentOffset
        let threshold: CGFloat = accumulatedScrollOffset > 0 ? 50.0 : 10.0
        let deltaX = currentOffset.x - lastContentOffset.x
        let deltaY = currentOffset.y - lastContentOffset.y
        let scrollDifference = resolvedScrollDifference(deltaX: deltaX, deltaY: deltaY)
        accumulatedScrollOffset += scrollDifference

        if abs(accumulatedScrollOffset) >= threshold {
            let newValue = accumulatedScrollOffset > 0
            if newValue != hideNavigationDueToScroll.wrappedValue {
#if DEBUG
                debugPrint(
                    "# TABBAR webScrollHideNav",
                    "new=\(newValue)",
                    "old=\(hideNavigationDueToScroll.wrappedValue)",
                    "offsetX=\(String(format: "%.1f", currentOffset.x))",
                    "offsetY=\(String(format: "%.1f", currentOffset.y))",
                    "axis=\(navigationScrollAxis == .horizontal ? "horizontal" : "vertical")",
                    "horizontalSign=\(String(format: "%.1f", horizontalForwardSign))",
                    "delta=\(String(format: "%.1f", scrollDifference))",
                    "accumulated=\(String(format: "%.1f", accumulatedScrollOffset))",
                    "threshold=\(String(format: "%.1f", threshold))"
                )
#endif
                DispatchQueue.main.async {
                    withAnimation(.easeIn(duration: newValue ? 0.3 : 0.1)) {
                        self.hideNavigationDueToScroll.wrappedValue = newValue
                    }
                }
            }
            accumulatedScrollOffset = 0 // Reset after state change
        }

        lastContentOffset = currentOffset
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
