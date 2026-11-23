import CoreGraphics
import CoreImage
import Foundation

public enum QRCode {
    /// Renders `text` as a QR code (error correction level M), scaled with
    /// nearest-neighbour so the modules stay crisp. The caller provides the white
    /// background and margin around it.
    /// - Parameter pixelsPerModule: edge length of one QR module in pixels.
    public static func image(for text: String, pixelsPerModule: Int = 8) -> CGImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }

        let scale = CGFloat(max(1, pixelsPerModule))
        let scaled = output.samplingNearest().transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        // Software renderer: tiny image, and no GPU context to set up in a menu bar agent.
        let context = CIContext(options: [.useSoftwareRenderer: true])
        return context.createCGImage(scaled, from: scaled.extent.integral)
    }

    /// Decodes the QR codes found in `image`. Used by the tests to prove that what
    /// the pairing window shows really scans back to the pairing URI.
    public static func decode(_ image: CGImage) -> [String] {
        let detector = CIDetector(
            ofType: CIDetectorTypeQRCode, context: CIContext(options: [.useSoftwareRenderer: true]),
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        let features = detector?.features(in: CIImage(cgImage: image)) ?? []
        return features.compactMap { ($0 as? CIQRCodeFeature)?.messageString }
    }
}
