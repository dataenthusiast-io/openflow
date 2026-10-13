import AppKit

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
