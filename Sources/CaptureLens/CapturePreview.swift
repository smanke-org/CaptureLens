import AppKit
import CaptureLensKit
import SwiftUI

/// The thumbnail that slides into the corner after a capture, like macOS's own: click it to
/// open the capture in the library, drag it into another app, or let it fade.
@MainActor
final class CapturePreview {
    static let shared = CapturePreview()

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private var hovering = false

    func show(_ item: CaptureItem, near frame: CGRect, copied: Bool) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let image = LibraryStore.shared.thumbnail(item) ?? NSImage()
        let view = PreviewView(itemID: item.id, image: image, copied: copied,
                               open: { [weak self] in self?.hide(); LibraryWindow.shared.show(select: item.id) },
                               close: { [weak self] in self?.hide() },
                               hover: { [weak self] in self?.hovering = $0; if !$0 { self?.scheduleHide() } })
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        panel.contentView = hosting
        let screen = NSScreen.screens.first { $0.frame.intersects(frame) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        panel.setFrame(CGRect(x: visible.maxX - size.width - 16, y: visible.minY + 16, width: size.width, height: size.height), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; panel.animator().alphaValue = 1 }
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, !hovering else { return }
            hide()
        }
    }

    func hide() {
        hideTask?.cancel()
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; panel.animator().alphaValue = 0 },
                                             completionHandler: { MainActor.assumeIsolated { panel.orderOut(nil) } })
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return panel
    }
}

private struct PreviewView: View {
    let itemID: UUID
    let image: NSImage
    let copied: Bool
    let open: () -> Void
    let close: () -> Void
    let hover: (Bool) -> Void
    @State private var store = LibraryStore.shared
    @State private var hovered = false

    private var item: CaptureItem? { store.entry(itemID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 220, maxHeight: 150)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.25)))
                .onDrag { dragProvider() }
                .onTapGesture { open() }
            HStack(spacing: 4) {
                if store.analyzing.contains(itemID) {
                    ProgressView().controlSize(.mini)
                    Text("Naming…").foregroundStyle(.secondary)
                } else {
                    Text(item?.name ?? "Saved").lineLimit(1).truncationMode(.middle)
                }
            }
            .font(.callout.weight(.medium))
            .frame(width: 220, alignment: .leading)
            Text(copied ? "Saved to the library and copied" : "Saved to the library")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .topLeading) {
            if hovered {
                Button(action: close) {
                    Image(systemName: "xmark.circle.fill").font(.title3).symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .offset(x: -4, y: -4)
                .help("Close")
            }
        }
        .padding(6)
        .onHover { hovered = $0; hover($0) }
        .help("Click to open in the library. Drag into another app to use it there.")
    }

    private func dragProvider() -> NSItemProvider {
        guard let item, let url = Flattener.temporaryFile(item) else { return NSItemProvider() }
        return NSItemProvider(contentsOf: url) ?? NSItemProvider()
    }
}
