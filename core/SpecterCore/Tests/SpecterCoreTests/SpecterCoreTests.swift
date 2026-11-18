import XCTest
@testable import SpecterCore

final class SpecterCoreTests: XCTestCase {
    func testChirpGeneration() {
        let config = ChirpConfig()
        let chirp = makeChirp(c: config)
        XCTAssertEqual(chirp.count, config.n)
        XCTAssertTrue(chirp.contains { $0 != 0.0 })
    }
}
