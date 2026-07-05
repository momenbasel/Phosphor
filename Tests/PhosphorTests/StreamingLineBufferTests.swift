import XCTest
@testable import Phosphor

final class StreamingLineBufferTests: XCTestCase {

    func testSplitsMultipleLines() {
        let b = StreamingLineBuffer()
        b.append(Data("a\nb\nc\n".utf8))
        XCTAssertEqual(b.drain(), ["a", "b", "c"])
    }

    func testPartialLineHeldUntilNewline() {
        let b = StreamingLineBuffer()
        b.append(Data("hel".utf8))
        XCTAssertEqual(b.drain(), [], "a line without a trailing newline must not be delivered yet")
        b.append(Data("lo\n".utf8))
        XCTAssertEqual(b.drain(), ["hello"])
    }

    func testBoundedCapacityKeepsNewest() {
        let b = StreamingLineBuffer(capacity: 3)
        for i in 1...10 { b.append(Data("\(i)\n".utf8)) }
        XCTAssertLessThanOrEqual(b.count, 3, "buffer must stay bounded regardless of input volume")
        XCTAssertEqual(b.drain(), ["8", "9", "10"], "must keep the newest lines")
    }

    func testUTF8SplitAcrossChunks() {
        // "é" == 0xC3 0xA9; the multibyte scalar is split across two reads.
        let b = StreamingLineBuffer()
        b.append(Data([0xC3]))
        b.append(Data([0xA9]))
        b.append(Data("\n".utf8))
        XCTAssertEqual(b.drain(), ["é"], "a UTF-8 scalar split across reads must not be dropped")
    }

    func testDrainClears() {
        let b = StreamingLineBuffer()
        b.append(Data("x\n".utf8))
        _ = b.drain()
        XCTAssertEqual(b.drain(), [], "drain must clear the buffer")
    }

    func testFinishFlushesRemainder() {
        let b = StreamingLineBuffer()
        b.append(Data("tail-no-newline".utf8))
        XCTAssertEqual(b.drain(), [])
        XCTAssertEqual(b.finish(), ["tail-no-newline"], "finish() flushes the trailing partial line")
    }
}
