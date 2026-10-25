#if DEBUG
import AppKit
import CaptureLensKit

/// Debug builds only: runs scrolling capture's camera and stitcher over a real area of the
/// screen, for a window another app scrolls by itself, so no input has to be faked.
/// `CAPTURELENS_DEBUG_SCROLL=<x>,<y>,<w>,<h>,<seconds>,<out folder>` takes the area in
/// global Cocoa coordinates, writes each frame's result to `scroll.txt`, the first and last
/// frames, and the stitched picture to `stitched.png`, then quits.
@MainActor
enum DebugScrollTest {
    static func run(spec: String) {
        let parts = spec.split(separator: ",", maxSplits: 5).map(String.init)
        guard parts.count == 6, let x = Double(parts[0]), let y = Double(parts[1]), let w = Double(parts[2]),
              let h = Double(parts[3]), let seconds = Double(parts[4]) else { exit(2) }
        let out = URL(fileURLWithPath: parts[5])
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let frame = CGRect(x: x, y: y, width: w, height: h)
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) else { exit(3) }
        let region = ScreenRegion(displayID: screen.displayID,
                                  rect: CGRect(x: frame.minX - screen.frame.minX, y: screen.frame.maxY - frame.maxY,
                                               width: w, height: h))
        Task {
            var log: [String] = ["region \(region.rect) on \(screen.localizedName)"]
            func write() { try? log.joined(separator: "\n").write(to: out.appending(path: "scroll.txt"), atomically: true, encoding: .utf8) }
            func save(_ image: CGImage?, _ name: String) {
                guard let image else { return }
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: out.appending(path: name))
            }
            let camera = RegionCamera(displayID: region.displayID, sourceRect: region.rect)
            let worker = StitchWorker()
            let end = Date().addingTimeInterval(seconds)
            var first: CGImage?, last: CGImage?
            while Date() < end {
                do {
                    let image = try await camera.capture()
                    if first == nil { first = image }
                    last = image
                    let result = await worker.add(image)
                    save(image, String(format: "f%03d.png", log.count))
                    log.append("\(Date().timeIntervalSince(end) + seconds) \(image.width)×\(image.height) \(result) height \(await worker.height)")
                } catch {
                    log.append("capture failed: \(error.localizedDescription)")
                }
                write()
                try? await Task.sleep(for: .milliseconds(110))
            }
            save(first, "first.png")
            save(last, "last.png")
            let stitched = await worker.image()
            save(stitched, "stitched.png")
            log.append("stitched \(stitched.map { "\($0.width)×\($0.height)" } ?? "nil")")
            write()
            NSApp.terminate(nil)
        }
    }
}
#endif
