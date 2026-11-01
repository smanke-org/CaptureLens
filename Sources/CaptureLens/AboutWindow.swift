import AppKit
import SwiftUI

/// About SnagAnything: the icon, version and copyright, then what changed in the last 10
/// releases, from their GitHub release notes. (The standard About panel can't show notes
/// that arrive after it opens.)
@MainActor
final class AboutWindow {
    static let shared = AboutWindow()

    /// How many releases' notes it shows.
    static let releaseCount = 10

    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: AboutView()))
            window.title = "About \(AppInfo.name)"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    #if DEBUG
    var debugWindow: NSWindow? { window }
    #endif
}

private struct AboutView: View {
    @State private var entries: [ReleaseNotes.Entry]?

    private var copyright: String {
        Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text(AppInfo.name).font(.title2.weight(.semibold))
                    Text("Version \(AppInfo.labeledVersion)").foregroundStyle(.secondary)
                    if !copyright.isEmpty { Text(copyright).font(.caption).foregroundStyle(.secondary) }
                }
            }
            Text("Recent releases").font(.headline)
            Group {
                if let entries, !entries.isEmpty {
                    ReleaseNotesList(entries: entries)
                } else if entries != nil {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("The release notes couldn't be loaded right now.")
                        Link("Read them on GitHub", destination: ReleaseNotes.allReleasesURL)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(height: 360)
            HStack {
                Link("All releases on GitHub", destination: ReleaseNotes.allReleasesURL)
                Spacer()
            }
        }
        .padding(20)
        .frame(width: 500)
        // Up to the version running; newer ones are the update prompt's to show.
        .task { entries = await ReleaseNotes.fetch(newAfter: AppInfo.version, through: AppInfo.version,
                                                  count: AboutWindow.releaseCount) }
    }
}
