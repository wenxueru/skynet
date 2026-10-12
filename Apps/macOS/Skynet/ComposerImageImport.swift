import AppKit
import ImageIO
import SkynetCore

enum ComposerImageImport {
    static func load(url: URL) throws -> ImageAttachment {
        try load(data: Data(contentsOf: url), suggestedFileName: url.lastPathComponent)
    }

    static func load(data: Data, suggestedFileName: String) throws -> ImageAttachment {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) else {
            throw ImportError.invalidImage(suggestedFileName)
        }
        // Detect the bytes, not the extension. Keep supported representations
        // intact (including GIF animation); normalize other native formats.
        let mediaType: String
        switch type as String {
        case "public.png": mediaType = "image/png"
        case "public.jpeg": mediaType = "image/jpeg"
        case "com.compuserve.gif": mediaType = "image/gif"
        case "org.webmproject.webp": mediaType = "image/webp"
        default:
            // Full-size transformed decoding preserves the displayed photo
            // orientation when converting away from EXIF-carrying formats.
            // No maximum size is supplied, so this does not downsample.
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ] as CFDictionary),
                let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                throw ImportError.invalidImage(suggestedFileName)
            }
            return ImageAttachment(data: png, mediaType: "image/png", fileName: suggestedFileName)
        }
        guard CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
            throw ImportError.invalidImage(suggestedFileName)
        }
        return ImageAttachment(data: data, mediaType: mediaType, fileName: suggestedFileName)
    }

    private enum ImportError: LocalizedError {
        case invalidImage(String)

        var errorDescription: String? {
            switch self {
            case .invalidImage(let name): "\(name) is not a readable image."
            }
        }
    }
}
