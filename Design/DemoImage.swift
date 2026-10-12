import CoreGraphics

enum DemoImage {
    enum ConversionError: Error {
        case contextCreationFailed
        case imageCreationFailed
    }

    /// Copy pixels, never the display profile or source metadata.
    static func standardSRGB(_ image: CGImage) throws -> CGImage {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height,
                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ConversionError.contextCreationFailed
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let result = context.makeImage() else { throw ConversionError.imageCreationFailed }
        return result
    }
}
