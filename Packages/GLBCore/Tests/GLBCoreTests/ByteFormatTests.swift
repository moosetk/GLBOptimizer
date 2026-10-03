import XCTest
@testable import GLBCore

final class ByteFormatTests: XCTestCase {
    func testSizes() {
        XCTAssertEqual(ByteFormat.string(512), "512 B")
        XCTAssertEqual(ByteFormat.string(1536), "1.50 KB")
        XCTAssertEqual(ByteFormat.string(97_184_804), "92.7 MB")
    }

    func testRatio() {
        XCTAssertEqual(ByteFormat.ratio(output: 15, input: 100), "约为原来的 15.0%")
        XCTAssertEqual(ByteFormat.ratio(output: 1, input: 0), "—")
    }
}
