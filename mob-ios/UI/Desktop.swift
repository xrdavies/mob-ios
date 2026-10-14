import SwiftUI
import UIKit

/// Maps a point in the view (screen space, before zoom) to desktop pixels.
func toDesktop(_ p: CGPoint, size: CGSize, fw: Int, fh: Int, scale: CGFloat, offset: CGSize) -> (x: Int, y: Int) {
    let cx = size.width / 2, cy = size.height / 2
    let lx = cx + (p.x - cx - offset.width) / scale
    let ly = cy + (p.y - cy - offset.height) / scale
    let s = min(size.width / CGFloat(fw), size.height / CGFloat(fh))
    let x = Int(((lx - (size.width - CGFloat(fw) * s) / 2) / s).rounded())
    let y = Int(((ly - (size.height - CGFloat(fh) * s) / 2) / s).rounded())
    return (min(max(x, 0), fw - 1), min(max(y, 0), fh - 1))
}

/// Keeps the shared live view open while the calling view is on screen.
private struct RetainDesktop: ViewModifier {
    @Environment(AppState.self) private var app
    func body(content: Content) -> some View {
        content
            .onAppear { app.retainDesktop() }
            .onDisappear { app.releaseDesktop() }
    }
}

/// Thumbnail under the Chat title (hidden by default; toggled from the top bar).
/// Always view-only: tapping it opens the full-screen live view.
struct DesktopThumbnail: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let s = app.vnc.state
        let aspect = s.width > 0 && s.height > 0 ? CGFloat(s.width) / CGFloat(s.height) : 16 / 10
        DesktopCanvas(snapshotWidth: 960)
            .aspectRatio(aspect, contentMode: .fit)
            .frame(maxHeight: 240)
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
            .padding(.horizontal, 12).padding(.vertical, 8)
            .modifier(RetainDesktop())
    }
}

/// Live frames when the VNC session is up, otherwise /screen snapshots every 2 s.
private struct DesktopCanvas: View {
    @Environment(AppState.self) private var app
    let snapshotWidth: Int
    @State private var snapshot: UIImage?
    @State private var snapshotError: String?

