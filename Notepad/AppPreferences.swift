import AppKit
import SwiftUI

// MARK: - Paper Theme

/// Controls the background and text color of the editor/table content area.
/// The window frame (toolbar, status bar, title bar) always follows the
/// system appearance — only the "paper" (NSTextView / table area) is themed.
enum PaperTheme: String, CaseIterable, Equatable {
    case system = "system"   // auto — follows macOS day/night
    case light  = "light"    // always white
    case dark   = "dark"     // always dark
    case sepia  = "sepia"    // warm cream

    var menuLabel: String {
        switch self {
        case .system: return "System (Auto)"
        case .light:  return "Light"
        case .dark:   return "Dark"
        case .sepia:  return "Sepia"
        }
    }

    /// The NSAppearance to force on the content view (nil = inherit system).
    /// Forcing the appearance ensures system-adaptive colors like .systemBlue
    /// render as their correct light/dark variants inside the text view.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light:  return NSAppearance(named: .aqua)
        case .dark:   return NSAppearance(named: .darkAqua)
        case .sepia:  return NSAppearance(named: .aqua)
        }
    }

    /// Background color of the text/table area.
    var paperColor: NSColor {
        switch self {
        case .system: return .textBackgroundColor           // adapts automatically
        case .light:  return .white
        case .dark:   return NSColor(calibratedWhite: 0.11, alpha: 1)
        case .sepia:  return NSColor(calibratedRed: 0.974, green: 0.941, blue: 0.876, alpha: 1)
        }
    }

    /// Primary text color drawn on the paper.
    var inkColor: NSColor {
        switch self {
        case .system: return .labelColor                    // adapts automatically
        case .light:  return NSColor(calibratedWhite: 0.07, alpha: 1)
        case .dark:   return NSColor(calibratedWhite: 0.88, alpha: 1)
        case .sepia:  return NSColor(calibratedWhite: 0.16, alpha: 1)
        }
    }

    /// Secondary / muted text color (row numbers, placeholders).
    var mutedColor: NSColor {
        switch self {
        case .system: return .tertiaryLabelColor
        case .light:  return NSColor(calibratedWhite: 0.60, alpha: 1)
        case .dark:   return NSColor(calibratedWhite: 0.50, alpha: 1)
        case .sepia:  return NSColor(calibratedWhite: 0.50, alpha: 1)
        }
    }

    /// Separator / gutter background color.
    var gutterColor: NSColor {
        switch self {
        case .system: return .controlBackgroundColor
        case .light:  return NSColor(calibratedWhite: 0.95, alpha: 1)
        case .dark:   return NSColor(calibratedWhite: 0.16, alpha: 1)
        case .sepia:  return NSColor(calibratedRed: 0.945, green: 0.906, blue: 0.830, alpha: 1)
        }
    }
}

// MARK: - App Preferences

/// Global, persisted app preferences. @Observable so any coordinator's
/// withObservationTracking chain re-fires when paperTheme changes.
@Observable
final class AppPreferences {
    static let shared = AppPreferences()

    var paperTheme: PaperTheme {
        didSet {
            UserDefaults.standard.set(paperTheme.rawValue, forKey: "paperTheme")
        }
    }

    private init() {
        if let raw   = UserDefaults.standard.string(forKey: "paperTheme"),
           let saved = PaperTheme(rawValue: raw) {
            paperTheme = saved
        } else {
            paperTheme = .system
        }
    }
}
