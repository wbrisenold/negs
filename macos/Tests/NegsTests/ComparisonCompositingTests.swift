import AppKit
import XCTest
@testable import NegsApp

@MainActor final class ComparisonCompositingTests: XCTestCase {
    func testOriginalWipeHasAnOpaqueMaskAboveTheCurrentFrame() throws {
        func image(_ red: UInt8) throws -> CGImage {
            let bytes = Data([red, 0, 0, 255])
            return try XCTUnwrap(CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: try XCTUnwrap(CGDataProvider(data: bytes as CFData)), decode: nil,
                shouldInterpolate: false, intent: .defaultIntent))
        }
        func descendants(_ layer: CALayer) -> [CALayer] {
            (layer.sublayers ?? []).flatMap { [$0] + descendants($0) }
        }
        let current = try image(255), original = try image(128)
        let view = PhotographView(frame: CGRect(x: 0, y: 0, width: 100, height: 60))
        view.settled = false
        view.show(current, size: CGSize(width: 100, height: 60), rotation: 0,
                  comparisonImage: original, wipeFraction: 0.4)
        view.layoutSubtreeIfNeeded()
        let layers = descendants(try XCTUnwrap(view.layer))
        let comparison = try XCTUnwrap(layers.first { ($0.contents as AnyObject?) === original })
        let shown = try XCTUnwrap(layers.first { ($0.contents as AnyObject?) === current })
        let siblings = try XCTUnwrap(comparison.superlayer?.sublayers)
        XCTAssertEqual(comparison.superlayer, shown.superlayer)
        XCTAssertGreaterThan(try XCTUnwrap(siblings.firstIndex(of: comparison)), try XCTUnwrap(siblings.firstIndex(of: shown)))
        XCTAssertGreaterThan(try XCTUnwrap(siblings.firstIndex(of: comparison)), try XCTUnwrap(siblings.firstIndex(of: view.sharp)))
        let mask = try XCTUnwrap(comparison.mask)
        XCTAssertEqual(try XCTUnwrap(mask.backgroundColor).alpha, 1, accuracy: 0.001)
        XCTAssertEqual(mask.bounds.width, 40, accuracy: 0.001)
        view.show(current, size: CGSize(width: 100, height: 60), rotation: 0)
        XCTAssertTrue(comparison.isHidden)
    }
}
