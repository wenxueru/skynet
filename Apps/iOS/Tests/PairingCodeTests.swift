import XCTest
@testable import Skynet

/// Pairing-code codec and constant-time comparison tests. These cover the
/// wire format the Mac and iPhone share, so they double as the format spec.
final class PairingCodeTests: XCTestCase {
    private let codec = PairingCodeCodec()
    private let endpoint = URL(string: "https://mac.example:7343/relay")!

    // MARK: - Round trips

    func testRoundTripWithoutExpiry() throws {
        let offer = PairingOffer(
            relayEndpoint: endpoint,
            machineName: "Studio Mac",
            token: "tok-abc123"
        )
        let decoded = try codec.decode(codec.encode(offer))
        XCTAssertEqual(decoded, offer)
        XCTAssertFalse(decoded.isExpired)
    }

    func testRoundTripWithFutureExpiry() throws {
        let offer = PairingOffer(
            relayEndpoint: endpoint,
            machineName: "Den Mini",
            token: "tok-xyz",
            expiresAt: Date(timeIntervalSinceNow: 300)
        )
        let decoded = try codec.decode(codec.encode(offer))
        XCTAssertEqual(decoded.relayEndpoint, offer.relayEndpoint)
        XCTAssertEqual(decoded.machineName, offer.machineName)
        XCTAssertEqual(decoded.token, offer.token)
        let decodedExpiry = try XCTUnwrap(decoded.expiresAt).timeIntervalSince1970
        let expectedExpiry = try XCTUnwrap(offer.expiresAt).timeIntervalSince1970
        XCTAssertEqual(decodedExpiry, expectedExpiry, accuracy: 1, "expiry travels as whole seconds")
        XCTAssertFalse(decoded.isExpired)
    }

    func testEncodedFormUsesSkynetPairScheme() throws {
        let offer = PairingOffer(
            relayEndpoint: endpoint,
            machineName: "Studio Mac",
            token: "tok-abc123"
        )
        let encoded = codec.encode(offer)
        XCTAssertTrue(encoded.hasPrefix("skynet-pair://pair?"), encoded)
        XCTAssertFalse(encoded.contains(endpoint.absoluteString), "endpoint must be base64url-encoded")
    }

    func testDecodeTrimsSurroundingWhitespaceAndQuotes() throws {
        let offer = PairingOffer(
            relayEndpoint: endpoint,
            machineName: "Studio Mac",
            token: "tok-abc123"
        )
        let decoded = try codec.decode("  \"\(codec.encode(offer))\"  \n")
        XCTAssertEqual(decoded.token, offer.token)
    }

    // MARK: - Rejection

    func testDecodeRejectsGarbage() {
        XCTAssertThrowsError(try codec.decode("hello world")) { error in
            XCTAssertEqual(error as? PairingError, .invalidCode)
        }
    }

    func testDecodeRejectsForeignSchemes() {
        XCTAssertThrowsError(try codec.decode("https://example.com/pair?v=1&e=abc&t=tok"))
        XCTAssertThrowsError(try codec.decode("skynet-pair://other?v=1&e=abc&t=tok"))
    }

    func testDecodeRejectsMissingRequiredParameters() {
        let full = codec.encode(
            PairingOffer(relayEndpoint: endpoint, machineName: "Studio Mac", token: "tok-abc123")
        )

        func reencoded(drop name: String) -> String {
            guard let url = URL(string: full),
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  var items = components.queryItems else { return "" }
            items.removeAll { $0.name == name }
            var edited = components
            edited.queryItems = items
            return edited.url?.absoluteString ?? ""
        }

        for missing in ["v", "e", "t"] {
            XCTAssertThrowsError(
                try codec.decode(reencoded(drop: missing)),
                "code without \(missing) must be rejected"
            )
        }
    }

    func testDecodeRejectsUnknownVersion() throws {
        let offer = PairingOffer(
            relayEndpoint: endpoint,
            machineName: "Studio Mac",
            token: "tok-abc123"
        )
        let encoded = codec.encode(offer).replacingOccurrences(of: "?v=1&", with: "?v=2&")
        XCTAssertThrowsError(try codec.decode(encoded)) { error in
            XCTAssertEqual(error as? PairingError, .invalidCode)
        }
    }

    func testDecodeRejectsCorruptBase64Endpoint() {
        let raw = "skynet-pair://pair?v=1&m=Mac&e=not%20base64%20at%20all&t=tok"
        XCTAssertThrowsError(try codec.decode(raw))
    }

    func testDecodeDefaultsMachineNameWhenMissing() throws {
        let raw = "skynet-pair://pair?v=1&e=aHR0cHM6Ly9tYWMubG9jYWw6NzM0My9yZWxheQ&t=tok"
        let decoded = try codec.decode(raw)
        XCTAssertEqual(decoded.machineName, "Mac")
    }

    // MARK: - Expiry

    func testExpiredOfferIsReportedAsExpired() throws {
        let offer = PairingOffer(
            relayEndpoint: endpoint,
            machineName: "Studio Mac",
            token: "tok-late",
            expiresAt: Date(timeIntervalSinceNow: -1)
        )
        let decoded = try codec.decode(codec.encode(offer))
        XCTAssertTrue(decoded.isExpired)
    }

    // MARK: - Constant-time comparison

    func testConstantTimeComparisonMatchesIdenticalStrings() {
        XCTAssertTrue(ConstantTimeComparison.equal("418942", "418942"))
        XCTAssertTrue(ConstantTimeComparison.equal("", ""))
    }

    func testConstantTimeComparisonRejectsDifferentStrings() {
        XCTAssertFalse(ConstantTimeComparison.equal("418942", "418943"))
        XCTAssertFalse(ConstantTimeComparison.equal("418942", "41s942"))
        XCTAssertFalse(ConstantTimeComparison.equal("", "418942"))
        XCTAssertFalse(ConstantTimeComparison.equal("418942", "4189422"))
    }
}
