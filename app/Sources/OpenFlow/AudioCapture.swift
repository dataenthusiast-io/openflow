import AVFoundation
import CoreAudio

/// Captures one input device and delivers 16 kHz mono Int16 PCM chunks plus an RMS level.
///
/// The system default input goes through AVAudioEngine. Any other device goes through
/// AVCaptureSession: AVAudioEngine's input node delivers nothing at all once its device is changed
/// (tested with both kAudioOutputUnitProperty_CurrentDevice and auAudioUnit.setDeviceID).
///
/// After a dictation the source can stay "warm" for a while: the next press starts instantly and
/// gets a short pre-roll, so a word started together with the key press isn't clipped.
final class AudioCapture {
    var onAudio: (Data) -> Void = { _ in }
    var onLevel: (Float) -> Void = { _ in }
    var warmSeconds: TimeInterval = 0

    private var source: AudioSource?
    private var sourceUID: String?  // nil = system default
    private var coolDown: DispatchWorkItem?

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
    func begin(device: AudioInputDevice?) throws {
        coolDown?.cancel()
        // The default device takes the AVAudioEngine path even when picked explicitly.
        let uid = device.flatMap { $0.id == AudioDevices.systemDefault() ? nil : $0.uid }
        if source != nil, uid != sourceUID { shutdown() }
        if source == nil {
            let deliver: (UnsafeBufferPointer<Int16>) -> Void = { [weak self] in self?.handle($0) }
            let onLost: () -> Void = { [weak self] in self?.shutdown() }
            source = try uid.map { try SessionSource(uid: $0, deliver: deliver) }
                ?? EngineSource(deliver: deliver, onLost: onLost)
            sourceUID = uid
        }
        lock.lock()
        capturing = true
        sendPreroll = true
        lock.unlock()
    }

    /// Stop delivering audio; keeps the source warm for `warmSeconds`.
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
        source?.stop()
        source = nil
        lock.lock()
        capturing = false
        ring.removeAll()
        lock.unlock()
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

private protocol AudioSource: AnyObject {
    func stop()
}

private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

/// System default input via AVAudioEngine, resampled to 16 kHz Int16.
private final class EngineSource: AudioSource {
    private let engine = AVAudioEngine()
    private var configObserver: NSObjectProtocol?

    init(deliver: @escaping (UnsafeBufferPointer<Int16>) -> Void, onLost: @escaping () -> Void) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, let converter = AVAudioConverter(from: format, to: target) else {
            throw NSError(domain: "OpenFlow", code: 1, userInfo: [NSLocalizedDescriptionKey: "no converter for \(format)"])
        }
        let ratio = target.sampleRate / format.sampleRate

        input.installTap(onBus: 0, bufferSize: 1600, format: format) { buffer, _ in
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var fed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, out.frameLength > 0, let samples = out.int16ChannelData?[0] else { return }
            deliver(UnsafeBufferPointer(start: samples, count: Int(out.frameLength)))
        }
        // Device unplugged or default changed: drop the source; the next press starts a new one.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { _ in onLost() }

        engine.prepare()
        try engine.start()
    }

    func stop() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

/// A specific device via AVCaptureSession; the output converts to 16 kHz mono Int16 itself.
private final class SessionSource: NSObject, AudioSource, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "openflow.capture")
    private let deliver: (UnsafeBufferPointer<Int16>) -> Void
    private var samples: [Int16] = []

    init(uid: String, deliver: @escaping (UnsafeBufferPointer<Int16>) -> Void) throws {
        self.deliver = deliver
        super.init()
        guard let device = AVCaptureDevice(uniqueID: uid) else {
            throw NSError(domain: "OpenFlow", code: 2, userInfo: [NSLocalizedDescriptionKey: "no capture device \(uid)"])
        }
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw NSError(domain: "OpenFlow", code: 3, userInfo: [NSLocalizedDescriptionKey: "cannot capture from \(uid)"])
        }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()
        queue.async { self.session.startRunning() }  // blocks until running; keep it off the main thread
    }

    func stop() {
        queue.async { self.session.stopRunning() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0 else { return }
        samples = [Int16](repeating: 0, count: length / 2)
        samples.withUnsafeMutableBytes { raw in
            _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
        }
        samples.withUnsafeBufferPointer(deliver)
    }
}
