import AppKit
import CryptoKit
import ImageIO

// Read-only diagnostic for one explicitly selected provider user frame, piped
// through stdin. Arguments are that QA's exact PNG blob and our own GIF fixture.
// Does not scan account directories, send a prompt, or modify any transcript.
@main
enum ImageProviderRoundTripRegression {
    static func main() {
        do { try verify() }
        catch { print("FAIL: \(error)"); exit(1) }
    }

    private static func verify() throws {
        guard CommandLine.arguments.count == 3 else { throw failure("Expected exact PNG and GIF paths") }
        let input = FileHandle.standardInput.readDataToEndOfFile()
        guard let frame = try JSONSerialization.jsonObject(with: input) as? [String: Any],
              let content = frame["content"] as? [[String: Any]] else {
            throw failure("Expected one complete provider message frame")
        }
        let images = try content.filter { $0["type"] as? String == "input_image" }.map { block -> Data in
            guard let url = block["image_url"] as? String,
                  url.hasPrefix("data:image/png;base64,"),
                  let bytes = Data(base64Encoded: String(url.dropFirst("data:image/png;base64,".count))) else {
                throw failure("Expected provider-normalized PNG image bytes")
            }
            return bytes
        }
        guard images.count == 2 else { throw failure("Expected exactly two transmitted images") }
        let png = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let gif = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
        func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
        print("Image1 bytes=\(images[0].count) SHA256=\(digest(images[0]))")
        guard images[0] == png else { throw failure("Image1 differs from the exact QA PNG blob") }
        print("PASS: provider image1 exactly matches the imported HEIC-normalized PNG")
        guard let source = CGImageSourceCreateWithData(gif as CFData, nil),
              let target = CGImageSourceCreateWithData(images[1] as CFData, nil),
              let providerImage = CGImageSourceCreateImageAtIndex(target, 0, nil) else {
            throw failure("Cannot decode exact own GIF/provider PNG")
        }
        print("Image2 bytes=\(images[1].count) SHA256=\(digest(images[1])) dimensions=\(providerImage.width)x\(providerImage.height)")
        let actual = NSBitmapImageRep(cgImage: providerImage)
        var matches: [Int] = []
        for index in 0..<CGImageSourceGetCount(source) {
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil),
                  image.width == providerImage.width, image.height == providerImage.height else { continue }
            let expected = NSBitmapImageRep(cgImage: image)
            var matched = true
            for y in 0..<image.height { for x in 0..<image.width {
                guard let a = actual.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      let e = expected.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    matched = false; continue
                }
                if abs(a.redComponent - e.redComponent) > 0.03
                    || abs(a.greenComponent - e.greenComponent) > 0.03
                    || abs(a.blueComponent - e.blueComponent) > 0.03 { matched = false }
            } }
            if matched { matches.append(index) }
        }
        guard matches == [0] else { throw failure("Provider GIF-normalized PNG matching frame indices: \(matches)") }
        print("PASS: provider image2 pixels match only the own GIF first frame; attachment order preserved")
    }

    private static func failure(_ text: String) -> NSError {
        NSError(domain: "ImageProviderRoundTripFixture", code: 1,
                userInfo: [NSLocalizedDescriptionKey: text])
    }
}
