import SwiftUI

#if os(iOS)
import AVFoundation
import UIKit

struct BarcodeScannerView: View {
    let onCode: (String) -> Void

    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                ScannerRepresentable(onCode: onCode, onError: { errorMessage = $0 })
                    .ignoresSafeArea()
                VStack {
                    Spacer()
                    Text("Align the barcode in the frame")
                        .font(.footnote)
                        .padding(10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 40)
                }
                if let errorMessage {
                    VStack {
                        Spacer()
                        Text(errorMessage)
                            .multilineTextAlignment(.center)
                            .padding()
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                            .padding()
                    }
                }
            }
            .navigationTitle("Scan Barcode")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct ScannerRepresentable: UIViewControllerRepresentable {

    let onCode: (String) -> Void
    let onError: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerViewController {
        ScannerViewController(onCode: onCode, onError: onError)
    }

    func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) {}
}

@MainActor
final class ScannerViewController: UIViewController {

    private let service = BarcodeScannerService()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private let onCode: (String) -> Void
    private let onError: (String) -> Void

    init(onCode: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
        self.onCode = onCode
        self.onError = onError
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        service.delegate = self
        Task {
            do {
                try await service.configure()
                await MainActor.run {
                    let layer = AVCaptureVideoPreviewLayer(session: service.session)
                    layer.videoGravity = .resizeAspectFill
                    layer.frame = view.bounds
                    view.layer.addSublayer(layer)
                    self.previewLayer = layer
                    service.start()
                }
            } catch let error as BarcodeScannerError {
                onError(error.errorDescription ?? "Camera error")
            } catch {
                onError(error.localizedDescription)
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        service.stop()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }
}

extension ScannerViewController: BarcodeScannerDelegate {
    func barcodeScanner(_ scanner: BarcodeScannerService, didDetect code: String) {
        onCode(code)
    }

    func barcodeScanner(_ scanner: BarcodeScannerService, didFailWith error: BarcodeScannerError) {
        onError(error.errorDescription ?? "Scanner failed")
    }
}

#else

struct BarcodeScannerView: View {
    let onCode: (String) -> Void
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "barcode.viewfinder").font(.largeTitle)
            Text("Barcode scanning is only available on iOS.")
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

#endif
