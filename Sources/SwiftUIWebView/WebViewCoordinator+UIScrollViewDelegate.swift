#if os(iOS)
import SwiftUI
import UIKit
import WebKit

extension WebViewCoordinator: UIScrollViewDelegate {
    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView.isTracking || scrollView.isDragging else { return }
        
        let currentOffset = scrollView.contentOffset.y
        let threshold: CGFloat = accumulatedScrollOffset > 0 ? 50.0 : 10.0
        let scrollDifference = currentOffset - lastContentOffset
        accumulatedScrollOffset += scrollDifference
        
        if abs(accumulatedScrollOffset) >= threshold {
            let newValue = accumulatedScrollOffset > 0
            if newValue != hideNavigationDueToScroll.wrappedValue {
#if DEBUG
                debugPrint(
                    "# TABBAR webScrollHideNav",
                    "new=\(newValue)",
                    "old=\(hideNavigationDueToScroll.wrappedValue)",
                    "offset=\(String(format: "%.1f", currentOffset))",
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
}
#endif
