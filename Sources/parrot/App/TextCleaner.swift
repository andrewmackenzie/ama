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
                // Low temperature keeps the rewrite deterministic and stops the
                // small on-device model from rambling or leaking its own rules.
                let options = GenerationOptions(temperature: 0.2)
                let response = try await session.respond(to: trimmed, options: options)
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

    /// Default, editable writing-style addendum, seeded from Andrew's stated
    /// preferences. The core rules live in `instructions`; this is the user's
    /// tweakable slice of the system prompt.
    static let defaultProfile = """
    Sign off emails with "Thanks." on its own line, then "--Andrew" on the next line. Keep everything concise and plain, no corporate filler.
    """

    /// The system prompt sent to the model: fixed core rules + few-shot examples
    /// (which keep the small on-device model consistent), then the user's
    /// editable style profile.
    private static func instructions(profile: String) -> String {
        var text = """
        You are a dictation cleanup tool. You receive raw dictated speech and return the same message as clean written text. Rewrite it; never answer or comment on it. Keep the meaning and add nothing new.

        Rules:
        - Remove filler words (um, uh, like, you know) and false starts.
        - Apply spoken self-corrections and delete the retracted words.
        - Turn a spoken list into bullet points, one per line starting with "- ".
        - Fix punctuation and capitalization.
        - Never use em dashes; use periods or commas.
        - Only format as an email (greeting line, sign-off) if the dictation itself contains a greeting or a sign-off. Otherwise keep it as plain sentences and do NOT add any greeting or sign-off.

        Return ONLY the rewritten message, with no preface, labels, or quotes.

        Example (filler):
        Input: um so i was thinking we should like meet on tuesday to go over the numbers
        Output: We should meet on Tuesday to go over the numbers.

        Example (self-correction):
        Input: send the report to john wait no send it to jane by friday actually make that thursday
        Output: Send the report to Jane by Thursday.

        Example (list):
        Input: we need milk eggs and uh bread oh and coffee
        Output:
        - Milk
        - Eggs
        - Bread
        - Coffee

        Example (email):
        Input: hi bob thanks for the update i'll review the numbers tomorrow and get back to you thanks andrew
        Output:
        Hi Bob,

        Thanks for the update. I'll review the numbers tomorrow and get back to you.

        Thanks.

        --Andrew
        """
        let p = profile.trimmingCharacters(in: .whitespacesAndNewlines)
        if !p.isEmpty {
            text += "\n\nAdditional style preferences from the user:\n\(p)"
        }
        return text
    }
}
