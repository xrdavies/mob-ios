import AVFoundation
import SwiftUI

/// Full-screen QR scanner for the pairing link; `onCode` returns true to stop (a valid link).
struct QRScannerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let onCode: (String) -> Bool
    @State private var access = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var hint: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                switch access {
                case .authorized:
                    if AVCaptureDevice.default(for: .video) == nil {
                        message("This device has no camera. Paste the link instead.")
                    } else {
                        QRScannerView { code in
                            if onCode(code) { dismiss() } else { hint = "Not a mobd pairing link" }
                        }
                        .ignoresSafeArea()
                        VStack {
                            Spacer()
                            Text(hint ?? "Point the camera at the QR code shown by mobd link")
                                .font(.callout).foregroundStyle(.white).multilineTextAlignment(.center)
                                .padding(12).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
                                .padding(24)
                        }
                    }
                case .notDetermined:
                    ProgressView().tint(.white)
                default:
                    VStack(spacing: 12) {
                        message("mob cannot use the camera. Allow it in Settings, or paste the link instead.")
                        Button("Open Settings") { openURL(URL(string: UIApplication.openSettingsURLString)!) }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .navigationTitle("Scan QR code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task {
                if access == .notDetermined {
                    _ = await AVCaptureDevice.requestAccess(for: .video)
                    access = AVCaptureDevice.authorizationStatus(for: .video)
                }
            }
        }
    }

    private func message(_ text: String) -> some View {
        Text(text).foregroundStyle(.white).multilineTextAlignment(.center).padding(32)
    }
}

/// Camera preview that reports every QR code it reads.
private struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let c = ScannerController()
        c.onCode = onCode
        return c
    }

    func updateUIViewController(_ c: ScannerController, context: Context) { c.onCode = onCode }
}

private final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    private let session = AVCaptureSession()
    private let preview = AVCaptureVideoPreviewLayer()
    private var last: String?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        if output.availableMetadataObjectTypes.contains(.qr) { output.metadataObjectTypes = [.qr] }
        preview.session = session
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // startRunning blocks, so keep it off the main thread.
        DispatchQueue.global(qos: .userInitiated).async { [session] in session.startRunning() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        DispatchQueue.global(qos: .userInitiated).async { [session] in session.stopRunning() }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard let code = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue, code != last else { return }
        // The same code arrives many times a second; report each distinct one once.
        last = code
        onCode?(code)
    }
}
