import AVFoundation

func runMicTest() {
    var out = ""
    func log(_ s: String) { out += s + "\n" }
    let devices = AudioDevices.inputs()
    log("default \(AudioDevices.systemDefault() ?? 0); devices: " + devices.map { "\($0.id)=\($0.name)" }.joined(separator: ", "))
    func run(_ label: String, device: AudioInputDevice?) {
        let cap = AudioCapture()
        var chunks = 0, samples = 0
        var peak: Float = 0
        cap.onAudio = { d in chunks += 1; samples += d.count / 2 }
        cap.onLevel = { l in peak = max(peak, l) }
        do { try cap.begin(device: device) } catch { log("\(label): begin threw \(error)"); return }
        let t0 = Date()
        var first: Double?
        while Date().timeIntervalSince(t0) < 1.2 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            if first == nil, chunks > 0 { first = Date().timeIntervalSince(t0) * 1000 }
        }
        cap.finish()
        cap.shutdown()
        log(String(format: "%@: %d chunks, %.2f s, peak %.4f, first audio %@", label, chunks, Double(samples) / 16000, peak,
                   first.map { String(format: "%.0f ms", $0) } ?? "never"))
    }
    run("system default        ", device: nil)
    for d in devices where !d.name.contains("Teams") {
        run("\(d.name) (\(d.id))", device: d)
    }
    run("system default again  ", device: nil)
    try? out.write(toFile: "/tmp/openflow-mictest.txt", atomically: true, encoding: .utf8)
}
