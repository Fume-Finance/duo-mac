import AVFoundation
import UIKit

/// Scans the pairing QR code in the Mac's Duo Mac window, inside the app (no trip to the Camera app).
final class QRScanner: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let session = AVCaptureSession()
    private var done: ((String?) -> Void)?

    /// done: what the code says, or nil if cancelled. `denied` instead when the camera isn't allowed
    /// (Settings › Duo Mac), so the page can say where to allow it.
    static func scan(from host: UIViewController, denied: @escaping () -> Void, done: @escaping (String?) -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { ok in
            DispatchQueue.main.async {
                guard ok else { return denied() }
                let v = QRScanner()
                v.done = done
                v.modalPresentationStyle = .fullScreen
                // From whatever is on top (a sheet may be up). If iOS doesn't show it after all, answer anyway:
                // the page's call must always get its reply.
                var top = host
                while let p = top.presentedViewController, !p.isBeingDismissed { top = p }
                top.present(v, animated: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    if v.presentingViewController == nil, let d = v.done { v.done = nil; d(nil) }
                }
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
        label.font = .preferredFont(forTextStyle: .headline) // follows Settings › Display › Text Size
        label.adjustsFontForContentSizeCategory = true
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
