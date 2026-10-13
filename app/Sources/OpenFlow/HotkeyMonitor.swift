import AppKit
import CoreGraphics

/// Global right-Option hotkey via a CGEventTap.
/// Pressing any other key while right ⌥ is held turns it into a normal modifier chord
/// (e.g. ⌥L for @ on German layouts) and reports `onChord` instead.
/// While `escapeIsActive()` returns true, Esc is swallowed and reported as `onEscape`.
final class HotkeyMonitor {
    static let rightOption: Int64 = 61
    static let escape: Int64 = 53

    var onPress: () -> Void = {}
    var onRelease: () -> Void = {}
    var onChord: () -> Void = {}
    var onEscape: () -> Void = {}
    var escapeIsActive: () -> Bool = { false }

    private var tap: CFMachPort?
    private var isDown = false

    /// Returns false while Accessibility / Input Monitoring permission is missing.
    func start() -> Bool {
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,  // not listen-only: needed to swallow Esc
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon!).takeUnretainedValue()
                return monitor.handle(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else { return false }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    /// Returns true to swallow the event.
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .keyDown:
            if event.getIntegerValueField(.keyboardEventKeycode) == Self.escape, escapeIsActive() {
                isDown = false
                onEscape()
                return true
            }
            if isDown {
                isDown = false
                onChord()
            }
        case .flagsChanged:
            guard event.getIntegerValueField(.keyboardEventKeycode) == Self.rightOption else {
                // Another modifier joined (e.g. ⌥⇧): treat as a chord, not dictation.
                if isDown { isDown = false; onChord() }
                return false
            }
            let down = event.flags.contains(.maskAlternate)
            if down && !isDown {
                isDown = true
                onPress()
            } else if !down && isDown {
                isDown = false
                onRelease()
            }
        default:
            break
        }
        return false
    }
}
