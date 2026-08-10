import AppKit
import SwiftUI

/// A newer release advertised by the appcast.
struct AvailableUpdate: Equatable {
    let shortVersion: String   // e.g. "0.1.35"
    let build: Int             // e.g. 35  (CFBundleVersion / commit count)
    let pkgURL: URL
}

/// Lightweight update checker — no Sparkle. Periodically (and on demand) fetches
/// the Sparkle-style appcast, compares its build number to the running app, and
/// exposes `available` so the title-bar pill can light up. Acting on the update
/// downloads the notarized `.pkg` to ~/Downloads and opens it (Installer).
@MainActor
final class UpdateChecker: ObservableObject {
    static let feedURL = URL(string: "https://www.capstannetworks.com/ama/ama.xml")!
    /// How often to check in the background.
    private static let interval: TimeInterval = 86_400   // 24h

    @Published private(set) var available: AvailableUpdate?
    @Published private(set) var isChecking = false
    @Published private(set) var isDownloading = false

    private var timer: Timer?

    var currentBuild: Int {
        Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0") ?? 0
    }

    /// Check shortly after launch, then daily.
    func start() {
        // Dev/test aid: `AMA_FAKE_UPDATE=1` lights the pill without a real release.
        if ProcessInfo.processInfo.environment["AMA_FAKE_UPDATE"] != nil {
            available = AvailableUpdate(shortVersion: "9.9.9", build: 99_999,
                                        pkgURL: URL(string: "https://www.capstannetworks.com/ama/Ama.pkg")!)
            return
        }
        Task { await check() }
        let t = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Fetch the appcast and update `available`. Silent — never shows a dialog.
    func check() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        do {
            var request = URLRequest(url: Self.feedURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData   // always see the latest feed
            let (data, _) = try await URLSession.shared.data(for: request)
            if let info = Self.parse(data), info.build > currentBuild {
                available = info
            } else {
                available = nil
            }
        } catch {
            // Leave `available` as-is on a network failure; try again next tick.
        }
    }

    /// Download the update's pkg to ~/Downloads and open it (launches Installer).
    func downloadAndOpen() {
        guard let update = available, !isDownloading else { return }
        isDownloading = true
        Task {
            defer { isDownloading = false }
            do {
                let (tmp, _) = try await URLSession.shared.download(from: update.pkgURL)
                let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
                let dest = downloads.appendingPathComponent("Ama.pkg")
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: tmp, to: dest)
                NSWorkspace.shared.open(dest)
            } catch {
                // Fall back to just opening the URL in the browser so the user
                // can still get the installer.
                NSWorkspace.shared.open(update.pkgURL)
            }
        }
    }

    // MARK: - Appcast parsing

    /// Pull build / shortVersion / pkg URL from the first <item>. Uses
    /// local-name() XPath so the `sparkle:` namespace prefix doesn't matter.
    static func parse(_ data: Data) -> AvailableUpdate? {
        guard let doc = try? XMLDocument(data: data) else { return nil }
        func first(_ xpath: String) -> String? {
            guard let node = try? doc.nodes(forXPath: xpath).first else { return nil }
            return node.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let item = "(//*[local-name()='item'])[1]"
        guard
            let buildStr = first("\(item)/*[local-name()='version']"),
            let build = Int(buildStr),
            let urlStr = first("\(item)/*[local-name()='enclosure']/@url"),
            let url = URL(string: urlStr)
        else { return nil }
        let short = first("\(item)/*[local-name()='shortVersionString']")
            ?? first("\(item)/*[local-name()='title']")
            ?? buildStr
        return AvailableUpdate(shortVersion: short, build: build, pkgURL: url)
    }
}

/// The green "Update available" pill for the window title bar. Empty (zero size)
/// when there's no update, so it never occupies the title bar otherwise.
struct UpdatePillView: View {
    @ObservedObject var checker: UpdateChecker

    var body: some View {
        if let update = checker.available {
            Button {
                checker.downloadAndOpen()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: checker.isDownloading ? "arrow.down.circle" : "arrow.down.circle.fill")
                        .imageScale(.small)
                    Text(checker.isDownloading ? "Downloading…" : "Update available")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(Color.green, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(checker.isDownloading)
            .help("Version \(update.shortVersion) is available — click to download and install")
            .padding(.trailing, 10)
            .padding(.vertical, 4)
        } else {
            Color.clear.frame(width: 0, height: 0)
        }
    }
}
