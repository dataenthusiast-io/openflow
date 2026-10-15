import AVFoundation
import CoreAudio

/// True while this process is capturing from any input device (what lights the orange mic dot).
func processHasInputRunning(_ pid: pid_t = getpid()) -> Bool {
    func addr(_ s: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: s, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
    var a = addr(kAudioHardwarePropertyProcessObjectList)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size)
    var objs = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &objs)
    for o in objs {
        var pa = addr(kAudioProcessPropertyPID), p: pid_t = 0, ps = UInt32(MemoryLayout<pid_t>.size)
        AudioObjectGetPropertyData(o, &pa, 0, nil, &ps, &p)
        guard p == pid else { continue }
        var ia = addr(kAudioProcessPropertyIsRunningInput), running: UInt32 = 0, rs = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(o, &ia, 0, nil, &rs, &running)
        return running != 0
    }
    return false
}

/// `open -n OpenFlow.app --args --mictest`: capture from each device, then check the mic is released.
func runMicTest() {
    var out = ""
    func log(_ s: String) { out += s + "\n" }
    func wait(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
    let devices = AudioDevices.inputs()
    log("default \(AudioDevices.systemDefault() ?? 0); devices: " + devices.map { "\($0.id)=\($0.name)" }.joined(separator: ", "))

    func run(_ label: String, device: AudioInputDevice?) {
        let cap = AudioCapture()
        var chunks = 0, samples = 0
        var peak: Float = 0
        cap.onAudio = { d in chunks += 1; samples += d.count / 2 }
        cap.onLevel = { l in peak = max(peak, l) }
        cap.warmSeconds = 1
        do { try cap.begin(device: device) } catch { log("\(label): begin threw \(error)"); return }
        let t0 = Date()
        var first: Double?
        while Date().timeIntervalSince(t0) < 1.2 {
            wait(0.01)
            if first == nil, chunks > 0 { first = Date().timeIntervalSince(t0) * 1000 }
        }
        cap.finish()
        let warm = processHasInputRunning()
        wait(2)
        log(String(format: "%@: %d chunks, %.2f s, peak %.4f, first audio %@ | mic in use while warm: %@, after cool-down: %@",
                   label, chunks, Double(samples) / 16000, peak, first.map { String(format: "%.0f ms", $0) } ?? "never",
                   warm ? "yes" : "no", processHasInputRunning() ? "STILL ON" : "released"))
    }
    run("system default", device: nil)
    for d in devices where !d.name.contains("Teams") { run("\(d.name) (\(d.id))", device: d) }
    try? out.write(toFile: "/tmp/openflow-mictest.txt", atomically: true, encoding: .utf8)
}

/// `open -n OpenFlow.app --args --systemaudiotest`: tap system audio for 8 s (play something meanwhile)
/// and report what arrived. Runs with the app's System Audio Recording permission.
func runSystemAudioTest() {
    var out = ""
    let cap = SystemAudioCapture()
    var chunks = 0, samples = 0
    var peak: Int16 = 0
    cap.onAudio = { d in
        chunks += 1
        samples += d.count / 2
        d.withUnsafeBytes { raw in for v in raw.bindMemory(to: Int16.self) where v.magnitude > peak.magnitude { peak = v } }
    }
    do {
        try cap.start()
        out += cap.details + "\n"
        RunLoop.main.run(until: Date().addingTimeInterval(8))
        cap.stop()
        out += String(format: "%d chunks, %.2f s of audio, peak %d%@\n", chunks, Double(samples) / 16000, Int(peak),
                      peak == 0 ? " (pure silence: nothing played, or the permission isn't active for this process)" : "")
    } catch {
        out += "start failed: \(error.localizedDescription)\n"
    }
    try? out.write(toFile: "/tmp/openflow-systemaudiotest.txt", atomically: true, encoding: .utf8)
}

/// `open -n OpenFlow.app --args --echotest CLIP.wav`: records the default mic while another process
/// plays CLIP through the speakers, without and with macOS voice processing (echo cancellation).
/// Writes levels to /tmp/openflow-echotest.txt and the recordings to /tmp/openflow-echo-{off,on}.caf.
func runEchoTest(clip: String) {
    var out = ""
    func wait(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
    func rms(_ x: ArraySlice<Float>) -> Float { x.isEmpty ? 0 : sqrt(x.reduce(0) { $0 + $1 * $1 } / Float(x.count)) }
    for vp in [false, true] {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        do {
            try input.setVoiceProcessingEnabled(vp)
            if vp { input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min) }
        } catch {
            out += "voice processing \(vp): \(error.localizedDescription)\n"
            continue
        }
        let format = input.outputFormat(forBus: 0)
        var samples: [Float] = []
        let lock = NSLock()
        input.installTap(onBus: 0, bufferSize: 4800, format: format) { buf, _ in
            guard let ch = buf.floatChannelData?[0] else { return }
            lock.lock()
            samples.append(contentsOf: UnsafeBufferPointer(start: ch, count: Int(buf.frameLength)))
            lock.unlock()
        }
        do { try engine.start() } catch { out += "start \(vp): \(error.localizedDescription)\n"; continue }
        wait(1.5)
        lock.lock(); let quietEnd = samples.count; lock.unlock()
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = [clip]
        try? player.run()
        while player.isRunning { wait(0.05) }
        lock.lock(); let playEnd = samples.count; lock.unlock()
        wait(0.5)
        engine.stop()
        input.removeTap(onBus: 0)
        let quiet = rms(samples[0..<quietEnd]), playing = rms(samples[quietEnd..<playEnd])
        out += String(format: "voice processing %@: %.0f Hz × %d ch, room %.4f, while playing %.4f (%.1f dB above room)\n",
                      vp ? "ON " : "OFF", format.sampleRate, format.channelCount, quiet, playing, 20 * log10(max(playing, 1e-6) / max(quiet, 1e-6)))
        let mono = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1)!
        if let file = try? AVAudioFile(forWriting: URL(fileURLWithPath: "/tmp/openflow-echo-\(vp ? "on" : "off").caf"), settings: mono.settings),
           let buf = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: AVAudioFrameCount(samples.count)) {
            buf.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
            try? file.write(from: buf)
        }
        wait(0.5)
    }
    try? out.write(toFile: "/tmp/openflow-echotest.txt", atomically: true, encoding: .utf8)
}
