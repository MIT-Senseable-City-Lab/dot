import XCTest
@testable import TrapjawApp

final class TrapjawProcessorTests: XCTestCase {

    func testRapidPauseResumeCycles() async {
        let processor = TrapjawProcessor()

        for i in 0..<50 {
            print("[TEST] Cycle \(i+1)/50")
            await processor.start()

            try? await Task.sleep(nanoseconds: 200_000_000)

            processor.pause()

            XCTAssertFalse(processor.isRunning, "isRunning should be false after pause on cycle \(i+1)")

            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func testPauseWhenNotStarted() {
        let processor = TrapjawProcessor()
        processor.pause()
        XCTAssertFalse(processor.isRunning)
    }

    func testStartIsIdempotentWhenAlreadyRunning() async {
        let processor = TrapjawProcessor()
        await processor.start()

        await processor.start()

        XCTAssertTrue(processor.isRunning)
    }
}
