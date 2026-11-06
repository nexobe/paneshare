#if os(macOS)
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// A QR code made on this Mac. Nothing leaves it.
struct QRCodeView: View {
    let text: String

    var body: some View {
        if let image = Self.image(for: text) {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .frame(width: 220, height: 220)
                .accessibilityLabel("QR code for the share link")
        } else {
            Text("This link is too long for a QR code.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private static func image(for text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: output.extent.size)
    }
}
#endif
