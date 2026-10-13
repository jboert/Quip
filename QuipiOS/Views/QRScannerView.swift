import SwiftUI
import AVFoundation

struct QRScannerView: View {
    var onScan: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                // Simple camera-based QR reader using AVFoundation
                QRCameraView(onScan: onScan)
            }
            .navigationTitle("Scan QR Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// AVFoundation QR scanner
struct QRCameraView: UIViewControllerRepresentable {
    var onScan: (String) -> Void

    func makeUIViewController(context: Context) -> QRScannerController {
        let vc = QRScannerController()
        vc.onScan = onScan
        return vc
    }
    func updateUIViewController(_ uiViewController: QRScannerController, context: Context) {}
}

class QRScannerController: UIViewController, @preconcurrency AVCaptureMetadataOutputObjectsDelegate {
    var onScan: ((String) -> Void)?
    private var captureSession: AVCaptureSession?
    private var hasScanned = false

    /// The camera path has no other failure surface: the scanner is presented
    /// as a sheet whose whole job is the preview layer, so a setup failure
    /// renders as an unexplained black rectangle. Draw the cause + next step
    /// directly into the view instead.
    private func showFailure(_ message: String) {
        view.backgroundColor = .black
        let label = UILabel()
        label.text = message
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .white
        label.font = .preferredFont(forTextStyle: .callout)
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let session = AVCaptureSession()
        guard let device = AVCaptureDevice.default(for: .video) else {
            print("[Quip][Pairing] QR scanner: no video capture device available")
            showFailure("No camera on this device. Pair by entering the Mac's address instead.")
            return
        }
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            // Permission denied, camera in use by another app, or a hardware
            // fault. Swallowing this left the user staring at a black sheet
            // with no message and no way to know why the scan never fired.
            print("[Quip][Pairing] QR scanner: AVCaptureDeviceInput FAILED err=\(error)")
            showFailure("Can't open the camera.\nCheck Settings › Privacy › Camera, then try again.")
            return
        }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.frame = view.bounds
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)

        captureSession = session
        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
        }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !hasScanned,
              let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let str = obj.stringValue else { return }
        hasScanned = true
        captureSession?.stopRunning()
        onScan?(str)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if let layer = view.layer.sublayers?.first as? AVCaptureVideoPreviewLayer {
            layer.frame = view.bounds
        }
    }
}

// MARK: - Saved Connection Model
