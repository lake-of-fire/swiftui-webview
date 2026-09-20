from pathlib import Path
import subprocess
import shutil
import sys

root = Path(sys.argv[1]).resolve()
payload = Path(__file__).parent
source = root / 'Sources/SwiftUIWebView/SwiftUIWebView.swift'
assert subprocess.check_output(['git', '-C', str(root), 'hash-object', str(source)], text=True).strip() == '9fb866a117e9fcb6ea5d3e2a1e13955423af3dfe'
s = source.read_text()
def replace(old, new, count=1):
    global s
    assert s.count(old) == count, (s.count(old), old[:120])
    s = s.replace(old, new)
replace('        let acceptsTrustedUserAction = messageHandlers\n', '''        // Capture application evidence at receipt, before either the broker's
        // deferred admission or the handler scheduler can suspend this event.
        let receiptEvidence = WebViewMessageReceiptCapture.capture(.init(
            name: message.name,
            mainDocumentURL: message.frameInfo.request.mainDocumentURL,
            requestURL: message.frameInfo.request.url
        ))
        let acceptsTrustedUserAction = messageHandlers
''')
for spaces in (12, 20):
    indent = ' ' * spaces
    replace(indent + 'context: documentContext,\n' + indent + 'cancellationHandler:',
            indent + 'context: documentContext,\n' + indent + 'receiptEvidence: receiptEvidence,\n' + indent + 'cancellationHandler:')
replace('        context: WebViewDocumentCallbackContext,\n        cancellationHandler:',
        '        context: WebViewDocumentCallbackContext,\n        receiptEvidence: WebViewMessageReceiptEvidence,\n        cancellationHandler:')
replace('            await handler(message)\n            self.pendingDocumentCallbackTasks',
        '''            await WebViewMessageReceiptContext.$evidence.withValue(receiptEvidence) {
                await handler(message)
            }
            self.pendingDocumentCallbackTasks''')
source.write_text(s)
shutil.copyfile(payload / 'WebViewMessageReceiptEvidence.swift', root / 'Sources/SwiftUIWebView/WebViewMessageReceiptEvidence.swift')
shutil.copyfile(payload / 'WebViewMessageReceiptEvidenceTests.swift', root / 'Tests/SwiftUIWebViewTests/WebViewMessageReceiptEvidenceTests.swift')
(root / 'dev/receipt-evidence').mkdir(parents=True, exist_ok=True)
shutil.copyfile(payload / 'ReceiptHarness.swift', root / 'dev/receipt-evidence/ReceiptHarness.swift')
# Keep the standalone Xcode framework target consistent with SwiftPM's automatic membership.
project = root / 'SwiftUIWebView.xcodeproj/project.pbxproj'
p = project.read_text()
build_id, file_id = 'A71E119A5B7439109F02EA10', 'A71E119A5B7439109F02EA11'
assert build_id not in p and file_id not in p
p = p.replace('/* Begin PBXBuildFile section */', '/* Begin PBXBuildFile section */\n\t\t' + build_id + ' /* WebViewMessageReceiptEvidence.swift in Sources */ = {isa = PBXBuildFile; fileRef = ' + file_id + ' /* WebViewMessageReceiptEvidence.swift */; };', 1)
p = p.replace('/* Begin PBXFileReference section */', '/* Begin PBXFileReference section */\n\t\t' + file_id + ' /* WebViewMessageReceiptEvidence.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = WebViewMessageReceiptEvidence.swift; sourceTree = "<group>"; };', 1)
lines = p.splitlines(keepends=True)
new = []
group_added = phase_added = False
for line in lines:
    new.append(line)
    if '/* SwiftUIWebView.swift */,' in line:
        assert not group_added
        new.append('\t\t\t\t' + file_id + ' /* WebViewMessageReceiptEvidence.swift */,\n')
        group_added = True
    if '/* SwiftUIWebView.swift in Sources */,' in line:
        assert not phase_added
        new.append('\t\t\t\t' + build_id + ' /* WebViewMessageReceiptEvidence.swift in Sources */,\n')
        phase_added = True
assert group_added and phase_added
project.write_text(''.join(new))
