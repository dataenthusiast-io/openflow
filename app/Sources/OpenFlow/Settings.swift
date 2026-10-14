import Foundation

/// User preferences, persisted in UserDefaults and edited from the menu bar.
enum Settings {
    private static let d = UserDefaults.standard

    static func registerDefaults() {
        d.register(defaults: [
            "language": "auto",
            "microphone": "auto",
            "sounds": true,
            "trailingSpace": true,
            "keepMicWarm": false,  // the orange mic dot lingering after dictating looks like spying
        ])
    }

    /// "auto" or a locale the model knows, e.g. "de-DE".
    static var language: String {
        get { d.string(forKey: "language") ?? "auto" }
        set { d.set(newValue, forKey: "language") }
    }

    /// "auto" (system default, but never a Bluetooth headset), "default", or a CoreAudio device UID.
    static var microphone: String {
        get { d.string(forKey: "microphone") ?? "auto" }
        set { d.set(newValue, forKey: "microphone") }
    }

    static var sounds: Bool {
        get { d.bool(forKey: "sounds") }
        set { d.set(newValue, forKey: "sounds") }
    }

    /// Append a space after the pasted text so back-to-back dictations don't run together.
    static var trailingSpace: Bool {
        get { d.bool(forKey: "trailingSpace") }
        set { d.set(newValue, forKey: "trailingSpace") }
    }

    /// Keep the mic open for a while after a dictation: no start-up clipping, plus a short pre-roll.
    static var keepMicWarm: Bool {
        get { d.bool(forKey: "keepMicWarm") }
        set { d.set(newValue, forKey: "keepMicWarm") }
    }

    static let defaultTranscriptsFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/OpenFlow/Transcripts", isDirectory: true)

    /// Where transcription mode writes its Markdown files.
    static var transcriptsFolder: URL {
        get { d.string(forKey: "transcriptsFolder").map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultTranscriptsFolder }
        set { d.set(newValue.path, forKey: "transcriptsFolder") }
    }
}
