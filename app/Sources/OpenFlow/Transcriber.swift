import AppKit
import SwiftUI

/// Transcription mode: transcribes the mic ("You") and everything the Mac plays ("Them") into the
/// side panel and a Markdown file. Each stream is cut into short ASR sessions at pauses. A segment
/// shows the live decoder's text first, then the final decoder's, then the local LLM's cleanup.
enum Speaker: String {
    case you = "You", them = "Them"
}

struct TranscriptSegment: Identifiable, Equatable {
    enum Stage { case live, final, polished }
    let id: Int
    let speaker: Speaker
    let start: Date
    var text: String
    var stage: Stage
    /// The recognizer's text before polish; echo detection compares against both.
    var heard = ""
}

final class TranscriptModel: ObservableObject {
    @Published var segments: [TranscriptSegment] = []
    @Published var started = Date()
    @Published var ended: Date?
    @Published var finishing = false
    @Published var level: Float = 0
    /// System audio level: stays flat while nothing plays, or while macOS withholds the permission.
    @Published var themLevel: Float = 0
    @Published var notice: String?
    @Published var fileURL: URL?
    /// The mic runs through macOS echo cancellation (speakers, not headphones).
    @Published var cancellingEcho = false

    struct Block: Identifiable {
        let id: Int
        let speaker: Speaker
        let start: Date
        var segments: [TranscriptSegment]
    }

    /// Consecutive segments of one speaker form a block; a long monologue gets a new one every 2 minutes.
    func blocks(includeLive: Bool) -> [Block] {
        var out: [Block] = []
        for s in segments.sorted(by: { $0.start < $1.start }) where !s.text.isEmpty && (includeLive || s.stage != .live) {
            if let last = out.last, last.speaker == s.speaker, s.start.timeIntervalSince(last.start) < 120 {
                out[out.count - 1].segments.append(s)
            } else {
                out.append(Block(id: s.id, speaker: s.speaker, start: s.start, segments: [s]))
            }
        }
        return out
    }

    func reset() {
        segments = []
        started = Date()
        ended = nil
        finishing = false
        level = 0
        themLevel = 0
        notice = nil
        fileURL = nil
    }
}

/// Cuts a continuous stream into ASR sessions at pauses: sessions stay short (the server keeps a
/// session's audio in memory) and every finished segment can be polished right away.
/// Runs on the audio thread.
private struct Segmenter {
    private var samples = 0
    private var silent = 0
    private var heard = false
    private var floor: Float = 0.01
    private static let rate = 16_000

    static func rms(_ pcm: Data) -> Float {
        pcm.withUnsafeBytes { raw in
            let s = raw.bindMemory(to: Int16.self)
            var sum: Float = 0
            for v in s { let f = Float(v) / 32768; sum += f * f }
            return sqrt(sum / Float(max(1, s.count)))
        }
    }

    /// Feeds one chunk; true when the session should end after it.
    mutating func feed(_ pcm: Data) -> Bool {
        let rms = Self.rms(pcm), n = pcm.count / 2
        // Noise floor: follows quiet stretches down at once, creeps up slowly during speech.
        floor = rms < floor ? rms : floor + (rms - floor) * 0.005
        let speech = rms > max(0.006, floor * 3)
        samples += n
        silent = speech ? 0 : silent + n
        heard = heard || speech
        let seconds = Double(samples) / Double(Self.rate), pause = Double(silent) / Double(Self.rate)
        // Pauses only end a segment that has speech in it; silence just keeps streaming.
        let cut = heard && ((seconds >= 2 && pause >= 0.7) || (seconds >= 20 && pause >= 0.3))
        guard cut || seconds >= 40 else { return false }
        samples = 0
        silent = 0
        heard = false
        return true
    }
}

/// One audio source and its ASR connection.
private final class Stream {
    let speaker: Speaker
    let client: ASRClient
    var segmenter = Segmenter()        // audio thread
    var segments: [Int: Int] = [:]     // ASR session -> segment id (main thread)

