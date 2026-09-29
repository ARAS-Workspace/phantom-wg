import SwiftUI
import AVFoundation

/// Camera sheet for the import flow — scans a QR code carrying a
/// WireGuard `.conf` and hands the decoded string to `onScan`. The
/// capture session stops after the first hit so a lingering camera
/// frame can never double-submit.
///
/// Permission is settled before any camera is built, and the order
/// matters: a denied camera still hands out a device and an input that
/// starts a session, and only the frames never arrive — so asking the
/// device first and the authorization second would show a black
/// rectangle and call it a missing camera. A camera the user turned
/// off and one the device does not have are different sentences, and
/// only the first has a way forward. Whichever ending arrives, the
/// sheet carries its own Cancel: dragging it down used to be the only
/// exit, and on the black screen there was nothing else to read or
/// press.
struct QRScannerView: View {
    let onScan: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(LocalizationManager.self) private var loc
    @State private var access: CameraAccess = .undetermined

    /// What the camera can do for this screen right now.
    enum CameraAccess {
        case undetermined
        case granted
        case denied
        case noDevice
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(loc.t("import_scan_qr"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(loc.t("cancel")) { dismiss() }
                            .accessibilityIdentifier(AXID.QRScanner.cancelButton)
                    }
                }
        }
        .task { await resolveAccess() }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch access {
        case .undetermined:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .granted:
            CameraPreview(onScan: onScan)
                .ignoresSafeArea(edges: .bottom)
        case .denied:
            explanation(loc.t("qr_camera_denied"), offersSettings: true)
        case .noDevice:
            explanation(loc.t("qr_camera_unavailable"), offersSettings: false)
        }
    }

    private func explanation(_ message: String, offersSettings: Bool) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "video.slash")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)

            Text(message)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(AXID.QRScanner.message)

            if offersSettings {
                Button(loc.t("open_settings")) { openSettings() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier(AXID.QRScanner.settingsButton)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Access

    /// Authorization is read before the device is looked for. Denial is
    /// the one state the app can name with certainty — `authorizationStatus`
    /// answers it without touching the camera — so it is settled first,
    /// and a missing device afterwards is a real absence rather than
    /// discovery being withheld.
    private func resolveAccess() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                access = .denied
                return
            }
        case .denied, .restricted:
            access = .denied
            return
        @unknown default:
            // The system's alphabet is open and this one is closed: an
            // unknown state is treated as no access rather than assumed
            // to be permission.
            access = .denied
            return
        }

        access = AVCaptureDevice.default(for: .video) == nil ? .noDevice : .granted
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - Camera

/// The live camera, shown only once authorization is in hand.
private struct CameraPreview: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerViewController {
        let vc = ScannerViewController()
        vc.onScan = onScan
        return vc
    }

    func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) {}
}

class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScan: ((String) -> Void)?
    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?

    override func viewDidLoad() {
        super.viewDidLoad()
        setupCamera()
    }

    /// The layer is sized here rather than once at load: a sheet's
    /// bounds are not final when `viewDidLoad` runs, so a frame taken
    /// there draws the preview at the wrong size for the rest of the
    /// session.
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    private func setupCamera() {
        let session = AVCaptureSession()

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else {
            return
        }

        if session.canAddInput(input) {
            session.addInput(input)
        }

        let output = AVCaptureMetadataOutput()
        if session.canAddOutput(output) {
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
        }

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.frame = view.bounds
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)
        previewLayer = preview

        captureSession = session
        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
        }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let string = object.stringValue else { return }
        captureSession?.stopRunning()
        onScan?(string)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        captureSession?.stopRunning()
    }
}
