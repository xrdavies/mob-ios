import SwiftUI
import UIKit

/// Keeps the shared live view open while the calling view is on screen.
private struct RetainDesktop: ViewModifier {
    @Environment(AppState.self) private var app
    @Environment(\.displayScale) private var displayScale
    @State private var id = UUID()
    @State private var pixels: CGSize = .zero
    var fullScreen = false

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGSize.self) { geo in
                guard geo.size.width > 0, geo.size.height > 0 else { return .zero }
                return CGSize(width: devicePixels(geo.size.width, scale: displayScale),
                              height: devicePixels(geo.size.height, scale: displayScale))
            } action: {
                pixels = $0
                app.updateDesktopSize(id, size: $0, fullScreen: fullScreen)
            }
            .onAppear { app.updateDesktopSize(id, size: pixels, fullScreen: fullScreen) }
            .onDisappear { app.releaseDesktop(id) }
    }
}

/// Thumbnail under the Chat title (hidden by default; toggled from the top bar).
/// Always view-only: tapping it opens the full-screen live view.
struct DesktopThumbnail: View {
    @Environment(AppState.self) private var app
    let width: CGFloat

    var body: some View {
        let s = app.liveState
        let aspect = s.width > 0 && s.height > 0 ? CGFloat(s.width) / CGFloat(s.height) : 16 / 10
        DesktopCanvas()
            .frame(width: max(width - 24, 1), height: max(width - 24, 1) / aspect)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(alignment: .topLeading) { StatusChip().padding(8) }
            .overlay(alignment: .topTrailing) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.caption).foregroundStyle(.white).padding(7)
                    .background(.black.opacity(0.45), in: Circle()).padding(8)
            }
            .contentShape(Rectangle())
            .onTapGesture { app.showLiveView = true }
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Office desktop. Opens full screen.")
            .modifier(RetainDesktop())
            .padding(.horizontal, 12).padding(.vertical, 8)
            .id(ObjectIdentifier(app.apiClient))
    }
}

/// Live frames while the live view is up, otherwise /screen snapshots every 2 s.
private struct DesktopCanvas: View {
    @Environment(AppState.self) private var app
    @Environment(\.displayScale) private var displayScale
    /// The view's width in points; snapshots are fetched at that width in pixels.
    @State private var width: CGFloat = 0
    @State private var snapshot: UIImage?
    @State private var snapshotTag: String?
    @State private var snapshotError: String?
    @State private var snapshotAt: Date?
    /// The last frame is from a sleeping desktop; it is not woken.
    @State private var asleep = false
    /// The conversation has no desktop yet (409 no_desktop).
    @State private var noDesktop = false
    /// Which conversation the snapshot belongs to; cleared when it changes.
    @State private var snapshotFor: String?

