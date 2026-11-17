// Layers added to a view's backing layer draw with the view (an
// AVPlayerLayer's picture, shape and gradient layers), in the view's own
// coordinates; documents named on the command line reach the delegate; a
// window made from a view controller shows its view.

import XCTest
import RunwayCore
@testable import AppKit

@MainActor
final class LayerHostingTests: XCTestCase {
    private func solid(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ w: Int = 4, _ h: Int = 4) -> CGImage {
        CGImage(width: w, height: h, rgba: Array((0..<(w * h)).map { _ in [r, g, b, 255] }.joined()), hasAlpha: false)
    }

    private func render(_ v: NSView) -> (Int, Int) -> (UInt8, UInt8, UInt8) {
        let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
        v.cacheDisplay(in: v.bounds, to: rep)
        let px = rep.bitmapData!, row = rep.bytesPerRow
        return { x, y in (px[y * row + x * 4], px[y * row + x * 4 + 1], px[y * row + x * 4 + 2]) }
    }

    final class Flipped: NSView { override var isFlipped: Bool { true } }

    func testSublayerContentsDrawInAFlippedView() {
        let v = Flipped(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        v.wantsLayer = true
        v.layer?.backgroundColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        let picture = CALayer()
        picture.contents = solid(255, 0, 0)
        picture.frame = CGRect(x: 0, y: 0, width: 20, height: 10)
        v.layer?.addSublayer(picture)
        let px = render(v)
        // A flipped view's layers are laid out top-down, as AppKit flips their geometry.
        XCTAssertEqual(px(5, 5).0, 255)
        XCTAssertLessThan(px(5, 5).1, 30, "the picture at the top left")
        XCTAssertEqual(px(5, 35).1, 255, "white below it")
        XCTAssertEqual(px(30, 5).1, 255, "white beside it")
    }

    func testSublayersInAnUnflippedViewAndNesting() {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        v.wantsLayer = true
        let host = CALayer()
        host.frame = CGRect(x: 10, y: 0, width: 30, height: 20)
        let inner = CALayer()
        inner.backgroundColor = CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
        inner.frame = CGRect(x: 0, y: 0, width: 10, height: 10)
        host.addSublayer(inner)
        v.layer?.addSublayer(host)
        let px = render(v)
        // Bottom-left origin: (10…20, 0…10) in the view is the bottom rows of the bitmap.
        XCTAssertEqual(px(15, 35).2, 255)
        XCTAssertLessThan(px(15, 35).0, 30)
        XCTAssertLessThan(px(15, 5).2, 30, "nothing at the top")
    }

    func testPictureLayerFollowsChangesAndMasksCorners() {
        let v = Flipped(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        v.wantsLayer = true
        let picture = CALayer()
        picture.frame = v.bounds
        picture.cornerRadius = 12
        picture.masksToBounds = true
        picture.contentsGravity = .resize
        v.layer?.addSublayer(picture)
        picture.contents = solid(0, 255, 0)
        var px = render(v)
        XCTAssertEqual(px(20, 20).1, 255)
        XCTAssertLessThan(px(0, 0).1, 100, "the rounded corner is clipped")
        // A new picture (the next video frame) replaces the old.
        picture.contents = solid(0, 0, 255)
        px = render(v)
        XCTAssertEqual(px(20, 20).2, 255)
        XCTAssertLessThan(px(20, 20).1, 30)
    }

    func testShapeAndGradientLayersDraw() {
        let v = Flipped(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        v.wantsLayer = true
        let shape = CAShapeLayer()
        shape.frame = v.bounds
        shape.path = CGPath(rect: CGRect(x: 0, y: 0, width: 10, height: 10), transform: nil)
        shape.fillColor = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        let gradient = CAGradientLayer()
        gradient.frame = CGRect(x: 20, y: 20, width: 20, height: 20)
        gradient.colors = [CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1), CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)]
        v.layer?.addSublayer(shape)
        v.layer?.addSublayer(gradient)
        let px = render(v)
        XCTAssertEqual(px(5, 5).0, 255, "the shape's fill")
        XCTAssertEqual(px(30, 30).2, 255, "the gradient")
        XCTAssertLessThan(px(30, 5).0, 30, "nothing elsewhere")
    }

    func testCommandLineDocumentsAreOpened() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("runway-open-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let urls = NSApplication.launchURLs(["/usr/bin/app", "--launched-at-login", dir.path, "/no/such/file", "file:///tmp/x.mov"])
        XCTAssertEqual(urls.map(\.path), [dir.standardizedFileURL.path, "/tmp/x.mov"])
        XCTAssertEqual(NSApplication.launchURLs(["/usr/bin/app"]), [])
    }

    func testWindowFromAViewControllerShowsItsView() {
        final class Content: NSViewController {
            override func loadView() { view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200)) }
        }
        let vc = Content()
        let w = NSWindow(contentViewController: vc)
        XCTAssertTrue(w.contentViewController === vc)
        XCTAssertTrue(w.contentView === vc.view)
        XCTAssertEqual(w.contentView?.frame.size, CGSize(width: 300, height: 200))
    }
}
