import XCTest
@testable import iCube

final class WebSocketFrameTests: XCTestCase {
  func testAcceptKeyMatchesRFC6455Example() {
    // RFC 6455 §1.3
    XCTAssertEqual(WebSocketHandshake.acceptKey(for: "dGhlIHNhbXBsZSBub25jZQ=="),
                   "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
  }
  func testEncodeShortTextFrameUnmasked() {
    let f = WebSocketFrame(fin: true, opcode: .text, payload: Data("Hi".utf8))
    XCTAssertEqual([UInt8](f.encode()), [0x81, 0x02, 0x48, 0x69])
  }
  func testDecodeMaskedClientFrame() {
    // "Hello" masked with key 37 fa 21 3d (RFC 6455 §5.7)
    let bytes: [UInt8] = [0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58]
    let r = WebSocketFrame.decode(Data(bytes))
    XCTAssertEqual(r?.consumed, 11)
    XCTAssertEqual(r?.frame.opcode, .text)
    XCTAssertEqual(r.map { String(decoding: $0.frame.payload, as: UTF8.self) }, "Hello")
  }
  func testDecodeIncompleteReturnsNil() {
    XCTAssertNil(WebSocketFrame.decode(Data([0x81, 0x85, 0x37])))
  }
  func testEncode16BitLength() {
    let f = WebSocketFrame(fin: true, opcode: .text, payload: Data(repeating: 0x41, count: 300))
    let b = [UInt8](f.encode())
    XCTAssertEqual(Array(b[0..<4]), [0x81, 126, 0x01, 0x2C])
  }
}
