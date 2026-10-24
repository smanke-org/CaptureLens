import AppKit
import SwiftUI

/// The app's own look: the system's, or always Light or always Dark, without changing the Mac's
/// setting. Kept under "appearance" (synced with the other settings) and applied to every
/// window, menu and popover the app shows. On-screen overlays that set their own look keep it.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    static let key = "appearance"
    static var store: UserDefaults { AppDefaults.store }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    static var current: AppAppearance {
        store.string(forKey: key).flatMap(AppAppearance.init) ?? .system
    }

    @MainActor private static var observer: NSObjectProtocol?
    @MainActor private static var themeObserver: NSObjectProtocol?
    @MainActor private static let systemWindows = NSHashTable<NSWindow>.weakObjects()

    /// Applies the saved choice now and again whenever it changes, from Settings or from
    /// another Mac through settings sync.
    @MainActor static func start() {
        apply()
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                                          object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { apply() }
        }
        themeObserver = DistributedNotificationCenter.default().addObserver(
            forName: .init("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main) { _ in
            // The new style is saved just after the notice goes out.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                MainActor.assumeIsolated { for window in systemWindows.allObjects { window.appearance = systemAppearance } }
            }
        }
    }

    /// The Mac's own look, whatever the app's choice.
    static var systemAppearance: NSAppearance? {
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        let style = CFPreferencesCopyAppValue("AppleInterfaceStyle" as CFString, kCFPreferencesAnyApplication) as? String
        return NSAppearance(named: style == "Dark" ? .darkAqua : .aqua)
    }

    /// Keeps an on-screen overlay on the Mac's own look instead of the app's.
    @MainActor static func followSystem(_ window: NSWindow) {
        systemWindows.add(window)
        window.appearance = systemAppearance
    }

    @MainActor static func apply() {
        let wanted = current.nsAppearance
        if NSApp.appearance?.name != wanted?.name { NSApp.appearance = wanted }
    }
}

/// The System / Light / Dark switch for Settings › General.
struct AppearancePicker: View {
    /// Called after the user picks a new look (for apps whose sync isn't told by defaults).
    var onChange: (() -> Void)? = nil
    @AppStorage(AppAppearance.key, store: AppAppearance.store) private var appearance = AppAppearance.system

    var body: some View {
        Picker("Appearance", selection: Binding(get: { appearance }, set: { appearance = $0; onChange?() })) {
            ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
    }
}

/// The switch with its explanation, as a section of a Settings form.
struct AppearanceSection: View {
    let appName: String
    var onChange: (() -> Void)? = nil

    var body: some View {
        Section {
            AppearancePicker(onChange: onChange)
        } footer: {
            Text(AppAppearance.footer(appName: appName))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

extension AppAppearance {
    static func footer(appName: String) -> String {
        "Light or Dark keeps \(appName) that way whatever the system uses; System follows your Mac."
    }
}