    var body: some View {
        let live = app.stream.state.status == .connected
        let activities = app.chat.detail?.activities ?? []
        ZStack {
            Color.black
            if live {
                // Fills the canvas; the Metal view letterboxes the video itself (scaleAspectFit), the
                // same fit the touch mapping assumes. Without a ratio, .aspectRatio would size it from
                // the view's own small ideal size.
                Group {
                    if app.stream.transport == .webSocket { WsVideoView(session: app.stream) }
                    else { StreamVideoView(track: app.stream.track) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let snapshot {
                Image(uiImage: snapshot).resizable().aspectRatio(contentMode: .fit)
                    .overlay { ClickPing(click: latestClick(activities), geometry: screenGeometry(activities)) }
            } else if asleep, let snapshot {
                Image(uiImage: snapshot).resizable().aspectRatio(contentMode: .fit)
            } else {
                Text(placeholder).font(.caption).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center).padding()
            }
        }
        .overlay(alignment: .bottomLeading) { if !live { snapshotLabel } }
        .overlay(alignment: .bottomLeading) { if asleep { asleepBadge } }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .task(id: taskId) {
            let pixels = devicePixels(width, scale: displayScale)
            let sessionId = app.health?.sessionDesktops == true ? app.chat.currentId : nil
            guard !live, width > 0, app.activeMachine?.needsPairing != true else { return }
            let client = app.apiClient
            // Another conversation: clear its snapshot.
            if sessionId != snapshotFor { snapshot = nil; snapshotTag = nil; asleep = false; noDesktop = false; snapshotFor = sessionId }
            while !Task.isCancelled {
                do {
                    // A size change starts a new task and a new download; otherwise unchanged costs a 304.
                    let fresh = try await client.screen(maxWidth: pixels, etag: snapshot == nil ? nil : snapshotTag, sessionId: sessionId)
                    guard !Task.isCancelled, client === app.apiClient else { return }
                    if let image = fresh.image { snapshot = image; snapshotTag = fresh.etag }
                    asleep = fresh.asleep
                    noDesktop = false
                    snapshotAt = Date()
                    snapshotError = nil
                } catch {
                    guard !Task.isCancelled, client === app.apiClient else { return }
                    if !(error is CancellationError) {
                        if (error as? APIError)?.code == "no_desktop" { noDesktop = true; snapshotError = nil }
                        else { snapshotError = readable(error) }
                    }
                    if error.isUnauthorized { return app.noteFailure(error, client: client) }
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var taskId: String {
        let live = app.stream.state.status == .connected
        let s = app.health?.sessionDesktops == true ? app.chat.currentId ?? "none" : "shared"
        return "\(ObjectIdentifier(app.apiClient)) \(live) \(app.activeMachine?.needsPairing == true) \(devicePixels(width, scale: displayScale)) \(s)"
    }

    /// "Snapshot · 17:33:05", or mobd's reason snapshots fail (locked, asleep, no Screen Recording).
    @ViewBuilder private var snapshotLabel: some View {
        let time = snapshot == nil ? nil : snapshotAt?.formatted(date: .omitted, time: .standard)
        let text: String? = switch (snapshotError, time) {
        case (.some, .some(let t)): "Snapshot · \(t) · not updating"
        case (.some(let e), nil): "Snapshot unavailable: \(e.replacingOccurrences(of: "screen unavailable: ", with: ""))"
        case (nil, .some(let t)): "Snapshot · \(t)"
        default: nil
        }
        if let text {
            Text(text).font(.caption2).foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
                .padding(8)
        }
    }

    private var placeholder: String {
        let s = app.liveState
        if s.status == .connecting { return "Connecting…" }
        if noDesktop || (app.health?.sessionDesktops == true && app.chat.currentId == nil) { return noDesktopText }
        let parts = [s.detail.isEmpty ? nil : s.detail, snapshotError.map { "Snapshot: \($0)" }].compactMap { $0 }
        return parts.isEmpty ? "Office desktop is not connected" : parts.joined(separator: "\n")
    }

    @ViewBuilder private var asleepBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "moon.fill").font(.caption2)
            Text("Asleep").font(.caption2.weight(.medium))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
        .padding(8)
    }
}

/// The agent's last click pings once on the picture, like the desktop app.
private struct ClickPing: View {
    let click: AgentClick?
    let geometry: ScreenGeometry?
    @State private var progress: CGFloat = 1

    var body: some View {
        GeometryReader { geo in
            if let click, let geometry, progress < 1 {
                let p = CGPoint(x: click.x / geometry.pointWidth * geo.size.width, y: click.y / geometry.pointHeight * geo.size.height)
                ZStack {
                    Circle().stroke(Color.blue.opacity(1 - progress), lineWidth: 2.5).frame(width: 16 + 44 * progress, height: 16 + 44 * progress)
                    Circle().fill(Color.blue.opacity(0.5 * (1 - progress))).frame(width: 12, height: 12)
                }
                .position(p)
            }
        }
        .allowsHitTesting(false)
        .onAppear { ping() }
        .onChange(of: click?.id) { ping() }
    }

    private func ping() {
        guard click != nil else { return }
        progress = 0
        withAnimation(.easeOut(duration: 1.6)) { progress = 1 }
    }
}

private struct StatusChip: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let s = app.liveState
        let (color, label): (Color, String) = switch s.status {
        case .connected: (.green, s.control ? "Controlling" : "Live")
        case .connecting: (.orange, "Connecting")
        default: (.gray, "Snapshot")
        }
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.caption2.weight(.medium)).foregroundStyle(.white)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.black.opacity(0.45), in: Capsule())
    }
}

/// Live view quality for the active machine; picking one reconnects an open view (mobd fixes it per session).
private struct QualityMenu: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let value = LiveQuality(rawValue: app.activeMachine?.liveQuality ?? "") ?? .auto
        Menu {
            Picker("Live view quality", selection: Binding(get: { value }, set: { q in
                if let id = app.activeMachine?.id { app.setLiveQuality(id, q) }
            })) {
                ForEach(LiveQuality.allCases) { q in
                    Button { } label: { Text(q.label); Text(q.hint) }.tag(q)
                }
            }
        } label: {
            Label(value.label, systemImage: "gauge.with.dots.needle.33percent").font(.subheadline)
        }
        .accessibilityLabel("Live view quality: \(value.label)")
    }
}