    init(speaker: Speaker, client: ASRClient) {
        self.speaker = speaker
        self.client = client
    }
}

final class Transcriber {
    let model = TranscriptModel()
    private(set) var isActive = false
    /// Called once everything is final and saved after stop().
    var onFinished: () -> Void = {}

    private let mic: AudioCapture
    private let system = SystemAudioCapture()
    private let you: Stream
    private let them: Stream
    private var nextID = 1
    private var polishing: Set<Int> = []
    private var finishTimeout: DispatchWorkItem?

    init(client: ASRClient, socketPath: String, mic: AudioCapture) {
        self.mic = mic
        you = Stream(speaker: .you, client: client)
        them = Stream(speaker: .them, client: ASRClient(socketPath: socketPath, decoderSet: 1))
        them.client.onEvent = { [weak self] event in self?.handle(event, from: self?.them) }
    }

    func start() throws {
        guard !isActive else { return }
        model.reset()
        nextID = 1
        polishing = []
        you.segments = [:]
        them.segments = [:]
        you.client.polish(id: 0, text: "")  // load the LLM while the first segment is spoken

        mic.warmSeconds = 0
        mic.onLevel = { [model] level in
            DispatchQueue.main.async { model.level = 0.5 * model.level + 0.5 * level }
        }
        model.cancellingEcho = Settings.cancelEcho && AudioDevices.outputIsSpeakers()
        try mic.begin(device: AudioDevices.resolve(Settings.microphone), cancelEcho: model.cancellingEcho)
        isActive = true
        begin(you)
        mic.onAudio = { [weak self, you] pcm in self?.feed(you, pcm) }

        if them.client.isConnected || them.client.connect() {
            do {
                begin(them)
                system.onAudio = { [weak self, them, model] pcm in
                    let level = Segmenter.rms(pcm)
                    DispatchQueue.main.async { model.themLevel = 0.5 * model.themLevel + 0.5 * level }
                    self?.feed(them, pcm)
                }
                try system.start()
            } catch {
                NSLog("OpenFlow: system audio failed: %@", error.localizedDescription)
                model.notice = "System audio unavailable, only your mic is transcribed."
                them.client.cancel()
                them.client.disconnect()
            }
        } else {
            model.notice = "System audio unavailable, only your mic is transcribed."
        }
        save()
    }

    /// Stops capturing; the panel shows "Finishing…" until the last finals and polishes are in.
    func stop() {
        guard isActive else { return }
        isActive = false
        mic.onAudio = { _ in }
        mic.onLevel = { _ in }
        mic.finish()
        system.onAudio = { _ in }
        system.stop()
        you.client.end()
        if them.client.isConnected { them.client.end() }
        model.finishing = true
        model.level = 0
        model.themLevel = 0
        let timeout = DispatchWorkItem { [weak self] in self?.finish() }
        finishTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
        finishIfDone()
    }

    /// Main-connection events: true if they belonged to transcription.
    func handleMain(_ event: ASRClient.Event) -> Bool {
        switch event {
        case .partial(let session, _, _), .final(let session, _, _):
            guard you.segments[session] != nil else { return false }
            handle(event, from: you)
            return true
        case .polished:  // only transcription asks for polish
            handle(event, from: you)
            return true
        case .disconnected:
            if isActive || model.finishing {
                model.notice = "Speech recognition restarted; the transcript so far is saved."
                stop()
                finish()
            }
            return false
        default:
            return false
        }
    }

    // MARK: - Audio thread

    private func feed(_ stream: Stream, _ pcm: Data) {
        stream.client.sendAudio(pcm)
        guard stream.segmenter.feed(pcm) else { return }
        stream.client.end()
        begin(stream)
    }

    /// Starts an ASR session for the next segment. Called on the audio thread at cuts.
    private func begin(_ stream: Stream) {
        let session = stream.client.start(language: Settings.language == "auto" ? "" : Settings.language)
        let start = Date()
        DispatchQueue.main.async { [self] in
            let id = nextID
            nextID += 1
            stream.segments[session] = id
            model.segments.append(TranscriptSegment(id: id, speaker: stream.speaker, start: start, text: "", stage: .live))
        }
    }

