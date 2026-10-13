import AppKit
import CoreGraphics

/// Global hold-to-talk on right Option (keycode 61) via a listen-only CGEventTap.
/// Pressing any other key while right ⌥ is held turns it into a normal modifier chord
/// (e.g. ⌥L for @ on German layouts) and cancels the dictation.
final class HotkeyMonitor {
    static let rightOption: Int64 = 61

    var onPress: () -> Void = {}
    var onRelease: () -> Void = {}
    var onChord: () -> Void = {}

    private var tap: CFMachPort?
    private var isDown = false

    /// Returns false when Input Monitoring permission is missing.
    func start() -> Bool {
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon!).takeUnretainedValue()
                monitor.handle(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else { return false }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .keyDown where isDown:
            isDown = false
            onChord()
        case .flagsChanged:
            guard event.getIntegerValueField(.keyboardEventKeycode) == Self.rightOption else {
                // Another modifier joined (e.g. ⌥⇧): treat as a chord, not dictation.
                if isDown { isDown = false; onChord() }
                return
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
    }
}