/// Connection quality as three bars, coloured when it degrades.
private struct SignalBars: View {
    let bars: Int

    var body: some View {
        let on: Color = bars >= 3 ? .green : bars == 2 ? .yellow : .red
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(1...3, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1).fill(i <= bars ? on : .white.opacity(0.2)).frame(width: 3, height: CGFloat(i * 4))
            }
        }
        .accessibilityHidden(true)
    }
}

/// Full-screen live view with the View / Control switch.
struct LiveView: View {
    @Environment(AppState.self) private var app
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    /// Where the last touch reached the Mac, in desktop pixels.
    @State private var mark: (x: Int, y: Int)?
    @State private var typing = false

    var body: some View {
        let stream = app.stream
        let s = stream.state
        let live = s.status == .connected
        VStack(spacing: 0) {
            HStack {
                Button { app.closeLiveView() } label: { Image(systemName: "xmark").font(.title3) }
                    .accessibilityLabel("Close")
                StatusChip()
                Spacer()
                QualityMenu()
                if live {
                    Picker("Mode", selection: Binding(get: { s.control }, set: { stream.setControl($0) })) {
                        Text("View").tag(false)
                        Text("Control").tag(true)
                    }
                    .pickerStyle(.segmented).frame(width: 170)
                } else if s.status != .connecting {
                    Button("Reconnect") { app.connectDesktop() }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .foregroundStyle(.white)

            GeometryReader { geo in
                ZStack {
                    DesktopCanvas()
                        .id(ObjectIdentifier(app.apiClient))
                        .scaleEffect(scale)
                        .offset(offset)
                    if s.control, let mark { marker(mark, in: geo.size, fw: s.width, fh: s.height) }
                    TouchSurface(control: s.control, handler: handler(size: geo.size, fw: s.width, fh: s.height))
                }
                .clipped()
                .modifier(RetainDesktop(fullScreen: true))
            }

            if s.control { KeysBar(typing: $typing) }
            if live {
                // What arrives, once a second: signal bars from mobd's loss and the measured round trip.
                HStack(spacing: 6) {
                    SignalBars(bars: signalBars(loss: stream.loss, rttMs: stream.readout?.rttMs))
                    Text(readoutText(width: s.width, height: s.height, stream.readout)).monospacedDigit()
                }
                .font(.caption).foregroundStyle(.white.opacity(0.7))
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.top, 8)
            }
            Text(footer(s, live: live))
                .font(.caption).foregroundStyle(.white.opacity(0.6))
                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
        }
        .background(Color.black.ignoresSafeArea())
        .background(KeyboardSink(active: $typing && s.control, session: stream))
        .preferredColorScheme(.dark)
    }

    private func footer(_ s: LiveState, live: Bool) -> String {
        if s.control { return "Tap = click · long-press = right-click · drag · two fingers: scroll or pinch to zoom" }
        if live { return "View only · pinch to zoom · switch to Control to use the Mac" }
        if s.status == .connecting { return "View only · connecting the live view…" }
        return "View only snapshot · " + (s.detail.isEmpty ? "live view not connected" : s.detail)
    }

    /// A ring where the last touch reached the Mac (the Mac draws its own pointer).
    private func marker(_ at: (x: Int, y: Int), in size: CGSize, fw: Int, fh: Int) -> some View {
        let s = min(size.width / CGFloat(max(fw, 1)), size.height / CGFloat(max(fh, 1)))
        let lx = (size.width - CGFloat(fw) * s) / 2 + CGFloat(at.x) * s
        let ly = (size.height - CGFloat(fh) * s) / 2 + CGFloat(at.y) * s
        let px = size.width / 2 + (lx - size.width / 2) * scale + offset.width
        let py = size.height / 2 + (ly - size.height / 2) * scale + offset.height
        return Circle().stroke(.white.opacity(0.9), lineWidth: 2).background(Circle().fill(.blue.opacity(0.35)))
            .frame(width: 18, height: 18).position(x: px, y: py).allowsHitTesting(false)
    }

    private func clampOffset(_ o: CGSize, _ size: CGSize) -> CGSize {
        let maxX = (scale - 1) * size.width / 2, maxY = (scale - 1) * size.height / 2
        return CGSize(width: min(max(o.width, -maxX), maxX), height: min(max(o.height, -maxY), maxY))
    }

    private func handler(size: CGSize, fw: Int, fh: Int) -> TouchHandler {
        let stream = app.stream
        func norm(_ p: CGPoint) -> (x: Double, y: Double, inside: Bool)? {
            normalizePoint(p, in: size, video: CGSize(width: fw, height: fh), scale: scale, offset: offset)
        }
        func point(_ n: (x: Double, y: Double, inside: Bool)) -> (x: Int, y: Int) {
            (min(Int((n.x * Double(fw)).rounded()), fw - 1), min(Int((n.y * Double(fh)).rounded()), fh - 1))
        }
        return TouchHandler(
            click: { p, right in
                guard let n = norm(p), n.inside else { return }
                stream.click(n.x, n.y, right: right)
                mark = point(n)
            },
            drag: { p, phase in
                guard let n = norm(p) else { return }
                if phase == .began && !n.inside { return }
                stream.drag(n.x, n.y, phase)
                mark = point(n)
            },
            scroll: { p, dx, dy in
                guard let n = norm(p), n.inside else { return }
                stream.scroll(n.x, n.y, dx: Double(dx), dy: Double(dy))
            },
            zoom: { factor, pan in
                scale = min(max(scale * factor, 1), 6)
                offset = clampOffset(CGSize(width: offset.width + pan.x, height: offset.height + pan.y), size)
            },
            reset: {
                withAnimation(.snappy) {
                    scale = 1
                    offset = .zero
                }
            }
        )
    }
}

/// Keys the phone keyboard lacks: modifiers (latched for the next key), Esc, Tab, arrows, paste.
private struct KeysBar: View {
    @Environment(AppState.self) private var app
    @Binding var typing: Bool

