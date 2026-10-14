import AppKit
import SwiftUI

/// `OpenFlow --demo`: plays a fake dictation through the overlay in a loop (no mic, no ASR).
func runOverlayDemo() {
    let overlay = OverlayPanel()
    let words = ("Hallo Team, ich schicke euch die Präsentation heute Nachmittag. Für morgen haben wir drei Themen, "
        + "erstens das Budget, zweitens die Roadmap und drittens das Hiring. Danke euch!")
        .split(separator: " ").map(String.init)
    retainedDemo = overlay

    func play() {
        overlay.show()
        var text = ""
        for (i, word) in words.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6 + Double(i) * 0.32) {
                text += (text.isEmpty ? "" : " ") + word
                overlay.model.update(TextFormatter.format(text))
                overlay.model.level = Float.random(in: 0.01...0.06)
                if i == 3 { overlay.model.lang = "de-DE" }
            }
        }
        let end = 0.6 + Double(words.count) * 0.32
        DispatchQueue.main.asyncAfter(deadline: .now() + end) { overlay.model.finishing = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + end + 0.6) { overlay.hide() }
        DispatchQueue.main.asyncAfter(deadline: .now() + end + 2) { play() }
    }
    DispatchQueue.main.async { play() }
}

private var retainedDemo: OverlayPanel?

/// `OpenFlow --transcript-demo`: plays a fake meeting through the transcription panel (no mic, no ASR).
/// Each segment streams in dimmed, then turns final, then gets its polished text.
func runTranscriptDemo() {
    let model = TranscriptModel()
    let panel = TranscriptPanel(model: model)
    retainedTranscriptDemo = (model, panel)
    let script: [(Speaker, String, String)] = [
        (.you, "Okay, lass uns kurz den Status zum Release durchgehen.", "Okay, lass uns kurz den Status zum Release durchgehen."),
        (.them, "Yes so the the pool request is merged and QA starts tomorrow at nine", "Yes, so the pull request is merged and QA starts tomorrow at 9."),
        (.them, "we still need sign off from security though", "We still need sign-off from security, though."),
        (.you, "Gut, dann schieben wir das Deployment auf Donnerstag, ähm, um zehn Uhr", "Gut, dann schieben wir das Deployment auf Donnerstag um 10 Uhr."),
        (.them, "Works for me. Can you send the summary to the team after the call?", "Works for me. Can you send the summary to the team after the call?"),
    ]
    panel.onStop = {
        model.finishing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            model.finishing = false
            model.ended = Date()
        }
    }
    func play() {
        model.reset()
        panel.show()
        var t = 0.8
        for (i, (speaker, raw, polished)) in script.enumerated() {
            let words = raw.split(separator: " ").map(String.init)
            let start = t
            DispatchQueue.main.asyncAfter(deadline: .now() + start) {
                model.segments.append(TranscriptSegment(id: i + 1, speaker: speaker, start: Date(), text: "", stage: .live))
            }
            for n in 1...words.count {
                DispatchQueue.main.asyncAfter(deadline: .now() + start + Double(n) * 0.25) {
                    guard let j = model.segments.firstIndex(where: { $0.id == i + 1 }) else { return }
                    model.segments[j].text = words.prefix(n).joined(separator: " ")
                    model.level = speaker == .you ? Float.random(in: 0.01...0.06) : 0.002
                    model.themLevel = speaker == .them ? Float.random(in: 0.01...0.06) : 0
                }
            }
            t += Double(words.count) * 0.25
            DispatchQueue.main.asyncAfter(deadline: .now() + t + 0.4) {
                guard let j = model.segments.firstIndex(where: { $0.id == i + 1 }) else { return }
                withAnimation(.smooth(duration: 0.35)) { model.segments[j].stage = .final }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + t + 0.9) {
                guard let j = model.segments.firstIndex(where: { $0.id == i + 1 }) else { return }
                withAnimation(.smooth(duration: 0.35)) { model.segments[j].text = polished; model.segments[j].stage = .polished }
            }
            t += 0.6
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + t + 1.5) { panel.onStop() }
        DispatchQueue.main.asyncAfter(deadline: .now() + t + 8) { play() }
    }
    DispatchQueue.main.async { play() }
}

private var retainedTranscriptDemo: (TranscriptModel, TranscriptPanel)?
