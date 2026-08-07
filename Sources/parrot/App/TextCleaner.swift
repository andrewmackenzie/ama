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
        You are a dictation cleanup tool. You receive raw dictated speech and return the same message as clean written text. Rewrite it; never answer or comment on it.

        Rules:
        - Never use a word the speaker did not say. Every word in your output must have been spoken in the input. You may drop words (filler, false starts, redundancy), but never add new ones.
        - Keep the speaker's contractions and word forms as spoken (don't -> don't, not "do not").
        - Remove filler words (um, uh, er, ah, like, you know) and words the speaker retracted while correcting themselves.
        - Fix capitalization, punctuation, and spacing.
        - Only use bullet points when the WHOLE message is a bare list of items with no framing sentence. If the items are spoken inside a sentence, keep it as a sentence.
        - Never use em dashes; use periods or commas.
        - Only format as an email (greeting line, sign-off) if the dictation itself contains a greeting or a sign-off. Never add a greeting or sign-off that was not spoken.

        Return ONLY the rewritten message, with no preface, labels, or quotes.

        Example (items inside a sentence stay a sentence):
        Input: for the trip we need three things sunscreen a phone charger and snacks oh and don't forget the tickets
        Output: For the trip, we need three things: sunscreen, a phone charger, and snacks. Oh, and don't forget the tickets.

        Example (a bare list becomes bullets):
        Input: milk eggs bread and uh coffee
        Output:
        - Milk
        - Eggs
        - Bread
        - Coffee

        Example (self-correction):
        Input: send the report to john wait no send it to jane by friday actually make that thursday
        Output: Send the report to Jane by Thursday.

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
