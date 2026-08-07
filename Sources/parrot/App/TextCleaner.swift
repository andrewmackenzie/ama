import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// On-device text cleanup for dictated text, using Apple's system language
/// model (Foundation Models, macOS 26+). Removes filler and false starts,
/// fixes punctuation, formats spoken lists, and applies self-corrections —
/// optionally shaped by a per-user writing-style profile.
///
/// Everything runs on-device; nothing is sent anywhere. Any failure returns the
/// original text so dictation never breaks.
enum TextCleaner {
    /// Whether cleanup can run right now (framework present, model available,
    /// Apple Intelligence enabled).
    static var isSupported: Bool {
        unavailableReason == nil
    }

    /// A short reason cleanup is unavailable, or nil when it's ready.
    static var unavailableReason: String? {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return nil
            case .unavailable(.deviceNotEligible):
                return "This Mac doesn't support Apple Intelligence."
            case .unavailable(.appleIntelligenceNotEnabled):
                return "Turn on Apple Intelligence in System Settings."
            case .unavailable(.modelNotReady):
                return "The on-device model is still downloading. Try again shortly."
            case .unavailable:
                return "The on-device model is unavailable right now."
            @unknown default:
                return "The on-device model is unavailable right now."
            }
        }
        return "Requires macOS 26 (Tahoe) or later."
        #else
        return "Requires macOS 26 (Tahoe) or later."
        #endif
    }

    /// Clean `text`, optionally shaped by a writing-style `profile`. Returns the
    /// original text on any failure.
    static func clean(_ text: String, profile: String = "") async -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            guard case .available = SystemLanguageModel.default.availability else { return text }
            do {
                let session = LanguageModelSession(instructions: instructions(profile: profile))
                let response = try await session.respond(to: trimmed)
                let out = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                return out.isEmpty ? text : out
            } catch {
                FileHandle.standardError.write(Data("cleanup failed: \(error)\n".utf8))
                return text
            }
        }
        #endif
        return text
    }

    /// Default writing-style profile, seeded from Andrew's stated preferences.
    /// Editable by the user in Settings.
    static let defaultProfile = """
    Never use em dashes; use periods or commas instead. Keep it concise and direct, no corporate filler or AI-sounding phrases. When the dictation is an email, put the greeting on its own line, then a blank line, then the body; end with "Thanks." on its own line and "--Andrew" on the line after.
    """

    private static func instructions(profile: String) -> String {
        var text = """
        You clean up dictated text. The user spoke this; rewrite it to read well WITHOUT changing meaning or adding anything they did not say.
        - Fix punctuation and capitalization.
        - Remove filler words (um, uh, like, you know) and false starts.
        - If the user corrected themselves (e.g. "Tuesday, no wait, Wednesday"), apply the correction and drop the retracted part.
        - If they dictated a list, format it as a bulleted list.
        - Do not add greetings, sign-offs, or commentary you were not given.
        - Output ONLY the cleaned text, nothing else.
        """
        let p = profile.trimmingCharacters(in: .whitespacesAndNewlines)
        if !p.isEmpty {
            text += "\n\nFollow this user's writing-style and formatting preferences:\n\(p)"
        }
        return text
    }
}
