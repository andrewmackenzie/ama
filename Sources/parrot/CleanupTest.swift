import ArgumentParser
import Foundation

/// Hidden developer command: run the on-device cleanup over a batch of noisy
/// sample dictations and print before/after, using the *live* Settings
/// (`cleanupSystemPrompt` + `writingStyle`) so it exercises exactly what ships.
///
///   ama cleanup-test              # built-in samples
///   echo "raw text" | ama cleanup-test --stdin
struct CleanupTest: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cleanup-test",
        abstract: "Dev-only: exercise TextCleaner over sample dictations.",
        shouldDisplay: false
    )

    @Flag(name: .long, help: "Read one sample from stdin instead of the built-ins.")
    var stdin: Bool = false

    /// Realistic noisy transcripts: filler, false starts, the target proper-noun
    /// mishears, plus a homophone that must NOT be rewritten.
    static let samples: [String] = [
        "so um i think we need to um talk to the client about uh the the renewal you know",
        "send the invoice to bob wait no send it to the finance team by uh friday actually thursday",
        "i asked clawed to refactor the code and clod suggested a cleaner approach",
        "we should push the config profile through a diggy to all the managed max",
        "the installomator label runs install a mator to update the app silently",
        "log into moselle and then check the cap stan tenant for the enrollment",
        "there was not a cloud in the sky during the whole hike honestly",
        "um so basically i think we need to like get the the update out to ama users before uh friday",
        "run make pkg with the no notarize flag so it builds faster while iterating",
        "i actually tested it on the m2 and it actually works now which is great",
    ]

    func run() throws {
        let d = UserDefaults(suiteName: "com.capstannetworks.ama") ?? .standard
        let sys = d.string(forKey: "cleanupSystemPrompt") ?? TextCleaner.defaultSystemPrompt
        let profile = d.string(forKey: "writingStyle") ?? TextCleaner.defaultProfile
        let corrections = d.string(forKey: "cleanupCorrections") ?? TextCleaner.defaultCorrections

        if let reason = TextCleaner.unavailableReason {
            FileHandle.standardError.write(Data("cleanup unavailable: \(reason)\n".utf8))
            throw ExitCode(2)
        }

        let inputs: [String]
        if stdin {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            inputs = [String(decoding: data, as: UTF8.self)]
        } else {
            inputs = Self.samples
        }

        // Bridge the async cleanup into this sync command.
        let sem = DispatchSemaphore(value: 0)
        Task {
            await TextCleaner.prewarm()
            for (i, raw) in inputs.enumerated() {
                let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                let started = Date()
                let out = await TextCleaner.clean(t, systemPrompt: sys, profile: profile, corrections: corrections)
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                let changed = out != t
                print("── [\(i + 1)/\(inputs.count)]  \(ms) ms  \(changed ? "CHANGED" : "unchanged")")
                print("BEFORE: \(t)")
                print("AFTER : \(out)")
                print("")
            }
            sem.signal()
        }
        sem.wait()
    }
}
