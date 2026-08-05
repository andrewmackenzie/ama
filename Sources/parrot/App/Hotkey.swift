import CoreGraphics
import Foundation

/// The push-to-talk key the user holds to dictate.
///
/// `Fn` is a pure modifier surfaced through `CGEventFlags.maskSecondaryFn`. The
/// right-side modifiers share their flag mask with their left-side twin
/// (left/right Option both set `.maskAlternate`), so those are disambiguated by
/// hardware keycode in addition to the flag.
enum Hotkey: String, CaseIterable, Codable, Identifiable {
    case fn
    case rightOption
    case rightCommand
    case rightControl

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fn: return "Fn (🌐)"
        case .rightOption: return "Right Option (⌥)"
        case .rightCommand: return "Right Command (⌘)"
        case .rightControl: return "Right Control (⌃)"
        }
    }

    /// Short label for status text, e.g. "Hold Fn to dictate".
    var shortName: String {
        switch self {
        case .fn: return "Fn"
        case .rightOption: return "Right ⌥"
        case .rightCommand: return "Right ⌘"
        case .rightControl: return "Right ⌃"
        }
    }

    /// The modifier flag this hotkey raises while held.
    var flag: CGEventFlags {
        switch self {
        case .fn: return .maskSecondaryFn
        case .rightOption: return .maskAlternate
        case .rightCommand: return .maskCommand
        case .rightControl: return .maskControl
        }
    }

    /// Hardware keycode used to distinguish a right-side modifier from its
    /// left twin. `nil` for Fn (there's only one Fn key).
    var keycode: Int64? {
        switch self {
        case .fn: return nil
        case .rightOption: return 61
        case .rightCommand: return 54
        case .rightControl: return 62
        }
    }

    enum Transition {
        case pressed
        case released
        /// This event doesn't concern our hotkey — leave state untouched.
        case irrelevant
    }

    /// Interpret a `flagsChanged` event as a press/release of this hotkey.
    ///
    /// For Fn we read the flag directly: the `.maskSecondaryFn` bit persists
    /// across other keys' events, so any event reflects Fn's true held state.
    ///
    /// For the right-side modifiers the flag alone is ambiguous — it's shared
    /// with the left twin, and it stays set while *other* keys are pressed
    /// mid-hold. So we only act on events carrying this key's own keycode and
    /// ignore everything else (returning `.irrelevant`), which avoids a false
    /// release when e.g. Shift is tapped while the hotkey is down.
    func transition(for event: CGEvent) -> Transition {
        let flagSet = event.flags.contains(flag)
        guard let keycode else {
            return flagSet ? .pressed : .released
        }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        guard code == keycode else { return .irrelevant }
        return flagSet ? .pressed : .released
    }
}
