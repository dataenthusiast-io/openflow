import CoreAudio
import Foundation

struct AudioInputDevice {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let transport: UInt32

    var isBluetooth: Bool {
        transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }
    var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }
}

/// CoreAudio input device lookup.
enum AudioDevices {
    static func inputs() -> [AudioInputDevice] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard inputChannels(id) > 0, let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            return AudioInputDevice(id: id, uid: uid, name: name, transport: uint32(id, kAudioDevicePropertyTransportType) ?? 0)
        }
    }

    static func systemDefault() -> AudioDeviceID? {
        uint32(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice)
    }

    /// Device to record from for a `Settings.microphone` value; nil means "let the system decide".
    /// "auto" avoids Bluetooth headsets: opening their mic drops them into low-quality call audio
    /// (worse transcripts, and your music turns mono) and takes long enough to clip the first word.
    static func resolve(_ setting: String) -> AudioInputDevice? {
        let all = inputs()
        switch setting {
        case "default":
            return nil
        case "auto":
            let current = systemDefault().flatMap { id in all.first { $0.id == id } }
            if let current, current.isBluetooth, let builtIn = all.first(where: \.isBuiltIn) { return builtIn }
            return current
        default:
            return all.first { $0.uid == setting } ?? resolve("auto")
        }
    }

    /// True when the default output is a loudspeaker the mic can hear (built-in speakers, a display,
    /// HDMI, AirPlay), false for headphones of any kind.
    static func outputIsSpeakers() -> Bool {
        guard let out = uint32(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice),
              let transport = uint32(out, kAudioDevicePropertyTransportType) else { return false }
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn:
            // The headphone jack is a data source of the built-in device.
            var addr = address(kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput)
            var source: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            let ok = AudioObjectGetPropertyData(out, &addr, 0, nil, &size, &source) == noErr
            return !(ok && source == 0x6864_706E)  // 'hdpn'
        case kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeAirPlay:
            return true
        default:
            return false
        }
    }

    // MARK: - CoreAudio helpers

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var addr = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &ref) == noErr else { return nil }
        return ref?.takeRetainedValue() as String?
    }

    private static func inputChannels(_ id: AudioDeviceID) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
