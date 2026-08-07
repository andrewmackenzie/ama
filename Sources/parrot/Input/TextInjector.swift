import CoreGraphics
import Foundation

/// Posts a string of text at the current cursor location by synthesizing
/// keyboard events with `CGEventKeyboardSetUnicodeString`. Works in nearly
/// every text field on macOS; some Electron apps and secure password fields
/// can drop characters (platform constraint).
enum TextInjector {
    /// Inject the given text at the current cursor location.
    /// Splits long strings into chunks because the underlying API has a
    /// per-event character limit (~20 chars).
    static func inject(_ text: String) {
        guard !text.isEmpty else { return }

        // A raw "\n" in the Unicode string is dropped by many apps, so multi-line
        // output (lists, emails) mashes together. Split on newlines and press the
        // Return key between lines instead.
        let lines = text.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            if i > 0 { postReturn() }
            injectLine(line)
        }
    }

    private static func injectLine(_ line: String) {
        guard !line.isEmpty else { return }
        let utf16 = Array(line.utf16)
        let chunkSize = 20
        var index = 0
        while index < utf16.count {
            let end = min(index + chunkSize, utf16.count)
            var chunk = Array(utf16[index..<end])
            postChunk(&chunk)
            index = end
        }
    }

    private static func postReturn() {
        // 0x24 = kVK_Return.
        CGEvent(keyboardEventSource: nil, virtualKey: 0x24, keyDown: true)?
            .post(tap: .cgSessionEventTap)
        CGEvent(keyboardEventSource: nil, virtualKey: 0x24, keyDown: false)?
            .post(tap: .cgSessionEventTap)
    }

    private static func postChunk(_ chunk: inout [UniChar]) {
        let length = chunk.count
        guard length > 0 else { return }

        let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
        down?.keyboardSetUnicodeString(stringLength: length, unicodeString: &chunk)
        down?.post(tap: .cgSessionEventTap)

        let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
        up?.keyboardSetUnicodeString(stringLength: length, unicodeString: &chunk)
        up?.post(tap: .cgSessionEventTap)
    }
}
