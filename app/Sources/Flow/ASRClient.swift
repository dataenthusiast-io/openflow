import Foundation

/// Talks to the Python sidecar over its Unix socket (framing documented in asr/server.py).
final class ASRClient {
    enum Event {
        case ready
        case partial(String, String?)
        case final(String, String?)
        case error(String)
        case disconnected
    }

    let socketPath: String
    var onEvent: (Event) -> Void = { _ in }
    private(set) var isConnected = false

    private var fd: Int32 = -1
    private let writeQueue = DispatchQueue(label: "flow.asr.write")

    init(socketPath: String) { self.socketPath = socketPath }

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
        Thread { [weak self] in self?.readLoop(s) }.start()
        return true
    }

    func start(language: String = "") { send("S", Data(language.utf8)) }
    func sendAudio(_ pcm: Data) { send("A", pcm) }
    func end() { send("E") }
    func cancel() { send("X") }

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
        switch type {
        case "ready": return .ready
        case "partial": return .partial(text, lang)
        case "final": return .final(text, lang)
        case "error": return .error(obj["message"] as? String ?? "unknown")
        default: return nil
        }
    }
}
