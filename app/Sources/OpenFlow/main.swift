import AppKit
import ServiceManagement

if CommandLine.arguments.contains("--selftest") {
    let fillers = FillerFilter.selfTest()
    let formatting = TextFormatter.selfTest()
    let echo = Transcriber.echoSelfTest()
    exit(fillers && formatting && echo ? 0 : 1)
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// recording: key held (or locked hands-free). tapPending: a short tap that may become a double-tap.
    /// transcribing: transcription mode (double-tap); dictation is off until it stops.
    private enum State { case idle, recording(Date, locked: Bool), tapPending, finishing, transcribing }

    private let socketPath = NSHomeDirectory() + "/Library/Application Support/OpenFlow/asr.sock"
    private lazy var client = ASRClient(socketPath: socketPath)
    private lazy var sidecar = SidecarManager(
        asrDir: Bundle.main.object(forInfoDictionaryKey: "OpenFlowASRDir") as? String ?? "",
        socketPath: socketPath
    )
    private let hotkey = HotkeyMonitor()
    private let audio = AudioCapture()
    private let overlay = OverlayPanel()
    private lazy var transcriber = Transcriber(client: client, socketPath: socketPath, mic: audio)
    private lazy var transcriptPanel = TranscriptPanel(model: transcriber.model)

    private var state = State.idle
    private var lang: String?
    private var session = 0
    /// ASR session of the current dictation; events from older sessions are ignored.
    private var dictationSession = 0
    private var lastTranscribePress: Date?
    /// Keeps the mic open briefly after release: people let go while the last syllable is still trailing.
    private let releaseTail: TimeInterval = 0.3
    private var pendingTail: DispatchWorkItem?
    /// A tap shorter than this is not a dictation; a second press right after it locks hands-free mode.
    private let tapThreshold: TimeInterval = 0.25
    private let doubleTapWindow: TimeInterval = 0.35
    private var pendingTap: DispatchWorkItem?
    private var history: [String] = []
    private var statusText = "ASR: starting…"
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ note: Notification) {
        Settings.registerDefaults()
        setUpMenu()
        setUpClient()
        AudioCapture.requestPermission { ok in if !ok { NSLog("OpenFlow: microphone permission denied") } }
        _ = TextInserter.hasAccessibility(prompt: true)
        startHotkey()

        if !client.connect() { sidecar.start() }
        scheduleReconnect()

        // Scripts and Shortcuts can toggle transcription mode (see README).
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("dev.openflow.toggleTranscription"), object: nil, queue: .main
        ) { [weak self] _ in self?.toggleTranscription() }
    }

    func applicationWillTerminate(_ note: Notification) {
        if case .transcribing = state {
            transcriber.stop()
            transcriber.finish()  // no time to wait for the last finals: save what's there
        }
        audio.shutdown()
        sidecar.stop()
    }

    // MARK: - Hotkey → audio → ASR

    private func startHotkey() {
        hotkey.onPress = { [weak self] in self?.keyPressed() }
        hotkey.onRelease = { [weak self] in self?.keyReleased() }
        hotkey.onChord = { [weak self] in self?.cancelDictation() }
        hotkey.onEscape = { [weak self] in self?.cancelDictation() }
        hotkey.escapeIsActive = { [weak self] in
            switch self?.state {
            case .recording, .tapPending: return true
            default: return false
            }
        }
        if !hotkey.start() {
            CGRequestListenEventAccess()  // Input Monitoring prompt; retry until granted
            setStatus("Grant Accessibility and Input Monitoring to OpenFlow")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.startHotkey() }
        }
    }

    private func keyPressed() {
        switch state {
        case .tapPending:  // double-tap: drop the tap's dictation and start transcription mode
            cancelDictation()
            startTranscription()
        case .transcribing:  // double-tap again to stop
            if let last = lastTranscribePress, Date().timeIntervalSince(last) < doubleTapWindow {
                lastTranscribePress = nil
                stopTranscription()
            } else {
                lastTranscribePress = Date()
            }
        case .recording(_, locked: true):  // press again to finish hands-free mode
            endDictation()
        case .recording:
            break
        case .idle, .finishing:
            beginDictation()
        }
    }

    private func keyReleased() {
        guard case .recording(let started, locked: false) = state else { return }
        guard Date().timeIntervalSince(started) >= tapThreshold else {
            state = .tapPending  // keep recording until we know whether a second press follows
            let work = DispatchWorkItem { [weak self] in
                guard let self, case .tapPending = self.state else { return }
                self.cancelDictation()
            }
            pendingTap = work
            DispatchQueue.main.asyncAfter(deadline: .now() + doubleTapWindow, execute: work)
            return
        }
        endDictation()
    }

    private func beginDictation() {
        guard client.isConnected else {
            setStatus("ASR not ready yet")
            return
        }
        flushTail()
        lang = nil
        session += 1
        dictationSession = client.start(language: Settings.language == "auto" ? "" : Settings.language)
        audio.onAudio = { [client] pcm in client.sendAudio(pcm) }
        audio.onLevel = { [overlay] level in
            DispatchQueue.main.async { overlay.model.level = 0.5 * overlay.model.level + 0.5 * level }  // smooth jitter
        }
        audio.warmSeconds = Settings.keepMicWarm ? 30 : 0
        do {
            try audio.begin(device: AudioDevices.resolve(Settings.microphone))
        } catch {
            NSLog("OpenFlow: audio start failed: %@", error.localizedDescription)
            client.cancel()
            return
        }
        state = .recording(Date(), locked: false)
        overlay.show()
        play("Tink")
    }

    private func endDictation() {
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

    private func startTranscription() {
        guard client.isConnected else {
            setStatus("ASR not ready yet")
            return
        }
        flushTail()
        do {
            try transcriber.start()
        } catch {
            NSLog("OpenFlow: transcription start failed: %@", error.localizedDescription)
            return
        }
        state = .transcribing
        lastTranscribePress = nil
        transcriptPanel.onStop = { [weak self] in self?.stopTranscription() }
        transcriptPanel.show()
        play("Morse")
    }

    private func stopTranscription() {
        guard case .transcribing = state else { return }
        transcriber.stop()
        state = .idle
        play("Pop")
    }

    /// Stops the post-release tail capture and asks the server for the final transcript.
    private func flushTail() {
        guard let tail = pendingTail else { return }
        tail.cancel()
        pendingTail = nil
        audio.finish()
        client.end()
    }

    private func cancelDictation() {
        switch state {
        case .recording, .tapPending: break
        default: return
        }
        pendingTap?.cancel()
        pendingTap = nil
        audio.finish()
        client.cancel()
        state = .idle
        overlay.hide()
    }

    private func setUpClient() {
        client.onEvent = { [weak self] event in
            guard let self else { return }
            if self.transcriber.handleMain(event) { return }
            switch event {
            case .ready:
                self.setStatus("ASR: ready")
            case .partial(let session, let text, let lang):
                guard session == self.dictationSession else { return }
                if case .idle = self.state { return }
                self.overlay.model.update(self.polish(text, lang: lang ?? self.lang))
                if let lang { self.overlay.model.lang = lang; self.lang = lang }
            case .final(let session, let text, let lang):
                guard session == self.dictationSession else { return }
                if case .finishing = self.state {
                    self.state = .idle
                    self.overlay.hide()
                }
                self.deliver(self.polish(text, lang: lang ?? self.lang))
            case .polished:
                break
            case .error(let message):
                NSLog("OpenFlow: ASR error: %@", message)
            case .disconnected:
                self.setStatus("ASR: reconnecting…")
                self.cancelDictation()
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

    private func deliver(_ text: String) {
        guard !text.isEmpty else { return }
        play("Pop")
        history.insert(text, at: 0)
        history = Array(history.prefix(10))
        paste(text)
    }

    private func paste(_ text: String) {
        let needsSpace = Settings.trailingSpace && !(text.last?.isWhitespace ?? true)
        TextInserter.insert(needsSpace ? text + " " : text)
    }

    private func play(_ name: String) {
        guard Settings.sounds, let sound = NSSound(named: NSSound.Name(name))?.copy() as? NSSound else { return }
        sound.volume = 0.25
        sound.play()
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
        menu.delegate = self
        statusItem.menu = menu
    }

    /// Rebuilt on every open so device list, history and checkmarks are current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(NSMenuItem(title: "Hold right ⌥ to dictate · double-tap to transcribe · Esc cancels", action: nil, keyEquivalent: ""))
        menu.items.last?.isEnabled = false
        menu.addItem(.separator())

        if case .transcribing = state {
            menu.addItem(item("Stop Transcription", #selector(toggleTranscription)))
        } else {
            menu.addItem(item("Start Transcription", #selector(toggleTranscription)))
            menu.addItem(item("Hands-Free Dictation", #selector(startHandsFree)))
        }
        menu.addItem(item("Open Transcripts Folder", #selector(openTranscripts)))
        let folder = item("Change Transcripts Folder…", #selector(chooseTranscriptsFolder))
        folder.toolTip = Settings.transcriptsFolder.path
        menu.addItem(folder)
        menu.addItem(.separator())

        let last = item("Paste Last Dictation", #selector(pasteHistory(_:)))
        last.tag = 0
        last.isEnabled = !history.isEmpty
        menu.addItem(last)
        if history.count > 1 {
            let recent = NSMenu()
            for (i, text) in history.enumerated() {
                let flat = text.replacingOccurrences(of: "\n", with: " ⏎ ")
                let entry = item(flat.count > 60 ? String(flat.prefix(60)) + "…" : flat, #selector(pasteHistory(_:)))
                entry.tag = i
                entry.toolTip = text
                recent.addItem(entry)
            }
            menu.addItem(submenu("Recent Dictations", recent))
        }
        menu.addItem(.separator())

        let languages = NSMenu()
        for (code, name) in [("auto", "Detect Automatically"), ("de-DE", "Deutsch"), ("en-US", "English")] {
            let entry = item(name, #selector(chooseLanguage(_:)))
            entry.representedObject = code
            entry.state = Settings.language == code ? .on : .off
            languages.addItem(entry)
        }
        menu.addItem(submenu("Language", languages))

        let mics = NSMenu()
        let auto = AudioDevices.resolve("auto")
        for (code, name) in [("auto", "Automatic (avoid Bluetooth)" + (auto.map { " – \($0.name)" } ?? "")),
                             ("default", "System Default")] {
            let entry = item(name, #selector(chooseMicrophone(_:)))
            entry.representedObject = code
            entry.state = Settings.microphone == code ? .on : .off
            mics.addItem(entry)
        }
        mics.addItem(.separator())
        for device in AudioDevices.inputs() {
            let entry = item(device.name + (device.isBluetooth ? " (Bluetooth)" : ""), #selector(chooseMicrophone(_:)))
            entry.representedObject = device.uid
            entry.state = Settings.microphone == device.uid ? .on : .off
            mics.addItem(entry)
        }
        menu.addItem(submenu("Microphone", mics))

        menu.addItem(toggle("Sounds", Settings.sounds, #selector(toggleSounds)))
        menu.addItem(toggle("Add Space After Text", Settings.trailingSpace, #selector(toggleTrailingSpace)))
        menu.addItem(toggle("Keep Mic Ready for 30 s", Settings.keepMicWarm, #selector(toggleKeepMicWarm)))
        menu.addItem(toggle("Cancel Speaker Echo While Transcribing", Settings.cancelEcho, #selector(toggleCancelEcho)))
        menu.addItem(toggle("Launch at Login", SMAppService.mainApp.status == .enabled, #selector(toggleLogin)))
        menu.addItem(.separator())
        menu.addItem(item("Restart ASR", #selector(restartASR)))
        menu.addItem(item("Open ASR Log", #selector(openLog)))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit OpenFlow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        return i
    }

    private func toggle(_ title: String, _ on: Bool, _ action: Selector) -> NSMenuItem {
        let i = item(title, action)
        i.state = on ? .on : .off
        return i
    }

    private func submenu(_ title: String, _ sub: NSMenu) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.submenu = sub
        return i
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
        statusText = s
        statusItem.button?.appearsDisabled = !client.isConnected
    }

    @objc private func pasteHistory(_ sender: NSMenuItem) {
        guard history.indices.contains(sender.tag) else { return }
        let text = history[sender.tag]
        // let the menu close so focus is back in the target field
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.paste(text) }
    }

    @objc private func toggleTranscription() {
        if case .transcribing = state {
            stopTranscription()
        } else if case .idle = state {
            startTranscription()
        }
    }

    /// Dictation without holding the key; a single press of right ⌥ finishes it.
    @objc private func startHandsFree() {
        guard case .idle = state else { return }
        beginDictation()
        guard case .recording = state else { return }
        state = .recording(Date(), locked: true)
        overlay.model.locked = true
    }

    @objc private func openTranscripts() {
        try? FileManager.default.createDirectory(at: Settings.transcriptsFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Settings.transcriptsFolder)
    }

    @objc private func chooseTranscriptsFolder() {
        let panel = NSOpenPanel()
        panel.title = "Transcripts Folder"
        panel.message = "New transcripts are saved here as Markdown."
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = Settings.transcriptsFolder
        NSApp.activate()  // a menu bar app's panel would otherwise open behind other windows
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Settings.transcriptsFolder = url
    }

    @objc private func chooseLanguage(_ sender: NSMenuItem) {
        Settings.language = sender.representedObject as? String ?? "auto"
    }

    @objc private func chooseMicrophone(_ sender: NSMenuItem) {
        Settings.microphone = sender.representedObject as? String ?? "auto"
        audio.shutdown()  // reopen on the new device next time
    }

    @objc private func toggleSounds() { Settings.sounds.toggle() }
    @objc private func toggleTrailingSpace() { Settings.trailingSpace.toggle() }

    @objc private func toggleCancelEcho() { Settings.cancelEcho.toggle() }

    @objc private func toggleKeepMicWarm() {
        Settings.keepMicWarm.toggle()
        if !Settings.keepMicWarm, case .idle = state { audio.shutdown() }
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
    }
}

if CommandLine.arguments.contains("--mictest") {
    runMicTest()
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--echotest"), i + 1 < CommandLine.arguments.count {
    runEchoTest(clip: CommandLine.arguments[i + 1])
    exit(0)
}

if CommandLine.arguments.contains("--systemaudiotest") {
    runSystemAudioTest()
    exit(0)
}

let app = NSApplication.shared
if CommandLine.arguments.contains("--demo") {
    runOverlayDemo()
} else if CommandLine.arguments.contains("--transcript-demo") {
    runTranscriptDemo()
} else {
    let delegate = AppDelegate()
    app.delegate = delegate
}
app.setActivationPolicy(.accessory)
app.run()
