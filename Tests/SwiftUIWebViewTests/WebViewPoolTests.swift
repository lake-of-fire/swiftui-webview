import SwiftUI
import WebKit
import XCTest
@testable import SwiftUIWebView

@MainActor
final class WebViewPoolTests: XCTestCase {
#if os(iOS)
    @available(iOS 15.5, *)
    func testZeroInsetsAreConfiguredOnceForEachMountedWebView() {
        let webView = InsetWriteCountingWebView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 844),
            configuration: WKWebViewConfiguration()
        )
        let controller = WebViewController(webView: webView)
        controller.loadViewIfNeeded()
        controller.viewDidLayoutSubviews()
        controller.viewDidLayoutSubviews()
        XCTAssertEqual(webView.obscuredInsetWriteCount, 1,
                       "Explicit zero insets establish the viewport policy on first attachment")
        XCTAssertEqual(webView.unobscuredSafeAreaInsetWriteCount, 1)

        controller.detachWebView()
        controller.replaceWebView(webView)
        XCTAssertEqual(webView.obscuredInsetWriteCount, 2,
                       "Reattaching a pooled view must establish its inset policy again")
        XCTAssertEqual(webView.unobscuredSafeAreaInsetWriteCount, 2)
        controller.viewDidLayoutSubviews()
        XCTAssertEqual(webView.obscuredInsetWriteCount, 2)
        XCTAssertEqual(webView.unobscuredSafeAreaInsetWriteCount, 2)
    }

    @available(iOS 15.5, *)
    func testUnchangedLayoutDoesNotRewriteWebKitInsets() {
        let webView = InsetWriteCountingWebView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 844),
            configuration: WKWebViewConfiguration()
        )
        let controller = WebViewController(webView: webView)
        controller.loadViewIfNeeded()
        controller.view.frame = webView.frame
        controller.obscuredInsets = UIEdgeInsets(top: 59, left: 0, bottom: 150, right: 0)
        controller.viewDidLayoutSubviews()
        webView.resetInsetWriteCounts()

        for _ in 0..<10 {
            controller.viewDidLayoutSubviews()
        }
        let sameInsets = controller.obscuredInsets
        controller.obscuredInsets = sameInsets

        XCTAssertEqual(webView.obscuredInsetWriteCount, 0)
        XCTAssertEqual(webView.unobscuredSafeAreaInsetWriteCount, 0)
        XCTAssertEqual(webView.viewportInsetWriteCount, 0)

        controller.obscuredInsets.bottom = 73
        XCTAssertEqual(webView.obscuredInsetWriteCount, 1)
        XCTAssertEqual(webView.unobscuredSafeAreaInsetWriteCount, 0,
                       "An unchanged safe-area value must stay untouched during a sheet transition")
        XCTAssertEqual(webView.viewportInsetWriteCount, 1)
        XCTAssertEqual(webView.minimumViewportInset.bottom, 73)
        XCTAssertEqual(webView.maximumViewportInset.bottom, 73)
    }

    @available(iOS 15.5, *)
    func testViewportInsetsRetryAfterInitiallyUnusableBounds() {
        let webView = InsetWriteCountingWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let controller = WebViewController(webView: webView)
        controller.loadViewIfNeeded()
        controller.obscuredInsets = UIEdgeInsets(top: 59, left: 0, bottom: 150, right: 0)
        XCTAssertEqual(webView.viewportInsetWriteCount, 0)

        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        webView.frame = controller.view.bounds
        controller.viewDidLayoutSubviews()
        XCTAssertEqual(webView.viewportInsetWriteCount, 1,
                       "Skipping unusable geometry must not suppress the first valid viewport update")
        XCTAssertEqual(webView.minimumViewportInset.top, 59)
        XCTAssertEqual(webView.maximumViewportInset.bottom, 150)
    }

    func testWebNavigationDirectionIgnoresBottomBounceAndShrinkingInset() {
        let coordinator = WebView(
            config: WebViewConfig(reservesDocumentBottomInset: true),
            navigator: WebViewNavigator(),
            state: .constant(.empty)
        ).makeCoordinatorForTesting()
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.contentSize = CGSize(width: 390, height: 2000)
        scrollView.contentInset.bottom = 150
        let compactBottom = CGPoint(x: 0, y: 1306)
        let overscrolled = CGPoint(x: 0, y: 1370)
        XCTAssertEqual(coordinator.navigationScrollOffset(overscrolled, in: scrollView), compactBottom)

        scrollView.contentInset.bottom = 73
        let minimizedBottom = CGPoint(x: 0, y: 1229)
        XCTAssertEqual(coordinator.navigationScrollOffset(compactBottom, in: scrollView), minimizedBottom)
        XCTAssertEqual(coordinator.navigationScrollOffset(overscrolled, in: scrollView), minimizedBottom)
        let reverseScroll = CGPoint(x: 0, y: minimizedBottom.y - 30)
        XCTAssertEqual(coordinator.navigationScrollOffset(reverseScroll, in: scrollView), reverseScroll,
                       "Scrolling back inside the document must still reveal navigation")

        coordinator.config = WebViewConfig(reservesDocumentBottomInset: false)
        XCTAssertEqual(coordinator.navigationScrollOffset(overscrolled, in: scrollView), overscrolled,
                       "Ebook and generic WebView scroll policies are unchanged")
    }

    func testDocumentBottomInsetTracksSheetClearanceAndRestoresForEBookStage() throws {
        let webView = EnhancedWKWebView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 844),
            configuration: WKWebViewConfiguration()
        )
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.contentInset = UIEdgeInsets(top: 7, left: 3, bottom: 12, right: 5)
        let controller = WebViewController(webView: webView)
        controller.loadViewIfNeeded()
        controller.view.frame = webView.frame
        controller.reservesDocumentBottomInset = true

        for bottom: CGFloat in [150, 73, 191, 73, 0] {
            controller.obscuredInsets = UIEdgeInsets(top: 59, left: 0, bottom: bottom, right: 0)
            let chrome = try XCTUnwrap(webView.value(forKey: "obscuredInsets") as? NSValue)
            XCTAssertEqual(chrome.uiEdgeInsetsValue.bottom, bottom)
            XCTAssertEqual(webView.scrollView.contentInset.bottom, max(12, bottom))
            XCTAssertEqual(webView.scrollView.contentInset.top, 7)
            XCTAssertEqual(webView.scrollView.contentInset.left, 3)
            XCTAssertEqual(webView.scrollView.contentInset.right, 5)
        }

        controller.obscuredInsets = UIEdgeInsets(top: 59, left: 0, bottom: 150, right: 0)
        controller.reservesDocumentBottomInset = false
        XCTAssertEqual(webView.scrollView.contentInset.bottom, 12,
                       "Ebook stages retain their existing scrollable inset")
        controller.obscuredInsets = UIEdgeInsets(top: 59, left: 0, bottom: 191, right: 0)
        XCTAssertEqual(webView.scrollView.contentInset.bottom, 12)
    }

    func testDocumentBottomInsetIsReleasedBeforeWebViewReuse() {
        let webView = EnhancedWKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.contentInset.bottom = 9
        let controller = WebViewController(webView: webView)
        controller.loadViewIfNeeded()
        controller.reservesDocumentBottomInset = true
        controller.obscuredInsets = UIEdgeInsets(top: 0, left: 0, bottom: 150, right: 0)
        XCTAssertEqual(webView.scrollView.contentInset.bottom, 150)

        controller.detachWebView()
        XCTAssertEqual(webView.scrollView.contentInset.bottom, 9)
    }

    func testDocumentBottomInsetPolicySurvivesConfigCopies() {
        let config = WebViewConfig(reservesDocumentBottomInset: true)
        XCTAssertTrue(config.withHidesTopScrollEdgeEffect(true).reservesDocumentBottomInset)
        XCTAssertTrue(config.withUserScripts([]).reservesDocumentBottomInset)
        XCTAssertFalse(WebViewConfig().reservesDocumentBottomInset)
    }

    func testWindowSafeAreaProtectsDocumentWhenSampledObscuredInsetIsZero() throws {
        let window = StatusBarInsetTestWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let webView = EnhancedWKWebView(frame: window.bounds, configuration: WKWebViewConfiguration())
        let controller = WebViewController(webView: webView)
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        controller.reservesWindowTopSafeAreaInObscuredInsets = true
        controller.reservesDocumentTopInset = true
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        controller.loadViewIfNeeded()
        controller.view.frame = window.bounds
        controller.obscuredInsets = .zero
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        controller.viewDidLayoutSubviews()
        let value = try XCTUnwrap(webView.value(forKey: "obscuredInsets") as? NSValue)
        XCTAssertGreaterThanOrEqual(value.uiEdgeInsetsValue.top, 59)
        XCTAssertEqual(webView.scrollView.contentInset.top, 59)
        XCTAssertEqual(webView.scrollView.contentOffset.y, -59, accuracy: 0.5)
        webView.scrollView.contentSize = CGSize(width: 390, height: 2000)
        controller.reservesDocumentTopInset = false
        XCTAssertEqual(webView.scrollView.contentInset.top, 0,
                       "Custom ebook stages own their document origin")
        controller.reservesDocumentTopInset = true
        webView.scrollView.contentOffset.y = 200
        controller.obscuredInsets = UIEdgeInsets(top: 96, left: 0, bottom: 34, right: 0)
        let chrome = try XCTUnwrap(webView.value(forKey: "obscuredInsets") as? NSValue)
        XCTAssertEqual(chrome.uiEdgeInsetsValue.top, 96, "Keep larger native chrome clearance")
        XCTAssertEqual(webView.scrollView.contentOffset.y, 200, accuracy: 0.5,
                       "Changing viewport clearance must preserve a restored reading position")
        controller.obscuredInsets = .zero
        controller.view.frame.origin.y = 59
        controller.viewDidLayoutSubviews()
        let belowStatusBar = try XCTUnwrap(webView.value(forKey: "obscuredInsets") as? NSValue)
        XCTAssertEqual(belowStatusBar.uiEdgeInsetsValue.top, 0, "Do not count safe area twice")
        controller.view.frame.origin.y = 0
        controller.viewDidLayoutSubviews()
        let returned = try XCTUnwrap(webView.value(forKey: "obscuredInsets") as? NSValue)
        XCTAssertEqual(returned.uiEdgeInsetsValue.top, 59, "Recompute after the mounted view moves")
        controller.reservesWindowTopSafeAreaInObscuredInsets = false
        let generic = try XCTUnwrap(webView.value(forKey: "obscuredInsets") as? NSValue)
        XCTAssertEqual(generic.uiEdgeInsetsValue.top, 0, "Generic web and overlay views retain their inset policy")
        XCTAssertEqual(webView.scrollView.contentInset.top, 0, "Release reader inset ownership before reuse")
    }
