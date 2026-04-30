import Foundation
#if canImport(AVFoundation) && os(iOS)
@preconcurrency import AVFoundation
import Vision
import UIKit
#endif

nonisolated enum BarcodeScannerError: LocalizedError, Sendable {
    case cameraUnavailable
    case cameraDenied
    case configurationFailed

    var errorDescription: String? {
        switch self {
        case .cameraUnavailable: "Camera is not available on this device."
        case .cameraDenied: "Camera access was denied. Enable it in Settings to scan barcodes."
        case .configurationFailed: "Could not configure the camera for barcode scanning."
        }
    }
}

#if os(iOS)

@MainActor
protocol BarcodeScannerDelegate: AnyObject {
    func barcodeScanner(_ scanner: BarcodeScannerService, didDetect code: String)
    func barcodeScanner(_ scanner: BarcodeScannerService, didFailWith error: BarcodeScannerError)
}

@MainActor
final class BarcodeScannerService: NSObject {

    weak var delegate: BarcodeScannerDelegate?

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "CalorieCalc.barcode.session")
    private let metadataOutput = AVCaptureMetadataOutput()
    private var hasEmitted = false

    static func cameraAuthorizationGranted() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        case .denied, .restricted: return false
        @unknown default: return false
        }
    }

    func configure() async throws {
        guard await Self.cameraAuthorizationGranted() else {
            throw BarcodeScannerError.cameraDenied
        }
        guard let device = AVCaptureDevice.default(for: .video) else {
            throw BarcodeScannerError.cameraUnavailable
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            session.beginConfiguration()
            if session.canAddInput(input) { session.addInput(input) }
            if session.canAddOutput(metadataOutput) { session.addOutput(metadataOutput) }
            metadataOutput.setMetadataObjectsDelegate(self, queue: .main)
            metadataOutput.metadataObjectTypes = [
                .ean8, .ean13, .upce, .code128, .code39, .code93, .pdf417, .qr,
            ]
            session.commitConfiguration()
        } catch {
            throw BarcodeScannerError.configurationFailed
        }
    }

    func start() {
        hasEmitted = false
        let session = self.session
        sessionQueue.async {
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        let session = self.session
        sessionQueue.async {
            if session.isRunning { session.stopRunning() }
        }
    }
}

extension BarcodeScannerService: AVCaptureMetadataOutputObjectsDelegate {
    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard let first = metadataObjects.compactMap({ $0 as? AVMetadataMachineReadableCodeObject }).first,
              let code = first.stringValue else { return }
        Task { @MainActor [weak self] in
            guard let self, !self.hasEmitted else { return }
            self.hasEmitted = true
            self.delegate?.barcodeScanner(self, didDetect: code)
        }
    }
}

#endif
