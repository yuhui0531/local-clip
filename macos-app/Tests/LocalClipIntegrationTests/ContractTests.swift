// 双库链接检查，by AI.Coding。
import Testing
import LocalClipCore
import LocalClipMac
@Test func independentLibraries() { #expect(PasteAction.copy != .directPaste) }
