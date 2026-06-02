import SwiftUI

#if os(iOS)
import UIKit
import PDFKit
import VisionKit
import UniformTypeIdentifiers

/// Wraps VisionKit's document camera so the Recipe Analyzer can scan a printed/handwritten
/// recipe. Returns one JPEG per scanned page.
struct DocumentScannerView: UIViewControllerRepresentable {
    let onScan: ([Data]) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan, onCancel: onCancel) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onScan: ([Data]) -> Void
        let onCancel: () -> Void

        init(onScan: @escaping ([Data]) -> Void, onCancel: @escaping () -> Void) {
            self.onScan = onScan
            self.onCancel = onCancel
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            var datas: [Data] = []
            for page in 0..<scan.pageCount {
                if let data = RecipeImageLoader.jpeg(from: scan.imageOfPage(at: page)) {
                    datas.append(data)
                }
            }
            onScan(datas)
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            onCancel()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            onCancel()
        }
    }
}

/// Converts assorted recipe inputs (UIImages, picked files, PDFs) into downscaled JPEG data
/// ready to send to the recognition service.
enum RecipeImageLoader {
    /// Max edge / quality tuned to keep recipe text legible while bounding the upload size.
    static func jpeg(from image: UIImage) -> Data? {
        image.scaled(toMaxDimension: 1536).jpegData(compressionQuality: 0.7)
    }

    /// Resolve picked file URLs (images and PDFs) into JPEG page images. PDFs are rendered
    /// page-by-page (capped). Security-scoped access is opened per URL.
    static func imageDatas(from urls: [URL]) -> [Data] {
        var datas: [Data] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { continue }
            if isPDF(url: url, data: data) {
                datas.append(contentsOf: pdfPageImages(data: data))
            } else if let image = UIImage(data: data), let jpeg = jpeg(from: image) {
                datas.append(jpeg)
            }
        }
        return datas
    }

    private static func isPDF(url: URL, data: Data) -> Bool {
        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) == true { return true }
        // %PDF magic header fallback.
        return data.prefix(4).elementsEqual([0x25, 0x50, 0x44, 0x46])
    }

    private static func pdfPageImages(data: Data, maxPages: Int = 5) -> [Data] {
        guard let doc = PDFDocument(data: data) else { return [] }
        var out: [Data] = []
        for index in 0..<min(doc.pageCount, maxPages) {
            guard let page = doc.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            guard bounds.width > 0, bounds.height > 0 else { continue }
            let scale: CGFloat = 2
            let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
            let renderer = UIGraphicsImageRenderer(size: size)
            let image = renderer.image { ctx in
                UIColor.white.set()
                ctx.fill(CGRect(origin: .zero, size: size))
                ctx.cgContext.translateBy(x: 0, y: size.height)
                ctx.cgContext.scaleBy(x: scale, y: -scale)
                page.draw(with: .mediaBox, to: ctx.cgContext)
            }
            if let jpeg = jpeg(from: image) { out.append(jpeg) }
        }
        return out
    }
}
#endif