#endif

    func testWarmsReusesCapsAndRemovesWebViews() {
        let pool = WebViewPool(warmUpCount: 1, keepAliveCount: 0)
        var createdCount = 0
        var enqueuedCount = 0
        var dequeuedCount = 0
        pool.onEnqueue = { _ in enqueuedCount += 1 }
        pool.onDequeue = { _ in dequeuedCount += 1 }

        pool.setCreationClosureIfNeeded {
            createdCount += 1
            return EnhancedWKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        }

        XCTAssertEqual(createdCount, 1)
        XCTAssertEqual(pool.retainedCount, 1)
        XCTAssertEqual(enqueuedCount, 1)

        let first = pool.dequeue {
            XCTFail("Expected a warmed web view")
            return EnhancedWKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        }
        XCTAssertEqual(pool.retainedCount, 0)
        XCTAssertEqual(dequeuedCount, 1)

        pool.enqueue(first)
        XCTAssertEqual(pool.retainedCount, 1)
        XCTAssertEqual(enqueuedCount, 2)

        let second = pool.dequeue {
            XCTFail("Expected the original web view to be reused")
            return EnhancedWKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        }
        XCTAssertTrue(first === second)

        pool.enqueue(second)
        let overflow = EnhancedWKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        pool.enqueue(overflow)
        XCTAssertEqual(pool.retainedCount, 1)

        pool.removeAll()
        XCTAssertEqual(pool.retainedCount, 0)
        XCTAssertGreaterThanOrEqual(dequeuedCount, 3)
    }

    func testLegacyRetainedTargetRebalancesWhenCountsDecrease() {
        let pool = WebViewPool(warmUpCount: 2, keepAliveCount: 1)
        var createdCount = 0
        var releasedCount = 0
        pool.onEnqueue = { _ in }
        pool.onDequeue = { _ in releasedCount += 1 }
        pool.setCreationClosureIfNeeded {
            createdCount += 1
            return EnhancedWKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        }

        XCTAssertEqual(pool.retainedCount, 3)
        XCTAssertEqual(createdCount, 3)

        pool.warmUpCount = 1
        XCTAssertEqual(pool.retainedCount, 2)
        XCTAssertEqual(releasedCount, 1)

        pool.keepAliveCount = 0
        XCTAssertEqual(pool.retainedCount, 1)
        XCTAssertEqual(releasedCount, 2)

        pool.warmUpCount = 2
        XCTAssertEqual(pool.retainedCount, 2)
        XCTAssertEqual(createdCount, 4)

        pool.warmUpCount = -1
        XCTAssertEqual(pool.retainedCount, 0)
        XCTAssertEqual(releasedCount, 4)
    }

    func testTotalCountTargetIncludesCheckedOutAndRetainedWebViews() {
        let pool = WebViewPool()
        var createdCount = 0
        pool.setCreationClosureIfNeeded {
            createdCount += 1
            return EnhancedWKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        }

        pool.totalCountTarget = 4
        XCTAssertEqual(createdCount, 4)
        XCTAssertEqual(pool.totalCount, 4)
        XCTAssertEqual(pool.retainedCount, 4)

        let first = pool.dequeue {
            XCTFail("Expected a retained web view")
            return EnhancedWKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        }
        let second = pool.dequeue {
            XCTFail("Expected a retained web view")
            return EnhancedWKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        }
        XCTAssertEqual(pool.totalCount, 4)
        XCTAssertEqual(pool.retainedCount, 2)

        pool.totalCountTarget = 2
        XCTAssertEqual(pool.totalCount, 2)
        XCTAssertEqual(pool.retainedCount, 0)

        pool.enqueue(first)
        XCTAssertEqual(pool.totalCount, 2)
        XCTAssertEqual(pool.retainedCount, 1)

        pool.totalCountTarget = 0
        XCTAssertEqual(pool.totalCount, 1)
        XCTAssertEqual(pool.retainedCount, 0)

        pool.enqueue(second)
        XCTAssertEqual(pool.totalCount, 0)
        XCTAssertEqual(pool.retainedCount, 0)
    }

    func testTotalCountTargetClampsNegativeValues() {
        let pool = WebViewPool()
        pool.totalCountTarget = -4
        XCTAssertEqual(pool.totalCountTarget, 0)
    }

    func testDequeueFallbackFactoryIsNotRetainedByPool() {
        final class Owner {}

        let pool = WebViewPool()
        weak var weakOwner: Owner?

        autoreleasepool {
            var owner: Owner? = Owner()
            weakOwner = owner
            let webView = pool.dequeue { [owner] in
                _ = owner
                return EnhancedWKWebView(
                    frame: .zero,
                    configuration: WKWebViewConfiguration()
                )
            }
            pool.enqueue(webView)
            owner = nil
        }

        XCTAssertNil(weakOwner)

        // A checkout fallback is not silently promoted into the pool's long-lived
        // warming factory. Explicit factory registration remains the only way to
        // create retained views without another checkout.
        pool.totalCountTarget = 1
        XCTAssertEqual(pool.retainedCount, 0)
    }

    func testDequeueUsesCurrentCheckoutFactoryWhenNoRetainedViewExists() {
        let pool = WebViewPool()
        var warmingFactoryCalls = 0
        var checkoutFactoryCalls = 0

        pool.setCreationClosureIfNeeded {
            warmingFactoryCalls += 1
            return EnhancedWKWebView(
                frame: .zero,
                configuration: WKWebViewConfiguration()
            )
        }

        let webView = pool.dequeue {
            checkoutFactoryCalls += 1
            return EnhancedWKWebView(
                frame: .zero,
                configuration: WKWebViewConfiguration()
            )
        }

        XCTAssertEqual(warmingFactoryCalls, 0)
        XCTAssertEqual(checkoutFactoryCalls, 1)
        pool.enqueue(webView)
    }

    func testDequeueUsesCurrentCheckoutFactoryWhenProactiveTopUpIsNeeded() {
        let pool = WebViewPool(warmUpCount: 1)
        var warmingFactoryCalls = 0
        var checkoutFactoryCalls = 0

        pool.setCreationClosureIfNeeded {
            warmingFactoryCalls += 1
            return EnhancedWKWebView(
                frame: .zero,
                configuration: WKWebViewConfiguration()
            )
        }

        let first = pool.dequeue {
            XCTFail("Expected the initially warmed WebView")
            return EnhancedWKWebView(
                frame: .zero,
                configuration: WKWebViewConfiguration()
            )
        }
        XCTAssertEqual(warmingFactoryCalls, 1)
        XCTAssertEqual(pool.retainedCount, 0)

        let second = pool.dequeue {
            checkoutFactoryCalls += 1
            return EnhancedWKWebView(
                frame: .zero,
                configuration: WKWebViewConfiguration()
            )
        }

        XCTAssertEqual(warmingFactoryCalls, 1)
        XCTAssertEqual(checkoutFactoryCalls, 1)
        XCTAssertFalse(first === second)
        pool.enqueue(first)
        pool.enqueue(second)
    }

    func testDetachedFactoryAppliesMediaPlaybackUserActionPolicy() {
        let config = WebViewConfig(
            mediaTypesRequiringUserActionForPlayback: [.audio]
        )
        let sourceView = WebView(
            config: config,
            navigator: WebViewNavigator(),
            state: .constant(.empty)
        )

        let webView = sourceView.makeDetachedWebViewFactory(config: config)()

        XCTAssertEqual(
            webView.configuration.mediaTypesRequiringUserActionForPlayback.rawValue,
            WKAudiovisualMediaTypes.audio.rawValue
        )
    }

    func testDetachedFactoryReportsCompletedConstructionStepsSynchronously() {
        var timings = [WebViewConstructionTiming]()
        let config = WebViewConfig(javaScriptEnabled: false)
        let sourceView = WebView(
            config: config,
            navigator: WebViewNavigator(),
            state: .constant(.empty),
            onConstructionTiming: { timings.append($0) }
        )

        let factory = sourceView.makeDetachedWebViewFactory(config: config)
        XCTAssertEqual(timings.map(\.step), [.websiteDataStore],
                       "Data-store resolution completes before the factory is returned")

        let first = factory()
        XCTAssertEqual(timings.map(\.step), [.websiteDataStore, .configuration, .webView])
        XCTAssertFalse(first.configuration.defaultWebpagePreferences.allowsContentJavaScript)
        XCTAssertTrue(first.configuration.websiteDataStore.isPersistent)

        let second = factory()
        XCTAssertFalse(first === second)
        XCTAssertEqual(timings.map(\.step), [
            .websiteDataStore, .configuration, .webView, .configuration, .webView
        ], "Each factory invocation reports its own completed creation spans")
        XCTAssertTrue(timings.allSatisfy { $0.elapsedMilliseconds.isFinite && $0.elapsedMilliseconds >= 0 })
    }

    func testDetachedProductionFactoryDoesNotRetainSourceNavigatorOrPrewarmer() {
        weak var weakNavigator: WebViewNavigator?
        weak var weakPrewarmer: WebViewPrewarmer?
        var retainedPool: WebViewPool?
        var timings = [WebViewConstructionTiming]()

        autoreleasepool {
            var navigator: WebViewNavigator? = WebViewNavigator()
            var prewarmer: WebViewPrewarmer? = WebViewPrewarmer()
            weakNavigator = navigator
            weakPrewarmer = prewarmer
            retainedPool = prewarmer?.pool

            var sourceView: SwiftUIWebView.WebView? = SwiftUIWebView.WebView(
                navigator: navigator!,
                state: .constant(.empty),
                webViewPrewarmer: prewarmer,
                onConstructionTiming: { timings.append($0) }
            )
            let factory = sourceView!.makeDetachedWebViewFactory(config: .default)
            retainedPool?.setCreationClosureIfNeeded(factory)

            sourceView = nil
            navigator = nil
            prewarmer = nil
        }

        XCTAssertNil(weakNavigator)
        XCTAssertNil(weakPrewarmer)
        XCTAssertEqual(timings.map(\.step), [.websiteDataStore])

        // The detached factory remains usable after the source SwiftUI value and
        // its owners are gone.
        retainedPool?.totalCountTarget = 1
        XCTAssertEqual(retainedPool?.retainedCount, 1)
        XCTAssertEqual(timings.map(\.step), [.websiteDataStore, .configuration, .webView],
                       "The detached timing callback remains usable without retaining the source owners")
        retainedPool?.invalidate()
    }

    func testInvalidateBreaksCreationClosureRetainCycle() {
        weak var weakPool: WebViewPool?

        autoreleasepool {
            var pool: WebViewPool? = WebViewPool()
            weakPool = pool
            pool?.totalCountTarget = 1
            pool?.setCreationClosureIfNeeded { [pool] in
                _ = pool
                return EnhancedWKWebView(frame: .zero, configuration: WKWebViewConfiguration())
            }
            XCTAssertEqual(pool?.totalCount, 1)

            pool?.invalidate()
            XCTAssertEqual(pool?.totalCount, 0)
            let lateView = pool?.dequeue {
                EnhancedWKWebView(frame: .zero, configuration: WKWebViewConfiguration())
            }
            XCTAssertEqual(pool?.totalCount, 0)
            if let lateView {
                pool?.enqueue(lateView)
            }
            XCTAssertEqual(pool?.totalCount, 0)
            pool = nil
        }

        XCTAssertNil(weakPool)
    }

    func testInvalidatedPoolCannotBeReactivatedByLaterTargetUpdates() {
        let pool = WebViewPool(warmUpCount: 1, keepAliveCount: 0)
        pool.setCreationClosureIfNeeded {
            EnhancedWKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        }

        let leased = pool.dequeue {
            XCTFail("Expected the warmed web view")
            return EnhancedWKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        }
        pool.invalidate()

        // Permanent invalidation must outrank late configuration updates and
        // the later return of a WebView that was leased before teardown.
        pool.totalCountTarget = nil
        pool.warmUpCount = 2
        pool.keepAliveCount = 2
        XCTAssertEqual(pool.totalCountTarget, 0)

        pool.enqueue(leased)

        XCTAssertEqual(pool.retainedCount, 0)
        XCTAssertEqual(pool.leasedCount, 0)
        XCTAssertEqual(pool.totalCount, 0)
    }

    func testDequeuePrefersRetainedViewWithMatchingContentID() {
        let pool = WebViewPool()
        pool.totalCountTarget = 2
        pool.setCreationClosureIfNeeded {
            EnhancedWKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        }

        let first = pool.dequeue { fatalError("Expected retained view") }
        let second = pool.dequeue { fatalError("Expected retained view") }
        first.poolReadyContentID = WebViewPoolContentID("page-1")
        second.poolReadyContentID = WebViewPoolContentID("page-2")
        pool.enqueue(first)
        pool.enqueue(second)

        let reused = pool.dequeue(preferredContentID: WebViewPoolContentID("page-2")) {
            fatalError("Expected matching retained view")
        }

        XCTAssertTrue(reused === second)
        XCTAssertEqual(reused.poolReadyContentID, WebViewPoolContentID("page-2"))
    }

    func testDequeueUsesCurrentWebViewContentIdentityInsteadOfEnqueueSnapshot() {
        let pool = WebViewPool()
        pool.totalCountTarget = 2
        pool.setCreationClosureIfNeeded {
            EnhancedWKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        }

        let first = pool.dequeue { fatalError("Expected retained view") }
        let second = pool.dequeue { fatalError("Expected retained view") }
        let preferredContentID = WebViewPoolContentID("preferred")
        first.poolReadyContentID = preferredContentID
        second.poolReadyContentID = WebViewPoolContentID("other")
        pool.enqueue(first)
        pool.enqueue(second)

        // Retained WebViews own their exact navigation/content state. If that
        // state changes while pooled, selection must not use an enqueue-time copy.
        first.poolReadyContentID = nil
        second.poolReadyContentID = preferredContentID

        let reused = pool.dequeue(preferredContentID: preferredContentID) {
            fatalError("Expected matching retained view")
        }

        XCTAssertTrue(reused === second)
        XCTAssertEqual(reused.poolReadyContentID, preferredContentID)
    }

    func testDequeueFallsBackToFIFOWhenNoContentMatches() {
        let pool = WebViewPool()
        pool.totalCountTarget = 2
        pool.setCreationClosureIfNeeded {
            EnhancedWKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        }

        let first = pool.dequeue { fatalError("Expected retained view") }
        let second = pool.dequeue { fatalError("Expected retained view") }
        first.poolReadyContentID = WebViewPoolContentID("page-1")
        second.poolReadyContentID = WebViewPoolContentID("page-2")
        pool.enqueue(first)
        pool.enqueue(second)

        let reused = pool.dequeue(preferredContentID: WebViewPoolContentID("page-3")) {
            fatalError("Expected FIFO retained view")
        }

        XCTAssertTrue(reused === first)
    }

    func testMatchingHTMLContentIDDoesNotReloadAttachedWebView() {
        let contentID = WebViewPoolContentID("page-1")
        let webView = EnhancedWKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.poolReadyContentID = contentID
        let navigator = WebViewNavigator()
        navigator.webView = webView

        navigator.loadHTML("<html>different bytes</html>", contentID: contentID)

        XCTAssertEqual(webView.poolReadyContentID, contentID)
        XCTAssertNil(webView.poolPendingContentID)
    }

    func testNewHTMLContentIDReplacesReadyIdentityUntilNavigationFinishes() {
        let oldID = WebViewPoolContentID("page-1")
        let newID = WebViewPoolContentID("page-2")
        let webView = EnhancedWKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.poolReadyContentID = oldID
        let navigator = WebViewNavigator()
        navigator.webView = webView

        navigator.loadHTML("<html>new page</html>", contentID: newID)

        XCTAssertNil(webView.poolReadyContentID)
        XCTAssertEqual(webView.poolPendingContentID, newID)
    }

    func testBeginningUnkeyedNavigationInvalidatesPendingAndReadyContentIdentity() {
        var gate = WebViewPoolContentNavigationGate<NSObject>()
        gate.setReadyContentID(WebViewPoolContentID("page-1"))
        gate.beginKeyedNavigation(
            contentID: WebViewPoolContentID("page-2"),
            navigation: NSObject()
        )

        gate.beginUnkeyedNavigation()

        XCTAssertNil(gate.pendingContentID)
        XCTAssertNil(gate.readyContentID)
    }

    func testKeyedProvisionalNavigationKeepsItsPendingIdentity() {
        let contentID = WebViewPoolContentID("page-2")
        let navigation = NSObject()
        var gate = WebViewPoolContentNavigationGate<NSObject>()
        gate.beginKeyedNavigation(
            contentID: contentID,
            navigation: navigation
        )

        gate.handleProvisionalNavigationStarted(navigation)

        XCTAssertEqual(gate.pendingContentID, contentID)
    }

    func testSupersededKeyedProvisionalStartCannotClearNewerPooledContentIdentity() {
        let firstNavigation = NSObject()
        let secondNavigation = NSObject()
        let secondContentID = WebViewPoolContentID("page-2")
        var gate = WebViewPoolContentNavigationGate<NSObject>()
        gate.beginKeyedNavigation(
            contentID: WebViewPoolContentID("page-1"),
            navigation: firstNavigation
        )
        gate.beginKeyedNavigation(
            contentID: secondContentID,
            navigation: secondNavigation
        )

        gate.handleProvisionalNavigationStarted(firstNavigation)

        XCTAssertEqual(gate.pendingContentID, secondContentID)
        XCTAssertNil(gate.readyContentID)
    }

    func testSupersededUnkeyedProvisionalStartCannotClearNewerPooledContentIdentity() {
        let firstNavigation = NSObject()
        let secondNavigation = NSObject()
        let secondContentID = WebViewPoolContentID("page-2")
        var gate = WebViewPoolContentNavigationGate<NSObject>()
        gate.beginUnkeyedNavigation(navigation: firstNavigation)
        gate.beginKeyedNavigation(
            contentID: secondContentID,
            navigation: secondNavigation
        )

        gate.handleProvisionalNavigationStarted(firstNavigation)

        XCTAssertEqual(gate.pendingContentID, secondContentID)
        XCTAssertNil(gate.readyContentID)
        XCTAssertFalse(gate.handleNavigationFinished(firstNavigation))
        XCTAssertTrue(gate.handleNavigationFinished(secondNavigation))
        XCTAssertEqual(gate.readyContentID, secondContentID)
    }

    func testNavigationCallbackDispositionDistinguishesCurrentStaleAndUnknownReceipts() {
        let firstNavigation = NSObject()
        let secondNavigation = NSObject()
        let unrelatedNavigation = NSObject()
        var gate = WebViewPoolContentNavigationGate<NSObject>()
        gate.beginUnkeyedNavigation(navigation: firstNavigation)
        gate.beginKeyedNavigation(
            contentID: WebViewPoolContentID("page-2"),
            navigation: secondNavigation
        )

        XCTAssertEqual(
            gate.navigationCallbackDisposition(for: firstNavigation),
            .stale
        )
        XCTAssertEqual(
            gate.navigationCallbackDisposition(for: secondNavigation),
            .current
        )
        XCTAssertEqual(
            gate.navigationCallbackDisposition(for: unrelatedNavigation),
            .unknown
        )
    }

    func testUnknownProvisionalNavigationBecomesCurrentAndInvalidatesKeyedIdentity() {
        let keyedNavigation = NSObject()
        let externalNavigation = NSObject()
        var gate = WebViewPoolContentNavigationGate<NSObject>()
        gate.beginKeyedNavigation(
            contentID: WebViewPoolContentID("page-2"),
            navigation: keyedNavigation
        )

        XCTAssertEqual(
            gate.handleProvisionalNavigationStarted(externalNavigation),
            .current
        )
        XCTAssertNil(gate.pendingContentID)
        XCTAssertNil(gate.readyContentID)
        XCTAssertEqual(
            gate.navigationCallbackDisposition(for: keyedNavigation),
            .stale
        )
        XCTAssertEqual(
            gate.navigationCallbackDisposition(for: externalNavigation),
            .current
        )
    }

    func testUnknownCommitBecomesCurrentAndSupersedesPreviouslyAdmittedReceipt() {
        let admittedNavigation = NSObject()
        let externalNavigation = NSObject()
        let contentID = WebViewPoolContentID("page-2")
        var gate = WebViewPoolContentNavigationGate<NSObject>()
        gate.beginKeyedNavigation(
            contentID: contentID,
            navigation: admittedNavigation
        )

        XCTAssertEqual(
            gate.admitNavigationCallback(externalNavigation),
            .current
        )
        XCTAssertNil(gate.pendingContentID)
        XCTAssertNil(gate.readyContentID)
        XCTAssertEqual(
            gate.navigationCallbackDisposition(for: admittedNavigation),
            .stale
        )
        XCTAssertEqual(
            gate.navigationCallbackDisposition(for: externalNavigation),
            .current
        )
    }

    func testUnknownTerminalCallbackSupersedesPriorReceiptBeforeItResumes() {
        let admittedNavigation = NSObject()
        let externalNavigation = NSObject()
        var gate = WebViewPoolContentNavigationGate<NSObject>()
        gate.beginUnkeyedNavigation(navigation: admittedNavigation)

        XCTAssertEqual(
            gate.admitNavigationCallback(externalNavigation),
            .current
        )
        XCTAssertFalse(gate.handleNavigationFinished(externalNavigation))
        XCTAssertEqual(
            gate.navigationCallbackDisposition(for: admittedNavigation),
            .stale
        )
    }

    func testUnknownProvisionalNavigationPreservesOlderReceiptAsStaleForLaterOwners() {
        let firstNavigation = NSObject()
        let externalNavigation = NSObject()
        let latestNavigation = NSObject()
        let latestContentID = WebViewPoolContentID("page-3")
        var gate = WebViewPoolContentNavigationGate<NSObject>()
        gate.beginKeyedNavigation(
            contentID: WebViewPoolContentID("page-1"),
            navigation: firstNavigation
        )
        gate.handleProvisionalNavigationStarted(externalNavigation)
        gate.beginKeyedNavigation(
            contentID: latestContentID,
            navigation: latestNavigation
        )

        XCTAssertEqual(
            gate.handleProvisionalNavigationStarted(firstNavigation),
            .stale
        )
        XCTAssertEqual(gate.pendingContentID, latestContentID)
        XCTAssertFalse(gate.handleNavigationFinished(firstNavigation))
        XCTAssertTrue(gate.handleNavigationFinished(latestNavigation))
        XCTAssertEqual(gate.readyContentID, latestContentID)
    }

    func testReceiptlessCallbackSupersedesPreviouslyAdmittedNavigation() {
        let admittedNavigation = NSObject()
        var gate = WebViewPoolContentNavigationGate<NSObject>()
        gate.beginKeyedNavigation(
            contentID: WebViewPoolContentID("page-2"),
            navigation: admittedNavigation
        )

        XCTAssertEqual(
            gate.admitNavigationCallback(nil),
            .unknown
        )
        XCTAssertNil(gate.pendingContentID)
        XCTAssertNil(gate.readyContentID)
        XCTAssertEqual(
            gate.navigationCallbackDisposition(for: admittedNavigation),
            .stale
        )
    }

    func testReceiptlessSupersessionMarksPreviouslyAdmittedNavigationStale() {
        let navigation = NSObject()
        var gate = WebViewPoolContentNavigationGate<NSObject>()
        gate.beginKeyedNavigation(
            contentID: WebViewPoolContentID("page-2"),
            navigation: navigation
        )

        gate.beginUnkeyedNavigation()

        XCTAssertEqual(
            gate.navigationCallbackDisposition(for: navigation),
            .stale
        )
    }

    func testPoolResetMakesCancelledNavigationReceiptStaleBeforeReuse() throws {
        let pool = WebViewPool(warmUpCount: 0, keepAliveCount: 1)
        pool.setCreationClosureIfNeeded {
            EnhancedWKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        }
        let webView = pool.dequeue {
            XCTFail("Expected retained WebView")
            return EnhancedWKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        }
        let navigation = try XCTUnwrap(webView.loadHTMLString(
            "<html><body>cancelled</body></html>",
            baseURL: URL(string: "https://example.com/cancelled")
        ))
        webView.beginUnkeyedNavigation(navigation: navigation)

        pool.enqueue(webView)

        XCTAssertEqual(
            webView.navigationCallbackDisposition(navigation),
            .stale
        )
    }

    func testStaleFinishCannotPromoteNewerPooledContentIdentity() {
        let firstNavigation = NSObject()
        let secondNavigation = NSObject()
        let secondContentID = WebViewPoolContentID("page-2")
        var gate = WebViewPoolContentNavigationGate<NSObject>()
        gate.beginKeyedNavigation(
            contentID: WebViewPoolContentID("page-1"),
            navigation: firstNavigation
        )
        gate.beginKeyedNavigation(
            contentID: secondContentID,
            navigation: secondNavigation
        )

        XCTAssertFalse(gate.handleNavigationFinished(firstNavigation))
        XCTAssertNil(gate.readyContentID)
        XCTAssertEqual(gate.pendingContentID, secondContentID)

        XCTAssertTrue(gate.handleNavigationFinished(secondNavigation))
        XCTAssertEqual(gate.readyContentID, secondContentID)
        XCTAssertNil(gate.pendingContentID)
    }

    func testStaleFailureCannotClearNewerPooledContentIdentity() {
        let firstNavigation = NSObject()
        let secondNavigation = NSObject()
        let secondContentID = WebViewPoolContentID("page-2")
        var gate = WebViewPoolContentNavigationGate<NSObject>()
        gate.beginKeyedNavigation(
            contentID: WebViewPoolContentID("page-1"),
            navigation: firstNavigation
        )
        gate.beginKeyedNavigation(
            contentID: secondContentID,
            navigation: secondNavigation
        )

        XCTAssertFalse(gate.handleNavigationFailed(firstNavigation))
        XCTAssertEqual(gate.pendingContentID, secondContentID)

        XCTAssertTrue(gate.handleNavigationFailed(secondNavigation))
        XCTAssertNil(gate.pendingContentID)
        XCTAssertNil(gate.readyContentID)
    }

    func testNonOwningProvisionalNavigationSupersedesPendingPooledContentIdentity() {
        let pendingNavigation = NSObject()
        let unrelatedNavigation = NSObject()
        var gate = WebViewPoolContentNavigationGate<NSObject>()
        gate.beginKeyedNavigation(
            contentID: WebViewPoolContentID("page-2"),
            navigation: pendingNavigation
        )

        gate.handleProvisionalNavigationStarted(unrelatedNavigation)

        XCTAssertNil(gate.pendingContentID)
        XCTAssertNil(gate.readyContentID)
        XCTAssertFalse(gate.handleNavigationFinished(pendingNavigation))
    }

    func testUnknownFailureCannotClearExactPendingPooledContentIdentity() {
        let contentID = WebViewPoolContentID("page-2")
        var gate = WebViewPoolContentNavigationGate<NSObject>()
        gate.beginKeyedNavigation(
            contentID: contentID,
            navigation: NSObject()
        )

        XCTAssertFalse(gate.handleNavigationFailed(nil))
        XCTAssertEqual(gate.pendingContentID, contentID)
    }

    func testTransparentNonScrollingOverlayConfigIsGestureNeutralByDefault() {
        let config = WebViewConfig.transparentNonScrollingOverlay

        XCTAssertTrue(config.javaScriptEnabled)
        XCTAssertFalse(config.allowsBackForwardNavigationGestures)
        XCTAssertFalse(config.dataDetectorsEnabled)
        XCTAssertFalse(config.isScrollEnabled)
        XCTAssertFalse(config.isOpaque)
        XCTAssertFalse(config.adjustsScrollViewContentInsetsForSafeArea)
        XCTAssertFalse(config.nativeLookupHitTestingEnabled)
        XCTAssertEqual(config.paginationConfiguration.mode, .unpaginated)
    }

    func testReplacingUserScriptsPreservesUnrelatedConfiguration() {
        let originalScript = WebViewUserScript(
            source: "window.original = true",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        let replacementScript = WebViewUserScript(
            source: "window.replacement = true",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        let config = WebViewConfig(
            javaScriptEnabled: false,
            contentRules: "[]",
            allowsBackForwardNavigationGestures: false,
            allowsInlineMediaPlayback: false,
            mediaTypesRequiringUserActionForPlayback: [.audio],
            dataDetectorsEnabled: true,
            isScrollEnabled: false,
            pageZoom: 1.5,
            isOpaque: false,
            usesSampledPageTopColorForUnderPageBackground: true,
            usesConfiguredBackgroundForReaderDocuments: true,
            adjustsScrollViewContentInsetsForSafeArea: false,
            hidesTopScrollEdgeEffect: true,
            nativeLookupHitTestingEnabled: false,
            userScripts: [originalScript],
            darkModeSetting: .darkModeOverride
        )

        let replaced = config.withUserScripts([replacementScript], dataDetectorsEnabled: false)

        XCTAssertFalse(replaced.javaScriptEnabled)
        XCTAssertEqual(replaced.contentRules, "[]")
        XCTAssertFalse(replaced.allowsBackForwardNavigationGestures)
        XCTAssertFalse(replaced.allowsInlineMediaPlayback)
        XCTAssertEqual(replaced.mediaTypesRequiringUserActionForPlayback.rawValue, WKAudiovisualMediaTypes.audio.rawValue)
        XCTAssertFalse(replaced.dataDetectorsEnabled)
        XCTAssertFalse(replaced.isScrollEnabled)
        XCTAssertEqual(replaced.pageZoom, 1.5)
        XCTAssertFalse(replaced.isOpaque)
        XCTAssertTrue(replaced.usesSampledPageTopColorForUnderPageBackground)
        XCTAssertTrue(replaced.usesConfiguredBackgroundForReaderDocuments)
        XCTAssertFalse(replaced.adjustsScrollViewContentInsetsForSafeArea)
        XCTAssertTrue(replaced.hidesTopScrollEdgeEffect)
        XCTAssertFalse(replaced.nativeLookupHitTestingEnabled)
        XCTAssertEqual(replaced.userScripts, [replacementScript])
        XCTAssertEqual(replaced.darkModeSetting.rawValue, DarkModeSetting.darkModeOverride.rawValue)
    }

    func testTotalCountTargetIncludesLeasedViewsAndTrimsIdleViews() {
        let pool = WebViewPool()
        pool.totalCountTarget = 3
        var createdCount = 0
        pool.setCreationClosureIfNeeded {
            createdCount += 1
            return EnhancedWKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        }

        XCTAssertEqual(pool.retainedCount, 3)
        XCTAssertEqual(pool.leasedCount, 0)
        XCTAssertEqual(pool.totalCount, 3)

        let first = pool.dequeue {
            XCTFail("Expected a warmed web view")
            return EnhancedWKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        }
        let second = pool.dequeue {
            XCTFail("Expected a warmed web view")
            return EnhancedWKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        }
        XCTAssertEqual(pool.retainedCount, 1)
        XCTAssertEqual(pool.leasedCount, 2)
        XCTAssertEqual(pool.totalCount, 3)

        pool.totalCountTarget = 2
        XCTAssertEqual(pool.retainedCount, 0)
        XCTAssertEqual(pool.leasedCount, 2)
        XCTAssertEqual(pool.totalCount, 2)

        pool.enqueue(first)
        XCTAssertEqual(pool.retainedCount, 1)
        XCTAssertEqual(pool.leasedCount, 1)
        XCTAssertEqual(pool.totalCount, 2)

        pool.totalCountTarget = 1
        XCTAssertEqual(pool.retainedCount, 0)
        XCTAssertEqual(pool.leasedCount, 1)
        XCTAssertEqual(pool.totalCount, 1)

        pool.enqueue(second)
        XCTAssertEqual(pool.retainedCount, 1)
        XCTAssertEqual(pool.leasedCount, 0)
        XCTAssertEqual(pool.totalCount, 1)
        XCTAssertEqual(createdCount, 3)
    }
}

#if os(iOS)
@available(iOS 15.5, *)
@MainActor
private final class InsetWriteCountingWebView: EnhancedWKWebView {
    private(set) var obscuredInsetWriteCount = 0
    private(set) var unobscuredSafeAreaInsetWriteCount = 0
    private(set) var viewportInsetWriteCount = 0

    override func setValue(_ value: Any?, forKey key: String) {
        if key == "obscuredInsets" { obscuredInsetWriteCount += 1 }
        if key == "unobscuredSafeAreaInsets" { unobscuredSafeAreaInsetWriteCount += 1 }
        super.setValue(value, forKey: key)
    }

    override func setMinimumViewportInset(_ minimumViewportInset: UIEdgeInsets, maximumViewportInset: UIEdgeInsets) {
        viewportInsetWriteCount += 1
        super.setMinimumViewportInset(minimumViewportInset, maximumViewportInset: maximumViewportInset)
    }

    func resetInsetWriteCounts() {
        obscuredInsetWriteCount = 0
        unobscuredSafeAreaInsetWriteCount = 0
        viewportInsetWriteCount = 0
    }
}

@MainActor
private final class StatusBarInsetTestWindow: UIWindow {
    override var safeAreaInsets: UIEdgeInsets {
        UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0)
    }
}
#endif