    var body: some View {
        let live = app.vnc.state.status == .connected
        ZStack {
            Color.black
            if live, let image = app.vnc.image {
                Image(decorative: image, scale: 1).resizable().interpolation(.medium).aspectRatio(contentMode: .fit)
            } else if let snapshot {
                Image(uiImage: snapshot).resizable().aspectRatio(contentMode: .fit)
            } else {
                Text(placeholder).font(.caption).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center).padding()
            }
        }
        .task(id: live) {
            guard !live else { return }
            while !Task.isCancelled {
                do {
                    snapshot = try await app.apiClient.screen(maxWidth: snapshotWidth)
                    snapshotError = nil
                } catch {
                    if !(error is CancellationError) { snapshotError = readable(error) }
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var placeholder: String {
        let s = app.vnc.state
        if s.status == .connecting { return "Connecting…" }
        let parts = [s.detail.isEmpty ? nil : s.detail, snapshotError.map { "Snapshot: \($0)" }].compactMap { $0 }
        return parts.isEmpty ? "Office desktop is not connected" : parts.joined(separator: "\n")
    }
}

private struct StatusChip: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let s = app.vnc.state
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

/// Full-screen live view with the View / Control switch.
struct LiveView: View {
    @Environment(AppState.self) private var app
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    /// Where the last touch reached the Mac, in desktop pixels.
    @State private var mark: (x: Int, y: Int)?
    @State private var typing = false

    var body: some View {
        let vnc = app.vnc
        let s = vnc.state
        let live = s.status == .connected
        VStack(spacing: 0) {
            HStack {
                Button { app.closeLiveView() } label: { Image(systemName: "xmark").font(.title3) }
                    .accessibilityLabel("Close")
                StatusChip()
                Spacer()
                if live {
                    Picker("Mode", selection: Binding(get: { s.control }, set: { vnc.setControl($0) })) {
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
                    DesktopCanvas(snapshotWidth: 1600)
                        .scaleEffect(scale)
                        .offset(offset)
                    if s.control, let mark { marker(mark, in: geo.size, fw: s.width, fh: s.height) }
                    TouchSurface(control: s.control, handler: handler(size: geo.size, fw: s.width, fh: s.height))
                }
                .clipped()
            }

            if s.control { KeysBar(typing: $typing) }
            Text(footer(s, live: live))
                .font(.caption).foregroundStyle(.white.opacity(0.6))
                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
        }
        .background(Color.black.ignoresSafeArea())
        .background(KeyboardSink(active: $typing && s.control, vnc: vnc))
        .modifier(RetainDesktop())
        .preferredColorScheme(.dark)
    }

    private func footer(_ s: VncState, live: Bool) -> String {
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
        let vnc = app.vnc
        func remote(_ p: CGPoint) -> (x: Int, y: Int) { toDesktop(p, size: size, fw: max(fw, 1), fh: max(fh, 1), scale: scale, offset: offset) }
        return TouchHandler(
            click: { p, right in
                let at = remote(p)
                vnc.click(x: at.x, y: at.y, button: right ? VncSession.buttonRight : VncSession.buttonLeft)
                mark = at
            },
            drag: { p, phase in
                let at = remote(p)
                switch phase {
                case .began:
                    vnc.pointer(x: at.x, y: at.y, buttons: 0)
                    vnc.pointer(x: at.x, y: at.y, buttons: VncSession.buttonLeft)
                case .changed: vnc.pointer(x: at.x, y: at.y, buttons: VncSession.buttonLeft)
                default: vnc.pointer(x: at.x, y: at.y, buttons: 0)
                }
                mark = at
            },
            scroll: { p, dx, dy in
                let at = remote(p)
                vnc.scroll(x: at.x, y: at.y, dx: dx, dy: dy)
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
        let vnc = app.vnc
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                key(typing ? "keyboard.chevron.compact.down" : "keyboard", system: true, on: typing, label: "Keyboard") { typing.toggle() }
                ForEach([("⌘", VncSession.xkMeta), ("⌥", VncSession.xkAlt), ("⌃", VncSession.xkControl), ("⇧", VncSession.xkShift)], id: \.1) { label, sym in
                    key(label, on: vnc.modifiers.contains(sym), label: "Hold \(label) for the next key") { vnc.toggleModifier(sym) }
                }
                key("esc", label: "Escape") { vnc.tapKey(VncSession.xkEscape) }
                key("tab", label: "Tab") { vnc.tapKey(VncSession.xkTab) }
                key("←", label: "Left") { vnc.tapKey(VncSession.xkLeft) }
                key("↑", label: "Up") { vnc.tapKey(VncSession.xkUp) }
                key("↓", label: "Down") { vnc.tapKey(VncSession.xkDown) }
                key("→", label: "Right") { vnc.tapKey(VncSession.xkRight) }
                key("⌫", label: "Delete") { vnc.tapKey(VncSession.xkBackspace) }
                key("⏎", label: "Return") { vnc.tapKey(VncSession.xkReturn) }
                key("Paste", label: "Type the phone's clipboard") { if let s = UIPasteboard.general.string { vnc.typeText(s) } }
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
    let vnc: VncSession

    func makeUIView(context: Context) -> KeyInputView { KeyInputView() }

    func updateUIView(_ view: KeyInputView, context: Context) {
        view.vnc = vnc
        DispatchQueue.main.async {
            if active, !view.isFirstResponder { view.becomeFirstResponder() }
            if !active, view.isFirstResponder { view.resignFirstResponder() }
        }
    }

    final class KeyInputView: UIView, UIKeyInput {
        weak var vnc: VncSession?
        var hasText: Bool { true }
        override var canBecomeFirstResponder: Bool { true }
        var autocorrectionType: UITextAutocorrectionType = .no
        var autocapitalizationType: UITextAutocapitalizationType = .none
        var spellCheckingType: UITextSpellCheckingType = .no
        var smartQuotesType: UITextSmartQuotesType = .no
        var smartDashesType: UITextSmartDashesType = .no
        var keyboardType: UIKeyboardType = .asciiCapable

        func insertText(_ text: String) {
            MainActor.assumeIsolated { text.forEach { vnc?.type($0) } }
        }

        func deleteBackward() {
            MainActor.assumeIsolated { vnc?.tapKey(VncSession.xkBackspace) }
        }
    }
}

private func && (lhs: Binding<Bool>, rhs: Bool) -> Bool { lhs.wrappedValue && rhs }