    // MARK: - Main thread

    private func handle(_ event: ASRClient.Event, from stream: Stream?) {
        guard let stream else { return }
        switch event {
        case .partial(let session, let text, let lang):
            guard let id = stream.segments[session] else { return }
            let clean = withoutEcho(FillerFilter.clean(text, lang: lang), segment: id)
            update(id) { if $0.stage == .live { $0.text = clean } }
        case .final(let session, let text, let lang):
            guard let id = stream.segments[session] else { return }
            stream.segments[session] = nil
            let heard = FillerFilter.clean(text, lang: lang)
            let clean = withoutEcho(heard, segment: id)
            if clean.isEmpty {
                model.segments.removeAll { $0.id == id }
            } else {
                update(id) { $0.text = clean; $0.heard = heard; $0.stage = .final }
                polishing.insert(id)
                you.client.polish(id: id, text: clean)
            }
            if stream === them { removeEchoes() }  // "You" may have finished first
            save()
            finishIfDone()
        case .polished(let id, let text):
            guard id != 0 else { return }
            polishing.remove(id)
            if !text.isEmpty { update(id) { $0.text = text; $0.stage = .polished } }
            removeEchoes()
            save()
            finishIfDone()
        case .disconnected where stream === them:
            if isActive {
                system.stop()
                model.notice = "System audio stopped."
            }
        default:
            break
        }
    }

    // MARK: - Echo removal

    /// Without headphones the mic also hears the speakers, so what "Them" said shows up again under
    /// "You", often mixed with your own words when you talk over someone. See `stripEcho`.
    private func withoutEcho(_ text: String, segment id: Int) -> String {
        guard let seg = model.segments.first(where: { $0.id == id }), seg.speaker == .you else { return text }
        let theirs = model.segments
            .filter { $0.speaker == .them && abs($0.start.timeIntervalSince(seg.start)) < 20 }
            .flatMap { [$0.text, $0.heard] }
        return Self.stripEcho(text, theirs: theirs)
    }

