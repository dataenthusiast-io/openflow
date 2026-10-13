import AppKit
import ServiceManagement

if CommandLine.arguments.contains("--selftest") {
    let fillers = FillerFilter.selfTest()
    let formatting = TextFormatter.selfTest()
    exit(fillers && formatting ? 0 : 1)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum State { case idle, recording(Date), finishing }

    private let socketPath = NSHomeDirectory() + "/Library/Application Support/OpenFlow/asr.sock"
    private lazy var client = ASRClient(socketPath: socketPath)
    private lazy var sidecar = SidecarManager(
        asrDir: Bundle.main.object(forInfoDictionaryKey: "OpenFlowASRDir") as? String ?? "",
        socketPath: socketPath
    )
    private let hotkey = HotkeyMonitor()
    private let audio = AudioCapture()
    private let overlay = OverlayPanel()

    private var state = State.idle
    private var lang: String?
    private var session = 0
    /// Keeps the mic open briefly after release: people let go while the last syllable is still trailing.
    private let releaseTail: TimeInterval = 0.3
    private var pendingTail: DispatchWorkItem?
    private var statusItem: NSStatusItem!
    private let statusLine = NSMenuItem(title: "ASR: starting…", action: nil, keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")

    func applicationDidFinishLaunching(_ note: Notification) {
        setUpMenu()
        setUpClient()
        AudioCapture.requestPermission { ok in if !ok { NSLog("OpenFlow: microphone permission denied") } }
        _ = TextInserter.hasAccessibility(prompt: true)
        startHotkey()

        if !client.connect() { sidecar.start() }
        scheduleReconnect()
    }

    func applicationWillTerminate(_ note: Notification) { sidecar.stop() }

    // MARK: - Hotkey → audio → ASR

    private func startHotkey() {
        hotkey.onPress = { [weak self] in self?.beginDictation() }
        hotkey.onRelease = { [weak self] in self?.endDictation() }
        hotkey.onChord = { [weak self] in self?.cancelDictation() }
        if !hotkey.start() {
            CGRequestListenEventAccess()  // Input Monitoring prompt; retry until granted
            setStatus("Grant Input Monitoring to OpenFlow")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.startHotkey() }
        }
    }

    private func beginDictation() {
        guard client.isConnected else {
            setStatus("ASR not ready yet")
            return
        }
        flushTail()
        lang = nil
        session += 1
        client.start()
        audio.onAudio = { [client] pcm in client.sendAudio(pcm) }
        audio.onLevel = { [overlay] level in
            DispatchQueue.main.async { overlay.model.level = 0.5 * overlay.model.level + 0.5 * level }  // smooth jitter
        }
        do {
            try audio.start()
        } catch {
            NSLog("OpenFlow: audio start failed: %@", error.localizedDescription)
            client.cancel()
            return
        }
        state = .recording(Date())
        overlay.show()
    }

    private func endDictation() {
        guard case .recording(let started) = state else { return }
        if Date().timeIntervalSince(started) < 0.25 {  // accidental tap
            audio.stop()
            client.cancel()
            state = .idle
            overlay.hide()
            return
        }
        state = .finishing
        overlay.model.finishing = true
        let tail = DispatchWorkItem { [weak self] in self?.flushTail() }
        pendingTail = tail
        DispatchQueue.main.asyncAfter(deadline: .now() + releaseTail, execute: tail)
        let id = session
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in  // safety net
            guard let self, self.session == id, case .finishing = self.state else { return }
            self.state = .idle
            self.overlay.hide()
        }
    }

    /// Stops the post-release tail capture and asks the server for the final transcript.
    private func flushTail() {
        guard let tail = pendingTail else { return }
        tail.cancel()
        pendingTail = nil
        audio.stop()
        client.end()
    }

    private func cancelDictation() {
        guard case .recording = state else { return }
        audio.stop()
        client.cancel()
        state = .idle
        overlay.hide()
    }

    private func setUpClient() {
        client.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .ready:
                self.setStatus("ASR: ready (hold right ⌥ to dictate)")
            case .partial(let text, let lang):
                if case .idle = self.state { return }
                self.overlay.model.update(self.polish(text, lang: lang ?? self.lang))
                if let lang { self.overlay.model.lang = lang; self.lang = lang }
            case .final(let text, let lang):
                if case .finishing = self.state {
                    self.state = .idle
                    self.overlay.hide()
                }
                TextInserter.insert(self.polish(text, lang: lang ?? self.lang))
            case .error(let message):
                NSLog("OpenFlow: ASR error: %@", message)
            case .disconnected:
                self.setStatus("ASR: reconnecting…")
                if case .recording = self.state { self.cancelDictation() }
                self.flushTail()
                self.state = .idle
                self.overlay.hide()
            }
        }
    }

    /// Same cleanup for the live HUD and the paste, so what you see is what gets inserted.
    private func polish(_ text: String, lang: String?) -> String {
        TextFormatter.format(FillerFilter.clean(text, lang: lang))
    }

    private func scheduleReconnect() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            if !self.client.isConnected, !self.client.connect() {
                self.setStatus("ASR: loading model…")
            }
            self.scheduleReconnect()
        }
    }

    // MARK: - Menu bar

    private func setUpMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = Self.menuBarIcon()
        let menu = NSMenu()
        menu.addItem(statusLine)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Restart ASR", action: #selector(restartASR), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Open ASR Log", action: #selector(openLog), keyEquivalent: ""))
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit OpenFlow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for item in menu.items where item.action != nil && item.target == nil && item.action != #selector(NSApplication.terminate(_:)) {
            item.target = self
        }
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        statusItem.menu = menu
    }

    /// Template version of the app icon's five-bar waveform.
    private static func menuBarIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let heights: [CGFloat] = [0.34, 0.62, 1.0, 0.74, 0.42]
            let w: CGFloat = 2, gap: CGFloat = 1.6, maxH: CGFloat = 13
            var x = rect.midX - (CGFloat(heights.count) * w + CGFloat(heights.count - 1) * gap) / 2
            NSColor.black.setFill()
            for h in heights {
                let bh = max(w, maxH * h)
                NSBezierPath(roundedRect: NSRect(x: x, y: rect.midY - bh / 2, width: w, height: bh), xRadius: w / 2, yRadius: w / 2).fill()
                x += w + gap
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "OpenFlow"
        return image
    }

    private func setStatus(_ s: String) {
        statusLine.title = s
        statusItem.button?.appearsDisabled = !client.isConnected
    }

    @objc private func restartASR() {
        setStatus("ASR: restarting…")
        sidecar.restart()
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: sidecar.logPath))
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("OpenFlow: launch at login failed: %@", error.localizedDescription)
        }
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
}

let app = NSApplication.shared
if CommandLine.arguments.contains("--demo") {
    runOverlayDemo()
} else {
    let delegate = AppDelegate()
    app.delegate = delegate
}
app.setActivationPolicy(.accessory)
app.run()
