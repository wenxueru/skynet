import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main
enum IOSDemoEncoder {
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count == 3 else { fatalError("Usage: encode-ios-demo <frames-directory> <output-directory>") }
        let frames = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let output = URL(fileURLWithPath: arguments[2], isDirectory: true)
        var images: [CGImage] = []
        for name in ["library", "session", "queue"] {
            let sourceURL = frames.appendingPathComponent("\(name).png")
            guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
                  let raw = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                fatalError("Cannot decode demo frame: \(name)")
            }
            let image: CGImage
            do { image = try DemoImage.standardSRGB(raw) }
            catch DemoImage.ConversionError.contextCreationFailed {
                fatalError("Cannot decode demo frame: \(name)")
            } catch { fatalError("Cannot encode demo frame") }
            guard let png = CGImageDestinationCreateWithURL(output.appendingPathComponent("ios-\(name).png") as CFURL,
                UTType.png.identifier as CFString, 1, nil) else { fatalError("Cannot encode demo frame") }
            CGImageDestinationAddImage(png, image, nil)
            guard CGImageDestinationFinalize(png) else { fatalError("Cannot save demo frame") }
            images.append(image)
        }
        guard let gif = CGImageDestinationCreateWithURL(output.appendingPathComponent("ios-workflow.gif") as CFURL,
            UTType.gif.identifier as CFString, images.count, nil) else { fatalError("Cannot encode demo GIF") }
        CGImageDestinationSetProperties(gif,
            [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for image in images {
            CGImageDestinationAddImage(gif, image,
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 2.5]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(gif) else { fatalError("Cannot save demo GIF") }
    }
}