    /// Cuts runs of 3+ words that also occur in `theirs` (bridging one misheard word), plus 2-word
    /// pieces of `theirs` touching such a run or the text's ends. What's left is yours; a single
    /// leftover word between echoes is usually a recognition error and goes too.
    static func stripEcho(_ text: String, theirs: [String]) -> String {
        var tri = Set<String>(), bi = Set<String>()
        for t in theirs {
            let w = words(t)
            for i in w.indices.dropLast(1) { bi.insert(w[i] + " " + w[i + 1]) }
            for i in w.indices.dropLast(2) { tri.insert(w[i..<i + 3].joined(separator: " ")) }
        }
        let tokens = text.split(separator: " ").map(String.init)
        let norm = tokens.map { words($0).joined() }
        let n = tokens.count
        guard !tri.isEmpty, n >= 3 else { return text }
        var echo = [Bool](repeating: false, count: n)
        for i in 0...(n - 3) where tri.contains(norm[i..<i + 3].joined(separator: " ")) {
            echo[i] = true; echo[i + 1] = true; echo[i + 2] = true
        }
        guard echo.contains(true) else { return text }
        for i in 1..<(n - 1) where !echo[i] && echo[i - 1] && echo[i + 1] { echo[i] = true }
        for i in 0..<(n - 1) where !echo[i] && !echo[i + 1] && bi.contains(norm[i] + " " + norm[i + 1]) {
            let touches = i == 0 || i + 1 == n - 1 || echo[i - 1] || (i + 2 < n && echo[i + 2])
            if touches { echo[i] = true; echo[i + 1] = true }
        }
        var kept: [String] = [], run: [String] = []
        for i in 0..<n {
            if !echo[i] { run.append(tokens[i]) }
            if echo[i] || i == n - 1 {
                if run.count >= 2 { kept += run }
                run = []
            }
        }
        var out = kept.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " ,;"))
        if let first = out.first, first.isLowercase { out = first.uppercased() + out.dropFirst() }
        return out
    }

    static func echoSelfTest() -> Bool {
        let them = ["Hey, can you review the pull request before launch? I think the streaming latency looks really good now."]
        let cases: [(String, String)] = [
            ("Hey can you review the pull request before launch", ""),
            ("Hey can you review the pull request yes I'll do it before launch", "Yes I'll do it"),
            ("Hey can you review the full request before launch", ""),  // one misheard word inside
            ("Sure, I'll review it after lunch.", "Sure, I'll review it after lunch."),
            ("I think the streaming latency looks really good now, but the build is slow", "But the build is slow"),
            ("Ja genau, das machen wir so.", "Ja genau, das machen wir so."),
        ]
        var ok = true
        for (input, want) in cases {
            let got = stripEcho(input, theirs: them)
            print(got == want ? "PASS" : "FAIL", " echo: \(input)  ->  \(got)")
            ok = ok && got == want
        }
        return ok
    }

    /// Re-checks finished "You" segments once more "Them" text is in.
    private func removeEchoes() {
        for seg in model.segments where seg.speaker == .you && seg.stage != .live {
            let kept = withoutEcho(seg.text, segment: seg.id)
            if kept != seg.text { update(seg.id) { $0.text = kept } }
        }
        withAnimation(.smooth(duration: 0.35)) {
            model.segments.removeAll { $0.speaker == .you && $0.stage != .live && $0.text.isEmpty }
        }
    }

    static func words(_ s: String) -> [String] {
        s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private func update(_ id: Int, _ change: (inout TranscriptSegment) -> Void) {
        guard let i = model.segments.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(.smooth(duration: 0.35)) { change(&model.segments[i]) }
    }

    private func finishIfDone() {
        guard model.finishing, you.segments.isEmpty, them.segments.isEmpty, polishing.isEmpty else { return }
        finish()
    }

    /// Final state: unfinished segments keep their best text; the file is written one last time.
    func finish() {
        guard model.finishing else { return }
        finishTimeout?.cancel()
        finishTimeout = nil
        model.segments.removeAll { $0.text.isEmpty }
        for i in model.segments.indices where model.segments[i].stage == .live { model.segments[i].stage = .final }
        you.segments = [:]
        them.segments = [:]
        polishing = []
        model.finishing = false
        model.ended = Date()
        save()
        them.client.disconnect()
        onFinished()
    }

    private func save() {
        do {
            model.fileURL = try TranscriptStore.save(model)
        } catch {
            NSLog("OpenFlow: saving transcript failed: %@", error.localizedDescription)
            model.notice = "Couldn't save the transcript: \(error.localizedDescription)"
        }
    }
}

/// Markdown files in `Settings.transcriptsFolder`, rewritten atomically after every finished
/// segment: a crash loses at most the segment being spoken. A transcript stays in the folder it
/// started in, even if the setting changes meanwhile.
enum TranscriptStore {
    static func save(_ model: TranscriptModel) throws -> URL {
        let url = model.fileURL ?? Settings.transcriptsFolder
            .appendingPathComponent(format(model.started, "yyyy-MM-dd HH-mm") + ".md")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try markdown(model).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func markdown(_ model: TranscriptModel) -> String {
        let end = model.ended.map { "–" + format($0, "HH:mm") } ?? " (recording)"
        var out = "# Transcript · \(format(model.started, "d MMM yyyy, HH:mm"))\(end)\n"
        for block in model.blocks(includeLive: false) {
            out += "\n**\(block.speaker.rawValue)** · \(format(block.start, "HH:mm"))\n"
            out += block.segments.map(\.text).joined(separator: " ") + "\n"
        }
        return out
    }

    static func format(_ date: Date, _ pattern: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = pattern
        return f.string(from: date)
    }
}
