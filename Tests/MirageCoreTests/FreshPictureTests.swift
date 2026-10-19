import XCTest
@testable import MirageCore

final class FreshPictureTests: XCTestCase {
    func testOnlyStartResizeAndTierChangeRestartTheWholePicture() {
        XCTAssertTrue(FreshPictureTrigger.streamStart.restartsWholePicture)
        XCTAssertTrue(FreshPictureTrigger.resize.restartsWholePicture)
        XCTAssertTrue(FreshPictureTrigger.tierChange.restartsWholePicture)
        // A localized change of any size, and the keyframe that recovers from a loss, never do.
        XCTAssertFalse(FreshPictureTrigger.regionChange.restartsWholePicture)
        XCTAssertFalse(FreshPictureTrigger.recoveryKeyframe.restartsWholePicture)
    }
}
