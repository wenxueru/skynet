// Compiled with actual AppModel attachment methods by the companion script.
@main
@MainActor
enum ImageImportRegression {
    static func main() {
        do { try verify() }
        catch { print("FAIL: \(error)"); exit(1) }
    }

    private static func verify() throws {
        let fixture = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("DerivedData/qa-image-import-20261003")
        let files = FileManager.default
        let names = ["sample.png", "sample.jpg", "sample.tiff", "jpeg-as-png.png", "invalid.png",
                     "animated.gif", "rotated.heic", "sample.webp", "webp-as-png.png"]
            + (1...8).map { "orientation-\($0).tiff" }
        if CommandLine.arguments.contains("--cleanup") {
            for name in names {
                let url = fixture.appendingPathComponent(name)
                if files.fileExists(atPath: url.path) { try files.removeItem(at: url) }
            }
            guard try files.contentsOfDirectory(atPath: fixture.path).isEmpty else {
                throw NSError(domain: "ImageImportFixture", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Unexpected files remain; refusing directory cleanup."])
            }
            try files.removeItem(at: fixture)
            print("PASS: own image fixture removed")
            return
        }
        try files.createDirectory(at: fixture, withIntermediateDirectories: true)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
                                     bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0)!
        for y in 0..<16 { for x in 0..<16 {
            bitmap.setColor((x < 8) == (y < 8)
                ? NSColor(deviceRed: 0.1, green: 0.4, blue: 0.9, alpha: 1)
                : NSColor(deviceRed: 0.9, green: 0.5, blue: 0.1, alpha: 1), atX: x, y: y)
        } }
        let png = bitmap.representation(using: .png, properties: [:])!
        let tiff = bitmap.tiffRepresentation!
        // Distinct palettes let the installed two-image vision probe verify
        // attachment order, not merely recognize two identical thumbnails.
        for y in 0..<16 { for x in 0..<16 {
            bitmap.setColor((x < 8) == (y < 8)
                ? NSColor(deviceRed: 0.9, green: 0.1, blue: 0.1, alpha: 1)
                : NSColor(deviceRed: 0.1, green: 0.8, blue: 0.1, alpha: 1), atX: x, y: y)
        } }
        let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8])!
        let pngSource = CGImageSourceCreateWithData(png as CFData, nil)!
        let jpegSource = CGImageSourceCreateWithData(jpeg as CFData, nil)!
        let gif = try encode(type: "com.compuserve.gif", images: [
            CGImageSourceCreateImageAtIndex(pngSource, 0, nil)!,
            CGImageSourceCreateImageAtIndex(jpegSource, 0, nil)!,
        ])
        let landscape = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 8,
                                        bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
                                        isPlanar: false, colorSpaceName: .deviceRGB,
                                        bytesPerRow: 0, bitsPerPixel: 0)!
        let colors: [NSColor] = [
            NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1),
            NSColor(deviceRed: 0, green: 1, blue: 0, alpha: 1),
            NSColor(deviceRed: 0, green: 0, blue: 1, alpha: 1),
            NSColor(deviceRed: 1, green: 1, blue: 0, alpha: 1),
        ]
        for y in 0..<8 { for x in 0..<16 {
            landscape.setColor(colors[(y < 4 ? 0 : 2) + (x < 8 ? 0 : 1)], atX: x, y: y)
        } }
        let landscapeImage = landscape.cgImage!
        let heic = try encode(type: "public.heic", images: [landscapeImage], orientation: 6)
        var inputs: [(String, Data, String)] = [
            ("sample.png", png, "image/png"), ("sample.jpg", jpeg, "image/jpeg"),
            ("sample.tiff", tiff, "image/png"), ("jpeg-as-png.png", jpeg, "image/jpeg"),
            ("animated.gif", gif, "image/gif"), ("rotated.heic", heic, "image/png"),
        ]
        // ImageIO decodes but cannot encode WebP. Accept an independently
        // encoded fixture, then exercise the actual importer with both names.
        if let index = CommandLine.arguments.firstIndex(of: "--webp-fixture") {
            guard index + 1 < CommandLine.arguments.count else {
                throw NSError(domain: "ImageImportFixture", code: 5,
                              userInfo: [NSLocalizedDescriptionKey: "Missing WebP fixture path."])
            }
            let webp = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            guard let source = CGImageSourceCreateWithData(webp as CFData, nil),
                  CGImageSourceGetType(source) as String? == "org.webmproject.webp",
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  image.width == 16, image.height == 12 else {
                throw NSError(domain: "ImageImportFixture", code: 6,
                              userInfo: [NSLocalizedDescriptionKey: "Expected genuine 16x12 WebP fixture."])
            }
            inputs.append(("sample.webp", webp, "image/webp"))
            inputs.append(("webp-as-png.png", webp, "image/webp"))
        }
        for orientation in 1...8 {
            inputs.append(("orientation-\(orientation).tiff",
                try encode(type: "public.tiff", images: [landscapeImage], orientation: orientation),
                "image/png"))
        }
        for (name, data, _) in inputs { try data.write(to: fixture.appendingPathComponent(name)) }
        try Data("not an image".utf8).write(to: fixture.appendingPathComponent("invalid.png"))
        if CommandLine.arguments.contains("--prepare") {
            print("Prepared only own image fixtures at \(fixture.path)")
            return
        }
        var failures: [String] = []
        func expect(_ condition: Bool, _ label: String) {
            print("\(condition ? "PASS" : "FAIL"): \(label)")
            if !condition { failures.append(label) }
        }
        for (name, original, expectedType) in inputs {
            let model = ImageImportHarness()
            model.attachImage(url: fixture.appendingPathComponent(name))
            expect(model.errorMessage == nil && model.pendingAttachments.count == 1, "\(name) imports")
            guard let attachment = model.pendingAttachments.first,
                  case .inline(let bytes, _) = attachment.payload else { continue }
            expect(attachment.mediaType == expectedType, "\(name) detected media type")
            expect(NSImage(data: bytes) != nil, "\(name) decodable attachment")
            if name.hasSuffix(".tiff") || name.hasSuffix(".heic") {
                expect(bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]), "\(name) encoded as real PNG")
            } else {
                expect(bytes == original, "\(name) original supported bytes preserved")
            }
            if expectedType == "image/webp" {
                let source = CGImageSourceCreateWithData(bytes as CFData, nil)!
                let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
                expect(image.width == 16 && image.height == 12, "\(name) dimensions preserved")
                expect(attachment.fileName == name, "\(name) filename preserved")
            }
            if name == "animated.gif" {
                let source = CGImageSourceCreateWithData(bytes as CFData, nil)!
                expect(CGImageSourceGetCount(source) == 2, "GIF retains both animation frames")
                let durations = (0..<CGImageSourceGetCount(source)).map { index -> Double in
                    let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)! as NSDictionary
                    let gifProperties = properties[kCGImagePropertyGIFDictionary] as? NSDictionary
                    return gifProperties?[kCGImagePropertyGIFDelayTime] as? Double ?? 0
                }
                expect(durations == [0.25, 0.25], "GIF retains both nonzero frame durations")
            }
            if name == "rotated.heic" || name.hasPrefix("orientation-") {
                let source = CGImageSourceCreateWithData(original as CFData, nil)!
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)! as NSDictionary
                let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
                let expectedOrientation = name == "rotated.heic" ? 6
                    : Int(name.dropFirst("orientation-".count).dropLast(".tiff".count))!
                expect(orientation == expectedOrientation, "\(name) fixture carries the intended orientation")
                let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(bytes as CFData, nil)!, 0, nil)!
                expect(image.width == (orientation >= 5 ? 8 : 16)
                       && image.height == (orientation >= 5 ? 16 : 8),
                       "\(name) normalization preserves the displayed dimensions")
                let reference = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                ] as CFDictionary)!
                let actual = NSBitmapImageRep(cgImage: image)
                let expected = NSBitmapImageRep(cgImage: reference)
                var cornersMatch = actual.pixelsWide == expected.pixelsWide
                    && actual.pixelsHigh == expected.pixelsHigh
                if cornersMatch {
                    for (x, y) in [(1, 1), (actual.pixelsWide - 2, 1),
                                   (1, actual.pixelsHigh - 2), (actual.pixelsWide - 2, actual.pixelsHigh - 2)] {
                        let a = actual.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                        let e = expected.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                        cornersMatch = cornersMatch && abs(a.redComponent - e.redComponent) < 0.02
                            && abs(a.greenComponent - e.greenComponent) < 0.02
                            && abs(a.blueComponent - e.blueComponent) < 0.02
                    }
                }
                expect(cornersMatch, "\(name) normalization preserves rotated/mirrored corners")
            }
        }
        let invalid = ImageImportHarness()
        invalid.attachImage(url: fixture.appendingPathComponent("invalid.png"))
        expect(invalid.pendingAttachments.isEmpty && invalid.errorMessage != nil,
               "invalid image rejected without an attachment")
        if !failures.isEmpty {
            throw NSError(domain: "ImageImportFixture", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: failures.joined(separator: "; ")])
        }
    }

    private static func encode(type: String, images: [CGImage], orientation: Int = 1) throws -> Data {
        let bytes = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(bytes, type as CFString, images.count, nil) else {
            throw NSError(domain: "ImageImportFixture", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "ImageIO cannot encode \(type)."])
        }
        if type == "com.compuserve.gif" {
            CGImageDestinationSetProperties(destination,
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        }
        for image in images {
            var properties: [CFString: Any] = [kCGImagePropertyOrientation: orientation]
            if type == "com.compuserve.gif" {
                properties[kCGImagePropertyGIFDictionary] = [kCGImagePropertyGIFDelayTime: 0.25]
            }
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "ImageImportFixture", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "ImageIO failed to encode \(type)."])
        }
        return bytes as Data
    }
}
