import AVFoundation

/// Captures the default input device and delivers 16 kHz mono Int16 PCM chunks plus an RMS level.
final class AudioCapture {
    private let engine = AVAudioEngine()
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

    var onAudio: (Data) -> Void = { _ in }
    var onLevel: (Float) -> Void = { _ in }

    static func requestPermission(_ done: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { ok in DispatchQueue.main.async { done(ok) } }
    }

    func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: format, to: target) else {
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
            let n = Int(out.frameLength)
            var sum: Float = 0
            for i in 0..<n { let s = Float(samples[i]) / 32768; sum += s * s }
            self.onLevel(sqrt(sum / Float(n)))
            self.onAudio(Data(bytes: samples, count: n * 2))
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}
