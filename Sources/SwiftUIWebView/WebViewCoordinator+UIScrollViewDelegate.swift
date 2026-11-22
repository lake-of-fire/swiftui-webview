#if os(iOS)
import SwiftUI
import UIKit
import WebKit

extension WebViewCoordinator: UIScrollViewDelegate {
    public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        guard let webView = navigator.webView, webView.scrollView === scrollView else { return }
        navigator.scrollViewSuppressingNavigationReveal = nil
        let ownsCallback = beginScrollCallback(for: webView)
        publishScrollBottomState(for: scrollView)
        guard ownsCallback() else { return }
        lastContentOffset = scrollView.contentOffset
        accumulatedScrollOffset = 0
        refreshNavigationScrollSemantics(scrollView)
    }

    public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard let webView = navigator.webView, webView.scrollView === scrollView else { return }
        navigator.scrollViewSuppressingNavigationReveal = nil
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
            let isVerticalScroll = navigationScrollAxis == .vertical || abs(deltaY) >= abs(deltaX)
            let suppressesHide = newValue && isVerticalScroll
                && shouldSuppressNativeDownwardNavigationHide?() == true
            guard ownsCallback() else { return }
            if !suppressesHide,
               newValue != currentHideNavigationDueToScroll,
               navigator.allowsScrollDrivenNavigationVisibility(newValue, for: scrollView) {
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
    private func beginScrollCallback(for webView: WKWebView) -> @MainActor () -> Bool {
        scrollCallbackGeneration &+= 1
        let generation = scrollCallbackGeneration
        // Retain both participants through this synchronous publication. The
        // release optimizer previously destroyed a local weak capture before
        // its final invocation during native scroll reentry.
        let context = captureDocumentCallbackContext(for: webView)
        let ownsNavigation = navigationCallbackFence(for: webView)
        return {
            self.scrollCallbackGeneration == generation
                && ownsNavigation()
                && self.captureDocumentCallbackContext(for: webView) == context
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
            initialScrollBottomPublication?.rendererWaitState = .retired
            return
        }
        guard scrollBottomObservedScrollView !== scrollView else { return }

        scrollBottomObservedScrollView = scrollView
        lastPublishedScrollBottomState = nil
        initialScrollBottomPublication?.rendererWaitState = .retired
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
        // A retired publication proves this document has already reached finish.
        // Reinstalling its observers must not depend on another finish callback.
        if let webView = navigator.webView,
           webView.scrollView === scrollView,
           let publication = initialScrollBottomPublication,
           publication.context == captureDocumentCallbackContext(for: webView) {
            publishInitialScrollBottomState(for: webView)
        }
    }

    /// A loaded document must reach its reset consumer even with unchanged geometry.
    /// Call after the finish callback, once per active document context.
    @MainActor
    internal func publishInitialScrollBottomState(for webView: WKWebView) {
        guard let context = captureDocumentCallbackContext(for: webView),
              initialScrollBottomPublication?.context != context
                || initialScrollBottomPublication?.rendererWaitState == .retired else { return }
        // Reserve before dispatch: repeated finish must not schedule another replay.
        // A new identity also fences resets that reuse the same document context.
        let publication = InitialScrollBottomPublication(context: context)
        initialScrollBottomPublication = publication
        let binding = javaScriptBindingToken(for: webView)
        let callerGeneration = scriptCallerReplacementGeneration
        // didFinish can precede native geometry delivery. An intervening renderer
        // frame lets WebKit deliver layout without a timer or a DOM scan.
        webView.__callAsyncJavaScript(
            "await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))); return true;",
            arguments: [:], inFrame: nil, in: .defaultClient
        ) { [weak self, weak webView] _, error in
            guard let self, let webView,
                  self.initialScrollBottomPublication === publication,
                  publication.rendererWaitState == .pending,
                  self.ownsDocumentCallbackContext(context) else { return }
            guard self.scriptCallerReplacementGeneration == callerGeneration,
                  self.javaScriptBindingToken(for: webView) == binding else {
                // The document still needs its initial sample. Retire this owner’s
                // reply and wait for layout under the current caller/binding.
                self.initialScrollBottomPublication = nil
                self.publishInitialScrollBottomState(for: webView)
                return
            }
            // Even a failed wait may be followed by a valid native layout event.
            // Open that path without sampling the failed reply or retrying it.
            publication.rendererWaitState = .completed
            guard error == nil else { return }
            self.lastPublishedScrollBottomState = nil
            self.publishScrollBottomState(for: webView.scrollView)
        }
    }

    @MainActor
    internal func publishScrollBottomState(for scrollView: UIScrollView) {
        guard let webView = navigator.webView,
              webView.scrollView === scrollView,
              canPublishScrollBottomState(for: webView),
              let onScrollBottomStateChanged else {
            return
        }

        let isAtEnd = scrollOffsetIsAtEnd(scrollView.contentOffset, in: scrollView)
        guard lastPublishedScrollBottomState != isAtEnd else { return }
        lastPublishedScrollBottomState = isAtEnd
        onScrollBottomStateChanged(isAtEnd)
    }

    private func scrollOffsetIsAtEnd(_ offset: CGPoint, in scrollView: UIScrollView) -> Bool {
        let isAtEnd: Bool
        switch navigationScrollAxis {
        case .vertical:
            let minimumOffset = -scrollView.adjustedContentInset.top
            let maximumOffset = max(
                minimumOffset,
                scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
            )
            isAtEnd = maximumOffset - minimumOffset <= 1
                || offset.y >= maximumOffset - 2
        case .horizontal:
            let minimumOffset = -scrollView.adjustedContentInset.left
            let maximumOffset = max(
                minimumOffset,
                scrollView.contentSize.width - scrollView.bounds.width + scrollView.adjustedContentInset.right
            )
            if maximumOffset - minimumOffset <= 1 {
                isAtEnd = true
            } else if horizontalForwardSign < 0 {
                isAtEnd = offset.x <= minimumOffset + 2
            } else {
                isAtEnd = offset.x >= maximumOffset - 2
            }
        }

        return isAtEnd
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
