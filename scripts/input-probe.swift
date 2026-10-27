import AppKit

let output = URL(fileURLWithPath: "/tmp/mob-ios-input-probe.json")
var events: [[String: Any]] = []
let hosts = Host.current().addresses + ["localhost"]
final class Probe: NSView {
    override var acceptsFirstResponder: Bool { true }
    func record(_ event: NSEvent, _ kind: String) {
        let p = CGEvent(source: nil)?.location ?? .zero
        let key = kind.hasPrefix("key")
        events.append([
            "kind": kind, "text": key ? event.characters ?? "" : "", "keyCode": key ? event.keyCode : 0,
            "x": p.x, "y": p.y,
            "dx": kind == "scroll" ? event.scrollingDeltaX : 0,
            "dy": kind == "scroll" ? event.scrollingDeltaY : 0,
            "flags": event.modifierFlags.rawValue
        ])
        save()
        needsDisplay = true
    }
    override func mouseDown(with e: NSEvent) { record(e, "down") }
    override func mouseUp(with e: NSEvent) { record(e, "up") }
    override func rightMouseDown(with e: NSEvent) { record(e, "rightDown") }
    override func rightMouseUp(with e: NSEvent) { record(e, "rightUp") }
    override func mouseDragged(with e: NSEvent) { record(e, "drag") }
    override func keyDown(with e: NSEvent) {
        if e.keyCode == 53 { NSApp.terminate(nil) } else { record(e, "keyDown") }
    }
    override func keyUp(with e: NSEvent) { record(e, "keyUp") }
    override func flagsChanged(with e: NSEvent) { record(e, "flags") }
    override func scrollWheel(with e: NSEvent) { record(e, "scroll") }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed: 0.07, green: 0.15, blue: 0.22, alpha: 1).setFill()
        dirtyRect.fill()
        let text = "MOB iOS · local input test\n\nThis window records harmless test input only. Press Esc to close.\n\nEvents: \(events.count)\n\n" + events.suffix(9).map { "\($0["kind"]!)  \($0["text"]!)  (\($0["x"]!), \($0["y"]!))" }.joined(separator: "\n")
        (text as NSString).draw(in: NSRect(x: 80, y: 150, width: bounds.width - 160, height: bounds.height - 200), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 26, weight: .medium), .foregroundColor: NSColor.white])
    }
}
func save() {
    let screen = NSScreen.main!.frame
    let locked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true
    let obj: [String: Any] = [
        "name": "mob-ios-input-probe", "hosts": hosts, "at": Date().timeIntervalSince1970,
        "ready": !locked && window.isVisible, "width": screen.width, "height": screen.height, "events": events
    ]
    if let data = try? JSONSerialization.data(withJSONObject: obj) { try? data.write(to: output, options: .atomic) }
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
final class ProbeWindow: NSWindow { override var canBecomeKey: Bool { true } }
let window = ProbeWindow(contentRect: NSScreen.main!.frame, styleMask: [.borderless], backing: .buffered, defer: false)
window.title = "Mob iOS input test"
window.level = .floating
let probe = Probe(frame: window.contentLayoutRect)
window.contentView = probe
window.makeKeyAndOrderFront(nil)
window.makeFirstResponder(probe)
app.activate(ignoringOtherApps: true)
save()
let heartbeat = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in save() }
app.run()