    var body: some View {
        let stream = app.stream
        let mods = stream.modifiers
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                key(typing ? "keyboard.chevron.compact.down" : "keyboard", system: true, on: typing, label: "Keyboard") { typing.toggle() }
                ForEach([("⌘", "MetaLeft"), ("⌥", "AltLeft"), ("⌃", "ControlLeft"), ("⇧", "ShiftLeft")], id: \.1) { label, code in
                    key(label, on: mods.contains(code), label: "Hold \(label) for the next key") { stream.toggleModifier(code) }
                }
                key("esc", label: "Escape") { stream.tapKey("Escape") }
                key("tab", label: "Tab") { stream.tapKey("Tab") }
                key("←", label: "Left") { stream.tapKey("ArrowLeft") }
                key("↑", label: "Up") { stream.tapKey("ArrowUp") }
                key("↓", label: "Down") { stream.tapKey("ArrowDown") }
                key("→", label: "Right") { stream.tapKey("ArrowRight") }
                key("⌫", label: "Delete") { stream.tapKey("Backspace") }
                key("⏎", label: "Return") { stream.tapKey("Enter") }
                key("Paste", label: "Type the phone's clipboard") { if let s = UIPasteboard.general.string { stream.typeText(s) } }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
        }
    }

    private func key(_ text: String, system: Bool = false, on: Bool = false, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group { if system { Image(systemName: text) } else { Text(text) } }
                .font(.callout.weight(.medium))
                .foregroundStyle(on ? .black : .white)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(on ? Color.white : Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
        }
        .accessibilityLabel(label)
    }
}

// MARK: - UIKit bridges

struct TouchHandler {
    var click: (CGPoint, _ right: Bool) -> Void
    var drag: (CGPoint, UIGestureRecognizer.State) -> Void
    var scroll: (CGPoint, _ dx: Int, _ dy: Int) -> Void
    var zoom: (_ factor: CGFloat, _ pan: CGPoint) -> Void
    var reset: () -> Void
}

/// Touches over the desktop. View mode: pinch and pan zoom the picture, double-tap resets.
/// Control mode: tap = click, long-press = right-click, one-finger drag = mouse drag,
/// two fingers = scroll wheel, or zoom when they pinch.
private struct TouchSurface: UIViewRepresentable {
    let control: Bool
    let handler: TouchHandler

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true
        context.coordinator.install(on: view)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.control = control
        context.coordinator.handler = handler
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var control = false
        var handler: TouchHandler?
        private var twoFinger: Mode = .undecided
        private var wheel = CGPoint.zero
        private var lastPan = CGPoint.zero
        private var lastScale: CGFloat = 1
        private enum Mode { case undecided, zoom, scroll }
        private let step: CGFloat = 28

