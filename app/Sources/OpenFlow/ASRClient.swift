import Foundation

/// Talks to the Python sidecar over its Unix socket (framing documented in asr/server.py).
final class ASRClient {
    /// `session` numbers the start() calls on this connection from 1, matching the server's count.
    enum Event {
        case ready
        case partial(session: Int, text: String, lang: String?)
        case final(session: Int, text: String, lang: String?)
        case polished(id: Int, text: String)
        case error(String)
        case disconnected
    }

    let socketPath: String
    /// Server-side model set; a second concurrent audio stream needs its own (see asr/server.py).
    let decoderSet: Int
    var onEvent: (Event) -> Void = { _ in }
    private(set) var isConnected = false

    private var fd: Int32 = -1
    private let writeQueue = DispatchQueue(label: "openflow.asr.write")
    private let counter = NSLock()
    private var sessions = 0

    init(socketPath: String, decoderSet: Int = 0) {
        self.socketPath = socketPath
        self.decoderSet = decoderSet
    }

    func connect() -> Bool {
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return false }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let bytes = Array(socketPath.utf8.prefix(maxLen - 1))
            raw.copyBytes(from: bytes + [0])
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard ok == 0 else { close(s); return false }
        var noSigPipe: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        fd = s
        isConnected = true
        counter.lock()
        sessions = 0
        counter.unlock()
        if decoderSet != 0 { send("C", Data(String(decoderSet).utf8)) }
        Thread { [weak self] in self?.readLoop(s) }.start()
        return true
    }

    /// Ends the connection; the read loop reports `.disconnected`.
    func disconnect() {
        let s = fd
        guard s >= 0 else { return }
        writeQueue.async { shutdown(s, SHUT_RDWR) }  // after frames already queued
    }

    /// Starts a session and returns its number. Safe to call from the audio thread.
    @discardableResult
    func start(language: String = "") -> Int {
        counter.lock()
        sessions += 1
        let id = sessions
        counter.unlock()
        send("S", Data(language.utf8))
        return id
    }

    func sendAudio(_ pcm: Data) { send("A", pcm) }
    func end() { send("E") }
    func cancel() { send("X") }

    /// Asks the server's local LLM to clean up a transcript segment; answers with `.polished(id:)`.
    /// Empty text only loads the model.
    func polish(id: Int, text: String) {
        guard let payload = try? JSONSerialization.data(withJSONObject: ["id": id, "text": text]) else { return }
        send("P", payload)
    }

    private func send(_ kind: Character, _ payload: Data = Data()) {
        let s = fd
        guard s >= 0 else { return }
        var frame = Data([kind.asciiValue!])
        var len = UInt32(payload.count).bigEndian
        frame.append(Data(bytes: &len, count: 4))
        frame.append(payload)
        writeQueue.async {
            frame.withUnsafeBytes { raw in
                var off = 0
                while off < raw.count {
                    let n = write(s, raw.baseAddress! + off, raw.count - off)
                    if n <= 0 { return }
                    off += n
                }
            }
        }
    }

    private func readLoop(_ s: Int32) {
        var pending = Data()
        var buf = [UInt8](repeating: 0, count: 16_384)
        while true {
            let n = read(s, &buf, buf.count)
            if n <= 0 { break }
            pending.append(buf, count: n)
            while let nl = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<nl]
                pending.removeSubrange(pending.startIndex...nl)
                if let event = Self.parse(Data(line)) {
                    DispatchQueue.main.async { self.onEvent(event) }
                }
            }
        }
        close(s)
        DispatchQueue.main.async {
            if self.fd == s { self.fd = -1 }
            self.isConnected = false
            self.onEvent(.disconnected)
        }
    }

    private static func parse(_ line: Data) -> Event? {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = obj["type"] as? String else { return nil }
        let text = obj["text"] as? String ?? ""
        let lang = obj["lang"] as? String
        let session = obj["session"] as? Int ?? 0
        switch type {
        case "ready": return .ready
        case "partial": return .partial(session: session, text: text, lang: lang)
        case "final": return .final(session: session, text: text, lang: lang)
        case "polished": return .polished(id: obj["id"] as? Int ?? -1, text: text)
        case "error": return .error(obj["message"] as? String ?? "unknown")
        default: return nil
        }
    }
}
