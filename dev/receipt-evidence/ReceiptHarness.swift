import Foundation

@main struct ReceiptHarness {
    @MainActor static func main() async {
        let key = "receipt-harness-lifetime"
        var lifetime = 1
        WebViewMessageReceiptCapture.register(key: key) { _ in lifetime }
        let header = WebViewMessageReceipt(name: "updateProgress", mainDocumentURL: nil, requestURL: nil)
        let first = WebViewMessageReceiptCapture.capture(header)
        lifetime = 2
        let second = WebViewMessageReceiptCapture.capture(header)
        let retained: Int? = first.value(for: key)
        precondition(retained == 1, "receipt must not reacquire successor")
        await WebViewMessageReceiptContext.$evidence.withValue(first) {
            await Task.yield()
            let current: Int? = WebViewMessageReceiptContext.evidence?.value(for: key)
            precondition(current == 1)
            precondition(current != lifetime, "stale receipt must fail final lifetime admission")
            await WebViewMessageReceiptContext.$evidence.withValue(second) {
                await Task.yield()
                let nested: Int? = WebViewMessageReceiptContext.evidence?.value(for: key)
                precondition(nested == 2)
            }
            let restored: Int? = WebViewMessageReceiptContext.evidence?.value(for: key)
            precondition(restored == 1, "nested delivery must restore its predecessor context")
        }
        precondition(WebViewMessageReceiptContext.evidence == nil)
        let wrongType: String? = first.value(for: key)
        precondition(wrongType == nil)
        print("PASS receipt snapshot, successor rejection, suspension, nested isolation, context cleanup, typed lookup")
    }
}
