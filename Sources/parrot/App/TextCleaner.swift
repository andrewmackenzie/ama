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

    /// Load the on-device language model ahead of time so the first real cleanup
    /// isn't slow. No-op if cleanup is unavailable. Safe to call repeatedly.
    static func prewarm() async {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            guard case .available = SystemLanguageModel.default.availability else { return }
            let session = LanguageModelSession(instructions: "You clean up dictated text.")
            _ = try? await session.respond(
                to: "Input: hello there\nOutput:",
                options: GenerationOptions(temperature: 0.2)
            )
        }
        #endif
    }

    /// Clean `text`, optionally shaped by a writing-style `profile` and a
    /// per-app `context` hint. Returns the original text on any failure.
    static func clean(_ text: String, systemPrompt: String = defaultSystemPrompt, profile: String = "", context: String? = nil) async -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            guard case .available = SystemLanguageModel.default.availability else { return text }
            let session = LanguageModelSession(instructions: instructions(systemPrompt: systemPrompt, profile: profile, context: context))
            // Low temperature keeps the rewrite deterministic and stops the
            // small on-device model from rambling or leaking its own rules.
            // Cap output length so a runaway generation (small models sometimes
            // loop and emit tokens up to the model's hard limit) can't spin
            // forever. Cleanup output tracks the input length, so scale the cap
            // to it with generous headroom.
            let wordCount = trimmed.split(whereSeparator: \.isWhitespace).count
            let maxTokens = min(2000, max(128, wordCount * 4))
            let options = GenerationOptions(temperature: 0.2, maximumResponseTokens: maxTokens)
            // Frame the request in the same Input:/Output: shape as the few-shot
            // examples. Handing the model a bare sentence makes the small
            // on-device model *answer* it (chat) instead of cleaning it; the
            // completion framing keeps it in transform mode.
            let prompt = "Input: \(trimmed)\nOutput:"
            // Stream the rewrite with an *inactivity* watchdog rather than an
            // overall deadline. A long dictation (a two-minute clip) legitimately
            // takes many seconds to clean, so a fixed total timeout would wrongly
            // abort it. Cleanup runs on the ANE, which can stall under system
            // contention — but a stall shows up as *no new tokens*, while healthy
            // generation streams steadily. So we only give up if nothing new
            // arrives for `idleTimeout`, and fall back to the raw transcript.
            let stream = session.streamResponse(to: prompt, options: options)
            guard let raw = await collectWithIdleTimeout(stream, idleTimeout: 8) else {
                return text
            }
            var out = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // Defensively strip an echoed "Output:" label if the model adds one.
            if out.lowercased().hasPrefix("output:") {
                out = String(out.dropFirst("Output:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return out.isEmpty ? text : out
        }
        #endif
        return text
    }

    #if canImport(FoundationModels)
    /// Consume a cleanup stream, giving up only if it produces nothing new for
    /// `idleTimeout` seconds (a stalled ANE), never on total elapsed time (a long
    /// dictation). Returns the final text, or nil if it stalled or errored.
    @available(macOS 26, *)
    private static func collectWithIdleTimeout(
        _ stream: LanguageModelSession.ResponseStream<String>,
        idleTimeout: TimeInterval
    ) async -> String? {
        let progress = StreamProgress()
        let producer = Task {
            do {
                for try await snapshot in stream {
                    await progress.push(snapshot.content)
                }
                await progress.finish(failed: false)
            } catch {
                FileHandle.standardError.write(Data("cleanup failed: \(error)\n".utf8))
                await progress.finish(failed: true)
            }
        }
        let poll: TimeInterval = 0.5
        var lastSeen = -1
        var idle: TimeInterval = 0
        while true {
            let s = await progress.state()
            if s.done {
                return s.failed ? nil : s.latest
            }
            if s.updates != lastSeen {
                lastSeen = s.updates
                idle = 0
            } else {
                idle += poll
                if idle >= idleTimeout {
                    producer.cancel()
                    return nil
                }
            }
            try? await Task.sleep(nanoseconds: UInt64(poll * 1_000_000_000))
        }
    }

    /// Shared progress between the stream producer and the idle watchdog.
    /// `updates` is a monotonic tick bumped on every snapshot, so the watchdog
    /// can detect "no new tokens" without comparing text.
    @available(macOS 26, *)
    private actor StreamProgress {
        private var latest = ""
        private var updates = 0
        private var done = false
        private var failed = false
        func push(_ s: String) { latest = s; updates += 1 }
        func finish(failed: Bool) { self.failed = failed; done = true }
        func state() -> (latest: String, updates: Int, done: Bool, failed: Bool) {
            (latest, updates, done, failed)
        }
    }
    #endif

    /// Default, editable writing-style addendum, seeded from Andrew's stated
    /// preferences. The core rules live in `instructions`; this is the user's
    /// tweakable slice of the system prompt.
    static let defaultProfile = """
    Sign off emails with "Thanks." on its own line, then "--Andrew" on the next line. Keep everything concise and plain, no corporate filler.
    """

    /// The default cleanup system prompt: fixed core rules + few-shot examples
    /// that keep the small on-device model consistent. Advanced users can
    /// override this in Settings; an empty override falls back to this.
    static let defaultSystemPrompt = """
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

        Example (a statement or question is cleaned, NOT answered — never reply to the content):
        Input: so um i think we need to have breakfast and uh what time works for you
        Output: So, I think we need to have breakfast. What time works for you?

        Example (email):
        Input: hi bob thanks for the update i'll review the numbers tomorrow and get back to you thanks andrew
        Output:
        Hi Bob,

        Thanks for the update. I'll review the numbers tomorrow and get back to you.

        Thanks.

        --Andrew
        """

    /// Assemble the full instructions: the (possibly user-edited) system prompt,
    /// then per-app context and the user's editable style profile.
    private static func instructions(systemPrompt: String, profile: String, context: String?) -> String {
        var text = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { text = defaultSystemPrompt }
        if let context, !context.isEmpty {
            text += "\n\nContext:\n\(context)"
        }
        let p = profile.trimmingCharacters(in: .whitespacesAndNewlines)
        if !p.isEmpty {
            text += "\n\nAdditional style preferences from the user:\n\(p)"
        }
        return text
    }
}
