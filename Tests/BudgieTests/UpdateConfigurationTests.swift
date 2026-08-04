import Foundation
import XCTest

final class UpdateConfigurationTests: XCTestCase {
    func testSparkleFeedAndSigningConfigurationIsPresent() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let infoURL = repositoryRoot.appendingPathComponent("Info.plist")
        let data = try Data(contentsOf: infoURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )

        XCTAssertEqual(
            plist["SUFeedURL"] as? String,
            "https://github.com/mkh09353/budgie/releases/latest/download/appcast.xml"
        )
        XCTAssertFalse(try XCTUnwrap(plist["SUPublicEDKey"] as? String).isEmpty)
        XCTAssertEqual(plist["SUEnableAutomaticChecks"] as? Bool, true)
        XCTAssertEqual(plist["SUAutomaticallyUpdate"] as? Bool, true)
    }
}
