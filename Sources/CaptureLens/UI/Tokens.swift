import AppKit
import SwiftUI

// The design tokens: spacing, corner radii, motion and the few custom surfaces. Views use
// these rather than raw numbers, so a change here changes the whole app. Which to use when
// is in design/DESIGN-SYSTEM.md.

/// Spacing on a 4-point grid.
enum Space {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 24
    static let section: CGFloat = 32
}

/// Corner radii. Nested corners are concentric: inner = outer − the padding between them.
enum Radius {
    /// Thumbnails' pictures, small labels.
    static let xs: CGFloat = 4
    /// Chips, key caps, labels over pictures.
    static let sm: CGFloat = 6
    /// Buttons, selection fills, rail icons.
    static let control: CGFloat = 8
    /// Grouped boxes, bars, popover content.
    static let card: CGFloat = 12
    /// A floating panel holding controls 8 pt in: control + 8.
    static let panel: CGFloat = 16
}

/// Every animation in the app, so they feel alike and all stop under Reduce Motion.
@MainActor
enum Motion {
    /// A hover or a press.
    static var quick: Animation? { reduced ? nil : .easeOut(duration: 0.1) }
    /// A list folding open or closed.
    static var fold: Animation? { reduced ? nil : .easeInOut(duration: 0.15) }
    /// A pane or panel moving.
    static var ui: Animation? { reduced ? nil : .easeInOut(duration: 0.2) }

    private static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

/// The custom surfaces; everything else uses the system's colors.
enum Surfaces {
    /// Behind the picture being viewed or marked up: a mid gray in Light mode, so a white
    /// capture's edges show, and the system's under-page gray in Dark mode.
    static let canvas = NSColor(name: "SnagCanvas") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? .underPageBackgroundColor
            : NSColor(white: 0.80, alpha: 1)
    }

    /// A picture's shadow on the canvas.
    static func shadow(_ layer: CALayer?) {
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.3
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: -2)
    }
}
