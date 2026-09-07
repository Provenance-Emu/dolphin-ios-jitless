import CryptoKit
import Foundation

enum WebSocketOpcode: UInt8 { case continuation = 0x0, text = 0x1, binary = 0x2, close = 0x8, ping = 0x9, pong = 0xA }

struct WebSocketFrame {
  let fin: Bool
  let opcode: WebSocketOpcode
  let payload: Data

  /// Server → client frames are never masked (RFC 6455 §5.1).
  func encode() -> Data {
    var out = Data()
    out.append((fin ? 0x80 : 0) | opcode.rawValue)
    let n = payload.count
    if n < 126 { out.append(UInt8(n)) }
    else if n <= 0xFFFF { out.append(126); out.append(UInt8(n >> 8)); out.append(UInt8(n & 0xFF)) }
    else { out.append(127); for s in stride(from: 56, through: 0, by: -8) { out.append(UInt8((UInt64(n) >> UInt64(s)) & 0xFF)) } }
    out.append(payload)
    return out
  }

  /// Decodes one frame from the front of `data`, unmasking if the client masked it.
  static func decode(_ data: Data) -> (frame: WebSocketFrame, consumed: Int)? {
    let b = [UInt8](data)
    guard b.count >= 2 else { return nil }
    let fin = b[0] & 0x80 != 0
    guard let op = WebSocketOpcode(rawValue: b[0] & 0x0F) else { return nil }
    let masked = b[1] & 0x80 != 0
    var len = Int(b[1] & 0x7F)
    var i = 2
    if len == 126 { guard b.count >= 4 else { return nil }; len = Int(b[2]) << 8 | Int(b[3]); i = 4 }
    else if len == 127 { guard b.count >= 10 else { return nil }; len = 0; for k in 2..<10 { len = len << 8 | Int(b[k]) }; i = 10 }
    var key: [UInt8] = []
    if masked { guard b.count >= i + 4 else { return nil }; key = Array(b[i..<i+4]); i += 4 }
    guard b.count >= i + len else { return nil }
    var payload = Array(b[i..<i+len])
    if masked { for k in 0..<payload.count { payload[k] ^= key[k % 4] } }
    return (WebSocketFrame(fin: fin, opcode: op, payload: Data(payload)), i + len)
  }
}

enum WebSocketHandshake {
  private static let guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
  static func acceptKey(for clientKey: String) -> String {
    Data(Insecure.SHA1.hash(data: Data((clientKey + guid).utf8))).base64EncodedString()
  }
  static func response(for clientKey: String) -> Data {
    Data("""
    HTTP/1.1 101 Switching Protocols\r\n\
    Upgrade: websocket\r\n\
    Connection: Upgrade\r\n\
    Sec-WebSocket-Accept: \(acceptKey(for: clientKey))\r\n\
    \r\n
    """.utf8)
  }
}
