import Foundation

/// Appends timestamped lines to ~/Library/Logs/OpenFlow.log (and the unified log).
enum Log {
    static let path = NSHomeDirectory() + "/Library/Logs/OpenFlow.log"
    private static let queue = DispatchQueue(label: "openflow.log")
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func write(_ message: String) {
        NSLog("OpenFlow: %@", message)
        let line = "\(stamp.string(from: Date())) \(message)\n"
        queue.async {
            if let h = FileHandle(forWritingAtPath: path) {
                h.seekToEndOfFile()
                h.write(Data(line.utf8))
                try? h.close()
            } else {
                FileManager.default.createFile(atPath: path, contents: Data(line.utf8))
            }
        }
    }
}
