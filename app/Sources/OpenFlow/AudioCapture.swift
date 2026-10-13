import AVFoundation
import CoreAudio

/// Captures one input device and delivers 16 kHz mono Int16 PCM chunks plus an RMS level.
///
/// After a dictation the engine can stay "warm" for a while: the next press starts instantly and
/// gets a short pre-roll, so a word started together with the key press isn't clipped.
final class AudioCapture {
    var onAudio: (Data) -> Void = { _ in }
    var onLevel: (Float) -> Void = { _ in }
    var warmSeconds: TimeInterval = 0

    private var engine: AVAudioEngine?
    private var deviceID: AudioDeviceID?
    private var coolDown: DispatchWorkItem?
    private var configObserver: NSObjectProtocol?
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

    // Shared with the audio thread.
    private let lock = NSLock()
    private var capturing = false
    private var sendPreroll = false
    private var ring: [Int16] = []
    private static let prerollSamples = 16_000 * 3 / 10  // 300 ms

    static func requestPermission(_ done: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { ok in DispatchQueue.main.async { done(ok) } }
    }

    /// Start delivering audio from `device` (nil = system default input).
    func begin(device: AudioDeviceID?) throws {
        coolDown?.cancel()
        if engine != nil, device != deviceID { shutdown() }
        if engine == nil { try startEngine(device: device) }
        lock.lock()
        capturing = true
        sendPreroll = true
        lock.unlock()
    }

    /// Stop delivering audio; keeps the engine warm for `warmSeconds`.
    func finish() {
        lock.lock()
        capturing = false
        ring.removeAll(keepingCapacity: true)
        lock.unlock()
        guard warmSeconds > 0 else { return shutdown() }
        let work = DispatchWorkItem { [weak self] in self?.shutdown() }
        coolDown = work
        DispatchQueue.main.asyncAfter(deadline: .now() + warmSeconds, execute: work)
    }

    func shutdown() {
        coolDown?.cancel()
        coolDown = nil
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        lock.lock()
        capturing = false
        ring.removeAll()
        lock.unlock()
    }

    private func startEngine(device: AudioDeviceID?) throws {
        let engine = AVAudioEngine()  // fresh engine per device: the input node caches its format
        let input = engine.inputNode
        if var id = device, let unit = input.audioUnit {
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            if status != noErr { NSLog("OpenFlow: could not select input device %u (%d)", id, status) }
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, let converter = AVAudioConverter(from: format, to: target) else {
            throw NSError(domain: "OpenFlow", code: 1, userInfo: [NSLocalizedDescriptionKey: "no converter for \(format)"])
        }
        let ratio = target.sampleRate / format.sampleRate

        input.installTap(onBus: 0, bufferSize: 1600, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: self.target, frameCapacity: capacity) else { return }
            var fed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, out.frameLength > 0, let samples = out.int16ChannelData?[0] else { return }
            self.handle(UnsafeBufferPointer(start: samples, count: Int(out.frameLength)))
        }
        // Device unplugged or default changed: drop the engine; the next press starts a new one.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in self?.shutdown() }

        engine.prepare()
        try engine.start()
        self.engine = engine
        deviceID = device
    }

    /// Audio thread: ring-buffer while warm, deliver (pre-roll first) while capturing.
    private func handle(_ samples: UnsafeBufferPointer<Int16>) {
        var chunk: [Int16]?
        lock.lock()
        if capturing {
            if sendPreroll {
                chunk = ring + samples
                ring.removeAll(keepingCapacity: true)
                sendPreroll = false
            } else {
                chunk = Array(samples)
            }
        } else {
            ring.append(contentsOf: samples)
            if ring.count > Self.prerollSamples { ring.removeFirst(ring.count - Self.prerollSamples) }
        }
        lock.unlock()
        guard let chunk else { return }

        var sum: Float = 0
        for s in samples { let f = Float(s) / 32768; sum += f * f }
        onLevel(sqrt(sum / Float(max(1, samples.count))))
        chunk.withUnsafeBytes { onAudio(Data($0)) }
    }
}