        func install(on view: UIView) {
            let tap = UITapGestureRecognizer(target: self, action: #selector(tap(_:)))
            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTap(_:)))
            doubleTap.numberOfTapsRequired = 2
            let long = UILongPressGestureRecognizer(target: self, action: #selector(longPress(_:)))
            let drag = UIPanGestureRecognizer(target: self, action: #selector(drag(_:)))
            drag.maximumNumberOfTouches = 1
            let two = UIPanGestureRecognizer(target: self, action: #selector(twoFingers(_:)))
            two.minimumNumberOfTouches = 2
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinch(_:)))
            for g in [tap, doubleTap, long, drag, two, pinch] as [UIGestureRecognizer] {
                g.delegate = self
                view.addGestureRecognizer(g)
            }
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            // Two-finger pan and pinch run together; the first clear movement picks scroll or zoom.
            (g is UIPinchGestureRecognizer && other is UIPanGestureRecognizer) || (g is UIPanGestureRecognizer && other is UIPinchGestureRecognizer)
        }

        @objc private func tap(_ g: UITapGestureRecognizer) {
            guard control, g.state == .ended else { return }
            handler?.click(g.location(in: g.view), false)
        }

        @objc private func doubleTap(_ g: UITapGestureRecognizer) {
            // In Control mode two taps already went to the Mac as a double-click.
            if !control, g.state == .ended { handler?.reset() }
        }

        @objc private func longPress(_ g: UILongPressGestureRecognizer) {
            guard control, g.state == .began else { return }
            handler?.click(g.location(in: g.view), true)
        }

        @objc private func drag(_ g: UIPanGestureRecognizer) {
            if control {
                handler?.drag(g.location(in: g.view), g.state)
            } else {
                // View mode: one finger pans the zoomed picture.
                let t = g.translation(in: g.view)
                handler?.zoom(1, t)
                g.setTranslation(.zero, in: g.view)
            }
        }

        @objc private func twoFingers(_ g: UIPanGestureRecognizer) {
            if g.state == .began { lastPan = .zero; wheel = .zero }
            let t = g.translation(in: g.view)
            let delta = CGPoint(x: t.x - lastPan.x, y: t.y - lastPan.y)
            lastPan = t
            if g.state == .ended || g.state == .cancelled { twoFinger = .undecided; return }
            if !control { handler?.zoom(1, delta); return }
            if twoFinger == .undecided, hypot(t.x, t.y) > 12 { twoFinger = .scroll }
            switch twoFinger {
            case .scroll:
                // Natural scrolling: fingers moving up scroll the page down.
                wheel.x -= delta.x
                wheel.y -= delta.y
                let dx = Int(wheel.x / step), dy = Int(wheel.y / step)
                if dx != 0 || dy != 0 {
                    handler?.scroll(g.location(in: g.view), dx, dy)
                    wheel.x -= CGFloat(dx) * step
                    wheel.y -= CGFloat(dy) * step
                }
            case .zoom: handler?.zoom(1, delta)
            case .undecided: break
            }
        }

        @objc private func pinch(_ g: UIPinchGestureRecognizer) {
            if g.state == .began { lastScale = 1 }
            if g.state == .ended || g.state == .cancelled { twoFinger = .undecided; return }
            if control && twoFinger == .undecided && abs(g.scale - 1) > 0.12 { twoFinger = .zoom }
            guard !control || twoFinger == .zoom else { return }
            handler?.zoom(g.scale / lastScale, .zero)
            lastScale = g.scale
        }
    }
}

/// Receives the phone keyboard while active and types it on the Mac.
private struct KeyboardSink: UIViewRepresentable {
    let active: Bool
    let session: StreamSession

    func makeUIView(context: Context) -> KeyInputView { KeyInputView() }

    func updateUIView(_ view: KeyInputView, context: Context) {
        view.session = session
        DispatchQueue.main.async {
            if active, !view.isFirstResponder { view.becomeFirstResponder() }
            if !active, view.isFirstResponder { view.resignFirstResponder() }
        }
    }

    final class KeyInputView: UIView, UIKeyInput {
        weak var session: StreamSession?
        var hasText: Bool { true }
        override var canBecomeFirstResponder: Bool { true }
        var autocorrectionType: UITextAutocorrectionType = .no
        var autocapitalizationType: UITextAutocapitalizationType = .none
        var spellCheckingType: UITextSpellCheckingType = .no
        var smartQuotesType: UITextSmartQuotesType = .no
        var smartDashesType: UITextSmartDashesType = .no
        var keyboardType: UIKeyboardType = .asciiCapable

        func insertText(_ text: String) {
            MainActor.assumeIsolated { text.forEach { session?.type($0) } }
        }

        func deleteBackward() {
            MainActor.assumeIsolated { session?.tapKey("Backspace") }
        }
    }
}

private func && (lhs: Binding<Bool>, rhs: Bool) -> Bool { lhs.wrappedValue && rhs }
