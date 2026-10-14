import AVFoundation
import CoreAudio

/// Everything the Mac plays (the other side of a call) via a Core Audio process tap, as 16 kHz mono
/// Int16 chunks like AudioCapture. OpenFlow's own sounds are excluded when CoreAudio knows the process.
/// The first start asks for "System Audio Recording" permission; until it is granted the tap delivers silence.
final class SystemAudioCapture {
    var onAudio: (Data) -> Void = { _ in }
    /// What start() set up, for --systemaudiotest.
    private(set) var details = ""

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "openflow.systemaudio")

    func start() throws {
        stop()
        let tap = CATapDescription(stereoGlobalTapButExcludeProcesses: Self.ownProcess().map { [$0] } ?? [])
        tap.uuid = UUID()
        tap.muteBehavior = .unmuted
        tap.isPrivate = true
        try check(AudioHardwareCreateProcessTap(tap, &tapID), "create process tap")

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = Self.address(kAudioTapPropertyFormat)
        try check(AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd), "read tap format")

        // The tap has to live in an aggregate device to be read. Tap only, no output sub-device: an
        // aggregate that includes Bluetooth headphones can cut their playback.
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "OpenFlow System Audio",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [] as [Any],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: false, kAudioSubTapUIDKey: tap.uuid.uuidString]],
        ]
        try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID), "create aggregate device")

        details = "output \(Self.defaultOutputUID() ?? "none"), tap \(asbd.mSampleRate) Hz × \(asbd.mChannelsPerFrame) ch, "
            + "excluding own process: \(Self.ownProcess() != nil)"
        guard let format = AVAudioFormat(streamDescription: &asbd),
              let converter = AVAudioConverter(from: format, to: pcm16k) else {
            throw NSError(domain: "OpenFlow", code: 4, userInfo: [NSLocalizedDescriptionKey: "no converter for system audio"])
        }
        converter.downmix = true
        let ratio = pcm16k.sampleRate / format.sampleRate
        let deliver = { [weak self] (data: Data) in self?.onAudio(data) }

        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, input, _, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil),
                  buffer.frameLength > 0 else { return }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: pcm16k, frameCapacity: capacity) else { return }
            var fed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, out.frameLength > 0, let samples = out.int16ChannelData?[0] else { return }
            deliver(Data(bytes: samples, count: Int(out.frameLength) * 2))
        }, "create IO proc")
        try check(AudioDeviceStart(aggregateID, procID), "start system audio")
    }

    func stop() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private func check(_ status: OSStatus, _ what: String) throws {
        guard status != noErr else { return }
        stop()
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "\(what) failed (\(status))"])
    }

    // MARK: - CoreAudio helpers

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    /// Our own CoreAudio process object; it only exists once the process has touched audio.
    private static func ownProcess() -> AudioObjectID? {
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    private static func defaultOutputUID() -> String? {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr else { return nil }
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        addr = address(kAudioDevicePropertyDeviceUID)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &uid) == noErr else { return nil }
        return uid?.takeRetainedValue() as String?
    }
}

private let pcm16k = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
