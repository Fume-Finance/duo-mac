import AVFoundation
import UIKit

/// Scans the pairing QR code in the Mac's Duo Mac window, inside the app (no trip to the Camera app).
final class QRScanner: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let session = AVCaptureSession()
    private var done: ((String?) -> Void)?

    static func scan(from host: UIViewController, done: @escaping (String?) -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { ok in
            DispatchQueue.main.async {
                guard ok else { return done(nil) }
                let v = QRScanner()
                v.done = done
                v.modalPresentationStyle = .fullScreen
                host.present(v, animated: true)
            }
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let cam = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: cam),
              session.canAddInput(input) else { return finish(nil) }
        session.addInput(input)
        let out = AVCaptureMetadataOutput()
        guard session.canAddOutput(out) else { return finish(nil) }
        session.addOutput(out)
        out.setMetadataObjectsDelegate(self, queue: .main)
        out.metadataObjectTypes = [.qr]
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)

        let label = UILabel()
        label.text = "Point at the QR code in Duo Mac on your Mac"
        label.textColor = .white
        label.font = .systemFont(ofSize: 16, weight: .semibold)
        label.textAlignment = .center
        label.numberOfLines = 0
        var bc = UIButton.Configuration.filled()
        bc.title = "Cancel"
        bc.baseBackgroundColor = UIColor(white: 0, alpha: 0.6)
        bc.cornerStyle = .capsule
        let cancel = UIButton(configuration: bc, primaryAction: UIAction { [weak self] _ in self?.finish(nil) })
        for v in [label, cancel] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            cancel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            cancel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])
        DispatchQueue.global(qos: .userInitiated).async { [session] in session.startRunning() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        view.layer.sublayers?.compactMap { $0 as? AVCaptureVideoPreviewLayer }.forEach { $0.frame = view.bounds }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard let s = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        finish(s)
    }

    private func finish(_ result: String?) {
        guard let d = done else { return }
        done = nil
        session.stopRunning()
        dismiss(animated: true) { d(result) }
    }
}
