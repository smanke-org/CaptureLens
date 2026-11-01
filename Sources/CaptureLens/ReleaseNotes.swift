import AppKit
import Observation
import SwiftUI

/// What changed in each version, from the notes written on its GitHub release.
enum ReleaseNotes {
    struct Entry: Equatable, Identifiable {
        let version: String
        let notes: String
        /// Newer than the version the user had, so marked New.
        var isNew = false
        var id: String { version }
    }

    /// How many releases' notes to show: the latest few give a feel for what's been changing.
    static let recentCount = 5

    /// Where every release's notes can be read.
    static var allReleasesURL: URL { URL(string: "https://github.com/\(UpdateController.repository)/releases")! }

    /// The notes of the most recent published releases up to `through`, newest first: the last
    /// `recentCount`, or more when the user skipped more than that, so every new one shows.
    /// Releases newer than `newAfter` are marked New. Empty if GitHub can't be reached.
    static func fetch(newAfter: String?, through: String) async -> [Entry] {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(UpdateController.repository)/releases?per_page=50")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("\(AppInfo.name)/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let releases = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        let entries: [Entry] = releases.compactMap { release in
            guard release["draft"] as? Bool != true, release["prerelease"] as? Bool != true,
                  let tag = release["tag_name"] as? String else { return nil }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            guard !UpdateController.isNewer(version, than: through) else { return nil }
            let isNew = newAfter.map { UpdateController.isNewer(version, than: $0) } ?? (version == through)
            return Entry(version: version, notes: (release["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                         isNew: isNew)
        }
        let sorted = entries.sorted { UpdateController.isNewer($0.version, than: $1.version) }
        return Array(sorted.prefix(max(recentCount, sorted.count { $0.isNew })))
    }

    /// A release body as styled text: **bold**, *italic*, `code` and links work, and list
    /// items get bullets.
    static func attributed(_ notes: String) -> AttributedString {
        let lines = notes.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map { line in
            var text = String(line)
            if text.hasPrefix("- ") || text.hasPrefix("* ") { text = "•  " + text.dropFirst(2) }
            // Headings read as bold lines.
            if let range = text.range(of: #"^#{1,6}\s+"#, options: .regularExpression) { text = "**\(text[range.upperBound...])**" }
            return text
        }
        let markdown = lines.joined(separator: "\n")
        return (try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(markdown)
    }
}

/// The notes for one or more versions, newest first, scrolling when they're long.
struct ReleaseNotesList: View {
    let entries: [ReleaseNotes.Entry]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text("Version \(entry.version)").font(.headline)
                            if entry.isNew {
                                Text("New")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(Color.accentColor.opacity(0.18), in: Capsule())
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        Text(entry.notes.isEmpty ? AttributedString("No notes for this version.") : ReleaseNotes.attributed(entry.notes))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
    }
}

/// After an update the user didn't see the notes for (one that installed itself, or one
/// installed by a version before this window existed), Settings shows what changed the next
/// time it opens, until they tick "Don't show this again" or a newer update arrives.
@Observable
@MainActor
final class WhatsNew {
    static let shared = WhatsNew()

    /// The version updated from ("" when unknown), and the version now running.
    private(set) var pending: (from: String, version: String)?

    private static let pendingFromKey = "whatsNew.from"
    private static let pendingVersionKey = "whatsNew.version"
    /// The version this Mac last ran, to notice an update however it was installed.
    private static let lastLaunchedKey = "update.lastLaunchedVersion"
    /// The version whose notes were shown in the install prompt, so they aren't shown twice.
    static let shownInPromptKey = "whatsNew.shownInPrompt"

    private init() {
        if let version = AppDefaults.store.string(forKey: Self.pendingVersionKey), version == AppInfo.version {
            pending = (AppDefaults.store.string(forKey: Self.pendingFromKey) ?? "", version)
        }
    }

    /// At launch: if this is a newer version than last time, keep its notes for Settings.
    /// - Parameter autoInstalledFrom: the version an automatic update replaced, if it was one.
    func noteLaunch(newInstall: Bool, autoInstalledFrom: String?) {
        let store = AppDefaults.store
        let last = store.string(forKey: Self.lastLaunchedKey)
        store.set(AppInfo.version, forKey: Self.lastLaunchedKey)
        guard !newInstall else { return }
        let from = autoInstalledFrom ?? last
        if let from, !UpdateController.isNewer(AppInfo.version, than: from) { return }
        // No record at all means an earlier version without this window: show this version's notes.
        if store.string(forKey: Self.shownInPromptKey) == AppInfo.version { return }
        pending = (from ?? "", AppInfo.version)
        store.set(from ?? "", forKey: Self.pendingFromKey)
        store.set(AppInfo.version, forKey: Self.pendingVersionKey)
    }

    func dismiss(forGood: Bool) {
        guard forGood else { return }
        pending = nil
        AppDefaults.store.removeObject(forKey: Self.pendingFromKey)
        AppDefaults.store.removeObject(forKey: Self.pendingVersionKey)
    }

    /// Shows the notes over `window` as a sheet: the pending ones, or this version's when the
    /// user asked for them.
    func present(on window: NSWindow, asked: Bool = false) {
        guard window.attachedSheet == nil, asked || pending != nil else { return }
        let from = asked ? nil : pending.flatMap { $0.from.isEmpty ? nil : $0.from }
        let sheet = NSWindow(contentViewController: NSHostingController(rootView: WhatsNewSheet(from: from, offerDismiss: !asked) { [weak window] forGood in
            if !asked { WhatsNew.shared.dismiss(forGood: forGood) }
            if let sheet = window?.attachedSheet { window?.endSheet(sheet) }
        }))
        window.beginSheet(sheet)
    }
}

private struct WhatsNewSheet: View {
    /// The version updated from, when known: the notes cover everything since.
    let from: String?
    /// Whether to offer "Don't show this again" (not when the user asked to see the notes).
    let offerDismiss: Bool
    let done: (_ forGood: Bool) -> Void

    @State private var entries: [ReleaseNotes.Entry]?
    @State private var dontShowAgain = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text("What's new in \(AppInfo.name) \(AppInfo.labeledVersion)").font(.title3.weight(.semibold))
                    if let from { Text("Updated from \(from).").foregroundStyle(.secondary) }
                }
            }
            Group {
                if let entries, !entries.isEmpty {
                    ReleaseNotesList(entries: entries)
                } else if entries != nil {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("The notes couldn't be loaded right now.")
                        Link("Read them on GitHub", destination: ReleaseNotes.allReleasesURL)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(height: 300)
            HStack {
                if offerDismiss { Toggle("Don't show this again", isOn: $dontShowAgain) }
                Spacer()
                Button("OK") { done(dontShowAgain) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .task { entries = await ReleaseNotes.fetch(newAfter: from, through: AppInfo.version) }
    }
}
