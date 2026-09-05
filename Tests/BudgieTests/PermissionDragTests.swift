import AppKit
import XCTest
@testable import Budgie

final class PermissionDragTests: XCTestCase {
    func testCancelledDragRestoresReadyState() {
        let presentation = PermissionDragPresentation(title: "Accessibility", appURL: nil)
        presentation.phase = .dragging
        presentation.dragEnded([])
        XCTAssertEqual(presentation.phase, .ready)
    }

    func testAcceptedDropWaitsForPermissionInsteadOfClaimingSuccess() {
        let presentation = PermissionDragPresentation(title: "Input Monitoring", appURL: nil)
        presentation.phase = .dragging
        presentation.dragEnded(.copy)
        XCTAssertEqual(presentation.phase, .waiting)
    }

    func testOnlyApplicationBundlesCanBeDragged() throws {
        XCTAssertNil(PermissionDragController.draggableApplicationURL(URL(fileURLWithPath: "/tmp/Budgie")))
        XCTAssertNil(PermissionDragController.draggableApplicationURL(URL(string: "https://example.com/Budgie.app")!))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = root.appendingPathComponent("Budgie.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(PermissionDragController.draggableApplicationURL(app))
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try Data().write(to: app.appendingPathComponent("Contents/Info.plist"))
        XCTAssertEqual(PermissionDragController.draggableApplicationURL(app), app)
    }

    func testNativeDragPayloadPreservesApplicationFileURL() throws {
        let url = URL(fileURLWithPath: "/Applications/Budgie Test.app")
        let source = AppDragSourceView()
        XCTAssertNil(source.makeDraggingItem(at: .zero))
        source.appURL = url
        let item = try XCTUnwrap(source.makeDraggingItem(at: .zero))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(pasteboard.writeObjects([try XCTUnwrap(item.item as? NSPasteboardWriting)]))
        XCTAssertTrue(pasteboard.types?.contains(.fileURL) == true)
        let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]
        XCTAssertEqual(urls, [url])
    }
}
