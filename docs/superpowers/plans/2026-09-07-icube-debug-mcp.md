# iCube Debug MCP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a Claude Code session drive an iCube device — read/write/snapshot settings, step frames, screenshot, stream events — and compare a scenario's frame against upstream Dolphin on the Mac.

**Architecture:** The device's existing `NativeWebServer` (port 8723, loopback, reached via `iproxy`) gains iFly-compatible routes, raw (PNG) responses and an RFC 6455 WebSocket fed by a `DebugEventBus`. A Python FastMCP server on the Mac (`tools/mcp/icube_debug`) mirrors the routes as tools and adds composites: scenario runs, upstream comparison via `/Applications/Dolphin.app` frame dumps + SSIM, and settings bisection.

**Tech Stack:** Swift 6 (Network.framework, XCTest), Objective-C++ bridge to the Dolphin core, Python 3.12+ with `uv`, `fastmcp`, `httpx`, `websockets`, `pillow`, `scikit-image`, `respx`/`pytest`.

**Spec:** `docs/superpowers/specs/2026-09-07-icube-debug-mcp-design.md`

## Global Constraints

- Device server stays loopback-only, port 8723, DEBUG always-on, Release behind the existing `ICubeBenchServerEnabled` toggle. No auth.
- Every JSON route answers `{"ok": true, "data": …}` or `{"ok": false, "error": "…"}`; failures carry an HTTP 4xx/5xx (409 wrong core state, 404 unknown key/route, 504 step timeout).
- Route paths and JSON shapes match iFly's `docs/dev/debug-api.md` where the route exists there.
- WebSocket: text frames only, no extensions/compression, ping/pong answered.
- MCP tools never retry state-changing calls; every tool takes `device: str = "127.0.0.1:8723"`.
- SSIM pass threshold 0.97; determinism guard threshold 0.995.
- Scenario `start` is `"boot"` only in this plan; `{"state": path}` is a follow-up.
- Phase-2 geometry detector is NOT in this plan.
- Commits: conventional commits, `Co-Authored-By: Claude <noreply@anthropic.com>` trailer per repo convention. Run Swift steps from `Source/iOS/App` (`tuist generate` first); Python steps from `tools/mcp`.
- Xcode test invocation used throughout: `xcodebuild test -workspace iCube.xcworkspace -scheme "iCube (NJB)" -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:iCubeTests/<Class> 2>&1 | xcbeautify` (run from `Source/iOS/App`; the xcframework must exist, `make xcframework` if not).

---

## File map

Device (Swift, `Source/iOS/App/Common/Swift/Debug/`):
- `NativeWebServer.swift` — modify: `HTTPRequest.headers` already exists; add `RawResponse`, `addRawHandler`, `webSocketHandler`, upgrade path.
- `WebSocketFrame.swift` — new: pure codec + handshake key (unit-tested).
- `WebSocketConnection.swift` — new: per-connection frame loop over `NWConnection`.
- `DebugEventBus.swift` — new: actor, fan-out, producers.
- `SettingsSnapshots.swift` — new: store + diff.
- `DebugAPIRoutes.swift` — modify: new routes.
- `DebugServerManager.swift` — modify: start the bus, register `/ws/events`.

Bridge (ObjC++, `Source/iOS/App/Common/Bridging/`):
- `DOLDebugBridge.h/.mm` — new: core state, frame step, frame count, screenshot bytes, render state, log tail, build info, config-changed + log listener hooks.

Tests (`Source/iOS/App/DolphiniOSTests/`):
- `WebSocketFrameTests.swift`, `SettingsSnapshotsTests.swift`, `DebugEventBusTests.swift`.

Mac (`tools/mcp/`):
- `pyproject.toml`, `README.md`
- `icube_debug/__init__.py`, `device.py` (HTTP client), `events.py` (WS client), `imagediff.py`, `oracle.py`, `config.py`, `scenario.py`, `server.py` (FastMCP tools)
- `tests/` — `test_device.py`, `test_events.py`, `test_imagediff.py`, `test_oracle.py`, `test_scenario.py`, `test_server.py`, `fixtures/`

Repo:
- `docs/dev/debug-api.md` — new.
- `.github/workflows/build.yml` — `paths-ignore`.
- `Source/iOS/App/Makefile` — `mcp-install`, `mcp-test`, `mcp-smoke`.

---

### Task 1: Raw responses in NativeWebServer

**Files:**
- Modify: `Source/iOS/App/Common/Swift/Debug/NativeWebServer.swift`

**Interfaces:**
- Produces: `struct RawResponse { let status: Int; let contentType: String; let body: Data }`, `func addRawHandler(forMethod: String, path: String, handler: @escaping (HTTPRequest, Data?) -> RawResponse)`. `HTTPRequest` becomes non-private (`struct HTTPRequest` at file scope already; make it `internal`).

- [ ] **Step 1: Add the types and registration**

In `NativeWebServer.swift`, next to `CustomRoute`:

```swift
struct RawResponse {
  let status: Int
  let contentType: String
  let body: Data
  static func json(_ obj: [String: Any], status: Int = 200) -> RawResponse {
    let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
    return RawResponse(status: status, contentType: "application/json", body: data)
  }
  static func error(_ message: String, status: Int) -> RawResponse {
    json(["ok": false, "error": message], status: status)
  }
}

typealias RawHandlerBlock = (_ request: HTTPRequest, _ body: Data?) -> RawResponse

private struct RawRoute {
  let method: String
  let path: String
  let handler: RawHandlerBlock
}
private var rawRoutes: [RawRoute] = []

func addRawHandler(forMethod method: String, path: String,
                   handler: @escaping RawHandlerBlock) {
  lock.lock(); defer { lock.unlock() }
  rawRoutes.append(RawRoute(method: method, path: path, handler: handler))
}
```

- [ ] **Step 2: Dispatch raw routes before JSON routes**

At the top of `routeRequest(on:request:body:)`:

```swift
lock.lock()
let raws = rawRoutes
lock.unlock()
if let raw = raws.first(where: { $0.method == request.method && $0.path == request.path }) {
  let r = raw.handler(request, body.isEmpty ? nil : body)
  sendDataResponse(on: connection, status: r.status, statusText: Self.statusText(r.status),
                   contentType: r.contentType, body: r.body)
  return
}
```

and add:

```swift
static func statusText(_ code: Int) -> String {
  switch code {
  case 200: return "OK"; case 400: return "Bad Request"; case 404: return "Not Found"
  case 409: return "Conflict"; case 500: return "Internal Server Error"
  case 504: return "Gateway Timeout"; default: return "Status \(code)"
  }
}
```

Also make JSON handlers able to signal a status: in the existing JSON path, if `result["ok"] as? Bool == false`, use status `(result["status"] as? Int) ?? 400` and strip the `status` key before encoding.

- [ ] **Step 3: Build**

Run: `tuist generate --no-open && xcodebuild build -workspace iCube.xcworkspace -scheme "iCube (NJB)" -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO 2>&1 | xcbeautify | tail -5`
Expected: `Build Succeeded`

- [ ] **Step 4: Commit**

```bash
git add Source/iOS/App/Common/Swift/Debug/NativeWebServer.swift
git commit -m "debug: raw (non-JSON) responses and error statuses in NativeWebServer"
```

---

### Task 2: WebSocket frame codec and handshake

**Files:**
- Create: `Source/iOS/App/Common/Swift/Debug/WebSocketFrame.swift`
- Test: `Source/iOS/App/DolphiniOSTests/WebSocketFrameTests.swift`

**Interfaces:**
- Produces: `enum WebSocketOpcode: UInt8 { case text = 0x1, binary = 0x2, close = 0x8, ping = 0x9, pong = 0xA }`, `struct WebSocketFrame { let fin: Bool; let opcode: WebSocketOpcode; let payload: Data; func encode() -> Data; static func decode(_ data: Data) -> (frame: WebSocketFrame, consumed: Int)? }`, `enum WebSocketHandshake { static func acceptKey(for clientKey: String) -> String; static func response(for clientKey: String) -> Data }`.

- [ ] **Step 1: Write the failing tests**

```swift
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
```

- [ ] **Step 2: Run to verify failure**

Run the Xcode test invocation with `-only-testing:iCubeTests/WebSocketFrameTests`.
Expected: compile error, `WebSocketFrame` undefined.

- [ ] **Step 3: Implement**

```swift
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
```

- [ ] **Step 4: Run tests**

Expected: 5 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Source/iOS/App/Common/Swift/Debug/WebSocketFrame.swift Source/iOS/App/DolphiniOSTests/WebSocketFrameTests.swift
git commit -m "debug: RFC 6455 frame codec and handshake with unit tests"
```

---

### Task 3: WebSocket upgrade path in the server

**Files:**
- Create: `Source/iOS/App/Common/Swift/Debug/WebSocketConnection.swift`
- Modify: `Source/iOS/App/Common/Swift/Debug/NativeWebServer.swift`

**Interfaces:**
- Consumes: `WebSocketFrame`, `WebSocketHandshake` (Task 2); `HTTPRequest.headers` (lower-cased keys, existing).
- Produces: `final class WebSocketConnection { func send(text: String); var onClose: (() -> Void)?; func close() }`, `NativeWebServer.webSocketHandler: ((_ path: String, _ socket: WebSocketConnection) -> Bool)?` — return `false` to reject with 404.

- [ ] **Step 1: WebSocketConnection**

```swift
import Foundation
import Network

final class WebSocketConnection: @unchecked Sendable {
  private let connection: NWConnection
  private let queue: DispatchQueue
  private var buffer = Data()
  private var closed = false
  var onClose: (() -> Void)?

  init(connection: NWConnection, queue: DispatchQueue) {
    self.connection = connection; self.queue = queue
  }

  func start(initial: Data) {
    buffer = initial
    drain()
    receive()
  }

  func send(text: String) {
    guard !closed else { return }
    let frame = WebSocketFrame(fin: true, opcode: .text, payload: Data(text.utf8)).encode()
    connection.send(content: frame, completion: .contentProcessed { [weak self] err in
      if err != nil { self?.close() }
    })
  }

  func close() {
    guard !closed else { return }
    closed = true
    let frame = WebSocketFrame(fin: true, opcode: .close, payload: Data()).encode()
    connection.send(content: frame, completion: .contentProcessed { [weak self] _ in
      self?.connection.cancel()
    })
    onClose?()
  }

  private func receive() {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
      guard let self else { return }
      if let data { self.buffer.append(data); self.drain() }
      if error != nil || isComplete { self.close(); return }
      if !self.closed { self.receive() }
    }
  }

  /// Consume every complete frame in the buffer. Text frames from the client are ignored
  /// (the bus is one-way); ping → pong; close → close.
  private func drain() {
    while let (frame, used) = WebSocketFrame.decode(buffer) {
      buffer.removeFirst(used)
      switch frame.opcode {
      case .ping:
        let pong = WebSocketFrame(fin: true, opcode: .pong, payload: frame.payload).encode()
        connection.send(content: pong, completion: .contentProcessed { _ in })
      case .close: close(); return
      default: break
      }
    }
  }
}
```

- [ ] **Step 2: Upgrade in NativeWebServer**

Add the property `var webSocketHandler: ((String, WebSocketConnection) -> Bool)?` and, in `receiveHTTPRequest` right after `HTTPRequest.parse` succeeds and before the body handling:

```swift
if request.headers["upgrade"]?.lowercased() == "websocket",
   let key = request.headers["sec-websocket-key"] {
  guard let handler = self.webSocketHandler else {
    self.sendResponse(on: connection, status: 404, statusText: "Not Found", body: "Not Found"); return
  }
  let socket = WebSocketConnection(connection: connection, queue: self.queue)
  guard handler(request.path, socket) else {
    self.sendResponse(on: connection, status: 404, statusText: "Not Found", body: "Not Found"); return
  }
  connection.send(content: WebSocketHandshake.response(for: key), completion: .contentProcessed { _ in
    socket.start(initial: Data(bodyStart))
  })
  return
}
```

Ensure the `Connection: close` path in `sendDataResponse` is not applied to upgraded sockets (the upgrade returns before it), and that `stop()` cancels upgraded connections too (they are still in `activeConnections`).

- [ ] **Step 3: Build**

Same build command as Task 1. Expected: `Build Succeeded`.

- [ ] **Step 4: Manual check on the simulator**

Run the app in the simulator, then on the Mac:

```bash
python3 -c "import websockets,asyncio
async def m():
    async with websockets.connect('ws://127.0.0.1:8723/ws/events') as ws: print('connected')
asyncio.run(m())"
```

Expected: `connected` (the handler in Task 5 will make `/ws/events` accept; until then expect a 404 — that is fine for this task, the point is the upgrade code compiles and runs without crashing).

- [ ] **Step 5: Commit**

```bash
git add Source/iOS/App/Common/Swift/Debug/WebSocketConnection.swift Source/iOS/App/Common/Swift/Debug/NativeWebServer.swift
git commit -m "debug: WebSocket upgrade path in NativeWebServer"
```

---

### Task 4: DOLDebugBridge (core access)

**Files:**
- Create: `Source/iOS/App/Common/Bridging/DOLDebugBridge.h`, `DOLDebugBridge.mm`
- Modify: `Source/iOS/App/Common/Swift/BridgingHeader.h` (add `#import "DOLDebugBridge.h"`)

**Interfaces:**
- Produces (all class methods, thread-safe unless noted):
  - `+ (NSString*)coreState;` → `"uninitialized" | "starting" | "running" | "paused" | "stopping"`
  - `+ (BOOL)pause; + (BOOL)resume;`
  - `+ (NSInteger)frameAdvance:(NSInteger)n timeoutSeconds:(double)t;` → frames advanced (< n on timeout)
  - `+ (uint64_t)frameCount;`
  - `+ (nullable NSData*)screenshotPNGWithTimeout:(double)t;`
  - `+ (BOOL)loadStateSlot:(NSInteger)slot; + (BOOL)loadStatePath:(NSString*)p; + (BOOL)saveStateSlot:(NSInteger)slot;`
  - `+ (NSDictionary*)renderState; + (NSDictionary*)buildInfo; + (NSArray<NSString*>*)logTail:(NSInteger)n;`
  - `+ (void)setConfigChangedHandler:(void (^)(void))h; + (void)setLogHandler:(void (^)(NSString* level, NSString* msg))h; + (void)setCoreStateHandler:(void (^)(NSString* state))h;`

- [ ] **Step 1: Header**

```objc
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface DOLDebugBridge : NSObject
+ (NSString*)coreState;
+ (BOOL)pause;
+ (BOOL)resume;
+ (NSInteger)frameAdvance:(NSInteger)n timeoutSeconds:(double)timeout;
+ (uint64_t)frameCount;
+ (nullable NSData*)screenshotPNGWithTimeout:(double)timeout;
+ (BOOL)loadStateSlot:(NSInteger)slot;
+ (BOOL)loadStatePath:(NSString*)path;
+ (BOOL)saveStateSlot:(NSInteger)slot;
+ (NSDictionary<NSString*, id>*)renderState;
+ (NSDictionary<NSString*, id>*)buildInfo;
+ (NSArray<NSString*>*)logTail:(NSInteger)count;
+ (void)setConfigChangedHandler:(nullable void (^)(void))handler;
+ (void)setLogHandler:(nullable void (^)(NSString* level, NSString* message))handler;
+ (void)setCoreStateHandler:(nullable void (^)(NSString* state))handler;
@end
NS_ASSUME_NONNULL_END
```

- [ ] **Step 2: Implementation**

```objc
#import "DOLDebugBridge.h"
#import <mutex>
#import <deque>
#import "Common/Config/Config.h"
#import "Common/FileUtil.h"
#import "Common/Logging/LogManager.h"
#import "Core/Config/GraphicsSettings.h"
#import "Core/Config/MainSettings.h"
#import "Core/Core.h"
#import "Core/Movie.h"
#import "Core/State.h"
#import "Core/System.h"
#import "VideoCommon/VideoConfig.h"
#import "Common/scmrev.h"

static NSString* StateName(Core::State s) {
  switch (s) {
    case Core::State::Uninitialized: return @"uninitialized";
    case Core::State::Starting: return @"starting";
    case Core::State::Running: return @"running";
    case Core::State::Paused: return @"paused";
    case Core::State::Stopping: return @"stopping";
  }
  return @"unknown";
}

// Log ring + listener (LOG_WINDOW_LISTENER slot is unused on iOS).
namespace {
std::mutex g_log_mutex;
std::deque<std::string> g_log_ring;
void (^g_log_handler)(NSString*, NSString*) = nil;
class RingListener : public Common::Log::LogListener {
 public:
  void Log(Common::Log::LogLevel level, const char* msg) override {
    std::lock_guard<std::mutex> lk(g_log_mutex);
    g_log_ring.emplace_back(msg);
    if (g_log_ring.size() > 2000) g_log_ring.pop_front();
    if (g_log_handler && level <= Common::Log::LogLevel::LWARNING)
      g_log_handler(level == Common::Log::LogLevel::LERROR ? @"ERROR" : @"WARN", @(msg));
  }
};
std::once_flag g_log_once;
void (^g_state_handler)(NSString*) = nil;
int g_state_cb_handle = -1;
Config::ConfigChangedCallbackID g_config_cb;
}

@implementation DOLDebugBridge

+ (NSString*)coreState { return StateName(Core::GetState(Core::System::GetInstance())); }
+ (BOOL)pause {
  auto& sys = Core::System::GetInstance();
  if (!Core::IsRunning(sys)) return NO;
  Core::SetState(sys, Core::State::Paused); return YES;
}
+ (BOOL)resume {
  auto& sys = Core::System::GetInstance();
  if (!Core::IsRunning(sys)) return NO;
  Core::SetState(sys, Core::State::Running); return YES;
}

+ (NSInteger)frameAdvance:(NSInteger)n timeoutSeconds:(double)timeout {
  auto& sys = Core::System::GetInstance();
  NSInteger done = 0;
  for (NSInteger i = 0; i < n; i++) {
    if (Core::GetState(sys) != Core::State::Paused) break;
    const uint64_t before = sys.GetMovie().GetCurrentFrame();
    Core::DoFrameStep(sys);
    const NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!(Core::GetState(sys) == Core::State::Paused && sys.GetMovie().GetCurrentFrame() > before)) {
      if ([deadline timeIntervalSinceNow] < 0) return done;
      [NSThread sleepForTimeInterval:0.002];
    }
    done++;
  }
  return done;
}

+ (uint64_t)frameCount { return Core::System::GetInstance().GetMovie().GetCurrentFrame(); }

+ (nullable NSData*)screenshotPNGWithTimeout:(double)timeout {
  auto& sys = Core::System::GetInstance();
  if (!Core::IsRunning(sys)) return nil;
  const std::string name = "debugapi-" + std::to_string((long long)([[NSDate date] timeIntervalSince1970] * 1000));
  Core::SaveScreenShot(name);
  // SaveScreenShot writes <Screenshots>/<GameID>/<name>.png asynchronously.
  const std::string gameId = SConfig::GetInstance().GetGameID();
  std::string path = File::GetUserPath(D_SCREENSHOTS_IDX) + gameId + DIR_SEP_CHR + name + ".png";
  NSString* ns = @(path.c_str());
  NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
  unsigned long long lastSize = 0;
  while ([deadline timeIntervalSinceNow] > 0) {
    NSDictionary* attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:ns error:nil];
    unsigned long long size = [attrs fileSize];
    if (size > 0 && size == lastSize) {
      NSData* data = [NSData dataWithContentsOfFile:ns];
      [[NSFileManager defaultManager] removeItemAtPath:ns error:nil];
      return data;
    }
    lastSize = size;
    [NSThread sleepForTimeInterval:0.05];
  }
  return nil;
}

+ (BOOL)loadStateSlot:(NSInteger)slot {
  auto& sys = Core::System::GetInstance();
  if (!Core::IsRunning(sys)) return NO;
  State::Load(sys, (int)slot); return YES;
}
+ (BOOL)loadStatePath:(NSString*)path {
  auto& sys = Core::System::GetInstance();
  if (!Core::IsRunning(sys) || ![[NSFileManager defaultManager] fileExistsAtPath:path]) return NO;
  State::LoadAs(sys, path.UTF8String); return YES;
}
+ (BOOL)saveStateSlot:(NSInteger)slot {
  auto& sys = Core::System::GetInstance();
  if (!Core::IsRunning(sys)) return NO;
  State::Save(sys, (int)slot, /*wait=*/true); return YES;
}

+ (NSDictionary<NSString*, id>*)renderState {
  const auto& c = g_ActiveConfig;
  return @{
    @"backend": @(Config::Get(Config::MAIN_GFX_BACKEND).c_str()),
    @"internal_resolution": @(c.iEFBScale),
    @"cpu_core": @((int)Config::Get(Config::MAIN_CPU_CORE)),
    @"dual_core": @(Config::Get(Config::MAIN_CPU_THREAD)),
    @"vertex_loader_type": @((int)c.vertex_loader_type),
    @"fast_math": @(Config::Get(Config::GFX_HACK_FAST_MATH)),
    @"neon_texture_decode": @(c.bNEONTextureDecode),
    @"immediate_xfb": @(c.bImmediateXFB),
    @"skip_efb_copy_to_ram": @(c.bSkipEFBCopyToRam),
    @"vi_skip_mode": @((int)Config::Get(Config::GFX_HACK_VI_SKIP_MODE)),
    @"overclock_enable": @(Config::Get(Config::MAIN_OVERCLOCK_ENABLE)),
    @"overclock": @(Config::Get(Config::MAIN_OVERCLOCK)),
    @"vi_overclock": @(Config::Get(Config::MAIN_VI_OVERCLOCK)),
    @"core_state": [self coreState],
  };
}

+ (NSDictionary<NSString*, id>*)buildInfo {
  NSBundle* b = [NSBundle mainBundle];
  return @{
    @"scm_rev": @(Common::GetScmRevStr().c_str()),
    @"scm_branch": @(Common::GetScmBranchStr().c_str()),
    @"app_version": b.infoDictionary[@"CFBundleShortVersionString"] ?: @"",
    @"app_build": b.infoDictionary[@"CFBundleVersion"] ?: @"",
#if DEBUG
    @"configuration": @"debug",
#else
    @"configuration": @"release",
#endif
  };
}

+ (NSArray<NSString*>*)logTail:(NSInteger)count {
  std::lock_guard<std::mutex> lk(g_log_mutex);
  NSMutableArray* out = [NSMutableArray array];
  size_t start = g_log_ring.size() > (size_t)count ? g_log_ring.size() - count : 0;
  for (size_t i = start; i < g_log_ring.size(); i++) [out addObject:@(g_log_ring[i].c_str())];
  return out;
}

+ (void)setConfigChangedHandler:(void (^)(void))handler {
  static bool registered = false;
  static void (^stored)(void) = nil;
  stored = handler;
  if (!registered) {
    g_config_cb = Config::AddConfigChangedCallback([] { if (stored) stored(); });
    registered = true;
  }
}
+ (void)setLogHandler:(void (^)(NSString*, NSString*))handler {
  std::call_once(g_log_once, [] {
    auto* mgr = Common::Log::LogManager::GetInstance();
    mgr->RegisterListener(Common::Log::LogListener::LOG_WINDOW_LISTENER, std::make_unique<RingListener>());
    mgr->EnableListener(Common::Log::LogListener::LOG_WINDOW_LISTENER, true);
  });
  std::lock_guard<std::mutex> lk(g_log_mutex);
  g_log_handler = handler;
}
+ (void)setCoreStateHandler:(void (^)(NSString*))handler {
  g_state_handler = handler;
  if (g_state_cb_handle < 0)
    g_state_cb_handle = Core::AddOnStateChangedCallback([](Core::State s) { if (g_state_handler) g_state_handler(StateName(s)); });
}
@end
```

Note for the implementer: `State::Load(sys, slot)` / `State::Save(sys, slot, wait)` are the slot APIs in `Core/State.h`; `SConfig::GetInstance().GetGameID()` needs `#import "Core/ConfigManager.h"`. If `LogManager` on iOS already registers a `LOG_WINDOW_LISTENER`, use `CONSOLE_LISTENER` instead — check `grep -rn "RegisterListener" Source/iOS`.

- [ ] **Step 3: Build**

Same build command. Expected: `Build Succeeded`. Fix include paths per the errors — all headers are under `Source/Core`, already in `USER_HEADER_SEARCH_PATHS`.

- [ ] **Step 4: Commit**

```bash
git add Source/iOS/App/Common/Bridging/DOLDebugBridge.h Source/iOS/App/Common/Bridging/DOLDebugBridge.mm Source/iOS/App/Common/Swift/BridgingHeader.h
git commit -m "debug: DOLDebugBridge — core state, frame step, screenshot bytes, render state, log tail"
```

---

### Task 5: DebugEventBus and /ws/events

**Files:**
- Create: `Source/iOS/App/Common/Swift/Debug/DebugEventBus.swift`
- Test: `Source/iOS/App/DolphiniOSTests/DebugEventBusTests.swift`
- Modify: `Source/iOS/App/Common/Swift/Debug/DebugServerManager.swift`

**Interfaces:**
- Consumes: `WebSocketConnection` (Task 3), `DOLDebugBridge` handlers, `DOLSettingsKeyBridge.snapshotAll()`, `DOLPerfBridge.snapshot()`.
- Produces: `final class DebugEventBus { static let shared; func publish(_ kind: String, _ fields: [String: Any]); func attach(_ socket: WebSocketConnection); func startProducers() }`, `static func settingsDiff(old: [String: Any], new: [String: Any]) -> [(key: String, old: Any?, new: Any?)]`.

- [ ] **Step 1: Failing tests**

```swift
import XCTest
@testable import iCube

final class DebugEventBusTests: XCTestCase {
  func testSettingsDiffFindsChangedAndAddedKeys() {
    let old: [String: Any] = ["A": ["value": 1], "B": ["value": "x"]]
    let new: [String: Any] = ["A": ["value": 2], "B": ["value": "x"], "C": ["value": true]]
    let d = DebugEventBus.settingsDiff(old: old, new: new).sorted { $0.key < $1.key }
    XCTAssertEqual(d.map(\.key), ["A", "C"])
    XCTAssertEqual(d[0].new as? Int, 2)
    XCTAssertNil(d[1].old)
  }
  func testEventEncodingHasTimestampAndKind() throws {
    let json = DebugEventBus.encode(kind: "core.state", fields: ["state": "paused"])
    let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    XCTAssertEqual(obj["kind"] as? String, "core.state")
    XCTAssertEqual(obj["state"] as? String, "paused")
    XCTAssertNotNil(obj["t"] as? Double)
  }
}
```

- [ ] **Step 2: Run — expect compile failure.**

- [ ] **Step 3: Implement**

```swift
import Foundation

final class DebugEventBus: @unchecked Sendable {
  static let shared = DebugEventBus()
  private let lock = NSLock()
  private var sockets: [ObjectIdentifier: WebSocketConnection] = [:]
  private var lastSettings: [String: Any] = [:]
  private var perfTimer: DispatchSourceTimer?
  private var producersStarted = false

  static func encode(kind: String, fields: [String: Any]) -> String {
    var obj = fields
    obj["kind"] = kind
    obj["t"] = Date().timeIntervalSince1970 * 1000
    let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
    return String(decoding: data, as: UTF8.self)
  }

  static func settingsDiff(old: [String: Any], new: [String: Any]) -> [(key: String, old: Any?, new: Any?)] {
    func value(_ d: [String: Any], _ k: String) -> Any? { (d[k] as? [String: Any])?["value"] }
    var out: [(String, Any?, Any?)] = []
    for k in Set(old.keys).union(new.keys) {
      let a = value(old, k), b = value(new, k)
      let same = (a == nil && b == nil) || (a as? NSObject) == (b as? NSObject)
      if !same { out.append((k, a, b)) }
    }
    return out.map { (key: $0.0, old: $0.1, new: $0.2) }
  }

  func publish(_ kind: String, _ fields: [String: Any]) {
    let text = Self.encode(kind: kind, fields: fields)
    lock.lock(); let targets = Array(sockets.values); lock.unlock()
    targets.forEach { $0.send(text: text) }
  }

  func attach(_ socket: WebSocketConnection) {
    lock.lock(); sockets[ObjectIdentifier(socket)] = socket; lock.unlock()
    socket.onClose = { [weak self, weak socket] in
      guard let self, let socket else { return }
      self.lock.lock(); self.sockets[ObjectIdentifier(socket)] = nil; self.lock.unlock()
    }
    publish("core.state", ["state": DOLDebugBridge.coreState()])
  }

  func startProducers() {
    guard !producersStarted else { return }
    producersStarted = true
    lastSettings = DOLSettingsKeyBridge.snapshotAll() as? [String: Any] ?? [:]
    DOLDebugBridge.setConfigChangedHandler { [weak self] in
      guard let self else { return }
      let now = DOLSettingsKeyBridge.snapshotAll() as? [String: Any] ?? [:]
      let diff = Self.settingsDiff(old: self.lastSettings, new: now)
      self.lastSettings = now
      for d in diff {
        self.publish("settings.changed", ["key": d.key, "old": d.old ?? NSNull(), "new": d.new ?? NSNull()])
      }
    }
    DOLDebugBridge.setLogHandler { [weak self] level, msg in
      self?.publish("log.line", ["level": level, "msg": msg])
    }
    DOLDebugBridge.setCoreStateHandler { [weak self] state in
      self?.publish("core.state", ["state": state])
    }
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
    timer.schedule(deadline: .now() + 1, repeating: 1)
    timer.setEventHandler { [weak self] in
      guard let self, DOLDebugBridge.coreState() == "running" else { return }
      let snap = DOLPerfBridge.snapshot() as? [String: Any] ?? [:]
      self.publish("perf.sample", ["fps": snap["fps"] ?? 0, "vps": snap["vps"] ?? 0, "frame_ms": snap["frameTimeMs"] ?? 0])
    }
    timer.resume()
    perfTimer = timer
  }
}
```

Check the actual keys `DOLPerfBridge.snapshot()` returns (`grep -n "@\"" Source/iOS/App/Common/Bridging/DOLPerfBridge.mm`) and use those names.

- [ ] **Step 4: Wire in DebugServerManager.start()**

Before `routes.registerRoutes(on: server)`:

```swift
server.webSocketHandler = { path, socket in
  guard path == "/ws/events" else { return false }
  DebugEventBus.shared.attach(socket)
  return true
}
DebugEventBus.shared.startProducers()
```

- [ ] **Step 5: Run tests** — `-only-testing:iCubeTests/DebugEventBusTests`. Expected: 2 PASS.

- [ ] **Step 6: Commit**

```bash
git add Source/iOS/App/Common/Swift/Debug/DebugEventBus.swift Source/iOS/App/DolphiniOSTests/DebugEventBusTests.swift Source/iOS/App/Common/Swift/Debug/DebugServerManager.swift
git commit -m "debug: DebugEventBus with settings/perf/log/core-state producers on /ws/events"
```

---

### Task 6: Core-control and info routes

**Files:**
- Modify: `Source/iOS/App/Common/Swift/Debug/DebugAPIRoutes.swift`

**Interfaces:**
- Consumes: `DOLDebugBridge` (Task 4), `RawResponse`/`addRawHandler` (Task 1), `TVEmulationBridge.currentGameID()`.
- Produces routes: `GET /api/health`, `POST /api/debug/pause|resume|frame-advance|savestate|loadstate`, `GET /api/debug/frame-count|screenshot|build-info|render-state`, `GET /api/logs`.

- [ ] **Step 1: Add the routes inside `registerRoutes`**

```swift
func jsonBody(_ body: Data?) -> [String: Any] {
  guard let body, let j = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return [:] }
  return j
}

server.addCustomHandler(forMethod: "GET", path: "/api/health") { _, _, _, _ in
  let perf = DOLPerfBridge.snapshot() as? [String: Any] ?? [:]
  let build = DOLDebugBridge.buildInfo()
  return ["ok": true, "data": [
    "build_sha": build["scm_rev"] ?? "", "config": build["configuration"] ?? "",
    "game_id": TVEmulationBridge.currentGameID() ?? "", "core_state": DOLDebugBridge.coreState(),
    "fps": perf["fps"] ?? 0, "vps": perf["vps"] ?? 0,
  ] as [String: Any]]
}
server.addCustomHandler(forMethod: "POST", path: "/api/debug/pause") { _, _, _, _ in
  DOLDebugBridge.pause() ? ["ok": true, "data": ["state": DOLDebugBridge.coreState()]]
                         : ["ok": false, "status": 409, "error": "core not running"]
}
server.addCustomHandler(forMethod: "POST", path: "/api/debug/resume") { _, _, _, _ in
  DOLDebugBridge.resume() ? ["ok": true, "data": ["state": DOLDebugBridge.coreState()]]
                          : ["ok": false, "status": 409, "error": "core not running"]
}
server.addCustomHandler(forMethod: "POST", path: "/api/debug/frame-advance") { _, _, _, body in
  let n = (jsonBody(body)["n"] as? NSNumber)?.intValue ?? 1
  guard DOLDebugBridge.coreState() == "paused" else {
    return ["ok": false, "status": 409, "error": "core must be paused (state=\(DOLDebugBridge.coreState()))"]
  }
  let done = DOLDebugBridge.frameAdvance(n, timeoutSeconds: 5)
  if done < n { return ["ok": false, "status": 504, "error": "timed out after \(done)/\(n) frames"] }
  return ["ok": true, "data": ["frames_advanced": done, "frame_count": DOLDebugBridge.frameCount()] as [String: Any]]
}
server.addCustomHandler(forMethod: "GET", path: "/api/debug/frame-count") { _, _, _, _ in
  ["ok": true, "data": ["frame_count": DOLDebugBridge.frameCount()]]
}
server.addCustomHandler(forMethod: "POST", path: "/api/debug/savestate") { _, _, _, body in
  let slot = (jsonBody(body)["slot"] as? NSNumber)?.intValue ?? 1
  return DOLDebugBridge.saveStateSlot(slot) ? ["ok": true, "data": ["slot": slot]]
                                            : ["ok": false, "status": 409, "error": "core not running"]
}
server.addCustomHandler(forMethod: "POST", path: "/api/debug/loadstate") { _, _, _, body in
  let j = jsonBody(body)
  let ok: Bool
  if let p = j["path"] as? String { ok = DOLDebugBridge.loadStatePath(p) }
  else { ok = DOLDebugBridge.loadStateSlot((j["slot"] as? NSNumber)?.intValue ?? 1) }
  return ok ? ["ok": true, "data": ["state": DOLDebugBridge.coreState()]]
            : ["ok": false, "status": 409, "error": "core not running or state missing"]
}
server.addRawHandler(forMethod: "GET", path: "/api/debug/screenshot") { _, _ in
  guard let png = DOLDebugBridge.screenshotPNG(withTimeout: 3) else {
    return .error("screenshot not produced within 3s (core running?)", status: 504)
  }
  return RawResponse(status: 200, contentType: "image/png", body: png)
}
server.addCustomHandler(forMethod: "GET", path: "/api/debug/build-info") { _, _, _, _ in
  ["ok": true, "data": DOLDebugBridge.buildInfo()]
}
server.addCustomHandler(forMethod: "GET", path: "/api/debug/render-state") { _, _, _, _ in
  ["ok": true, "data": DOLDebugBridge.renderState()]
}
server.addCustomHandler(forMethod: "GET", path: "/api/logs") { _, _, query, _ in
  let n = Int(query?["tail"] ?? "") ?? 200
  return ["ok": true, "data": ["lines": DOLDebugBridge.logTail(n)]]
}
```

Note: the JSON path in Task 1 turns `"status": 409` into the HTTP status and strips the key.

- [ ] **Step 2: Build** — expected `Build Succeeded`.

- [ ] **Step 3: Smoke on a device or simulator**

```bash
curl -s localhost:8723/api/health; echo
curl -s -X POST localhost:8723/api/debug/pause; echo
curl -s -X POST localhost:8723/api/debug/frame-advance -d '{"n":5}'; echo
curl -s localhost:8723/api/debug/screenshot -o /tmp/s.png && file /tmp/s.png
```

Expected: JSON envelopes; `frames_advanced: 5`; `PNG image data`.

- [ ] **Step 4: Commit**

```bash
git add Source/iOS/App/Common/Swift/Debug/DebugAPIRoutes.swift
git commit -m "debug: health, pause/resume, frame-advance, states, screenshot, render-state, logs routes"
```

---

### Task 7: Settings snapshots and layer routes

**Files:**
- Create: `Source/iOS/App/Common/Swift/Debug/SettingsSnapshots.swift`
- Test: `Source/iOS/App/DolphiniOSTests/SettingsSnapshotsTests.swift`
- Modify: `Source/iOS/App/Common/Swift/Debug/DebugAPIRoutes.swift`
- Modify: `Source/iOS/App/Common/Bridging/DOLSettingsKeyBridge.h/.mm` — add `+ (NSDictionary*)snapshotAllLayers;` (per key: `{value, layer, layers: {Base: v, PerGame: v, CurrentRun: v}}`) and `+ (BOOL)resetKeys:(NSArray<NSString*>*)keys;` (empty = all known keys; deletes from `Config::LayerType::Base`, `LocalGame`, `CurrentRun` via `Config::DeleteKey`).

**Interfaces:**
- Produces: `final class SettingsSnapshots { init(directory: URL); func save(name: String, snapshot: [String: Any], gameId: String) throws; func list() -> [[String: Any]]; func load(name: String) -> [String: Any]?; static func diff(_ a: [String: Any], _ b: [String: Any]) -> [[String: Any]] }` — diff rows `{key, a, b}`.

- [ ] **Step 1: Failing tests**

```swift
import XCTest
@testable import iCube

final class SettingsSnapshotsTests: XCTestCase {
  func makeStore() -> SettingsSnapshots {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    return SettingsSnapshots(directory: dir)
  }
  func testSaveListLoadRoundTrip() throws {
    let s = makeStore()
    try s.save(name: "before", snapshot: ["A": ["value": 1]], gameId: "SMNE01")
    XCTAssertEqual(s.list().count, 1)
    XCTAssertEqual(s.list()[0]["name"] as? String, "before")
    XCTAssertEqual((s.load(name: "before")?["A"] as? [String: Any])?["value"] as? Int, 1)
  }
  func testDiffReportsOnlyChangedKeys() {
    let d = SettingsSnapshots.diff(["A": ["value": 1], "B": ["value": 2]], ["A": ["value": 1], "B": ["value": 3]])
    XCTAssertEqual(d.count, 1)
    XCTAssertEqual(d[0]["key"] as? String, "B")
    XCTAssertEqual(d[0]["b"] as? Int, 3)
  }
  func testNameIsSanitised() throws {
    let s = makeStore()
    try s.save(name: "../evil", snapshot: [:], gameId: "")
    XCTAssertEqual(s.list()[0]["name"] as? String, "evil")
  }
}
```

- [ ] **Step 2: Run — compile failure expected.**

- [ ] **Step 3: Implement**

```swift
import Foundation

final class SettingsSnapshots {
  private let directory: URL
  init(directory: URL) {
    self.directory = directory
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }
  static var defaultDirectory: URL {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("DebugSnapshots")
  }
  static func sanitise(_ name: String) -> String {
    let allowed = name.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    return allowed.isEmpty ? "snapshot" : allowed
  }
  func save(name: String, snapshot: [String: Any], gameId: String) throws {
    let doc: [String: Any] = ["name": Self.sanitise(name), "taken_at": ISO8601DateFormatter().string(from: Date()),
                              "game_id": gameId, "settings": snapshot]
    let data = try JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys, .prettyPrinted])
    try data.write(to: directory.appendingPathComponent(Self.sanitise(name) + ".json"), options: .atomic)
  }
  func list() -> [[String: Any]] {
    let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    return files.filter { $0.pathExtension == "json" }.compactMap { url in
      guard let d = try? Data(contentsOf: url), let doc = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
      return ["name": doc["name"] ?? "", "taken_at": doc["taken_at"] ?? "", "game_id": doc["game_id"] ?? ""]
    }.sorted { ($0["taken_at"] as? String ?? "") < ($1["taken_at"] as? String ?? "") }
  }
  func load(name: String) -> [String: Any]? {
    let url = directory.appendingPathComponent(Self.sanitise(name) + ".json")
    guard let d = try? Data(contentsOf: url), let doc = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
    return doc["settings"] as? [String: Any]
  }
  static func diff(_ a: [String: Any], _ b: [String: Any]) -> [[String: Any]] {
    DebugEventBus.settingsDiff(old: a, new: b).map { ["key": $0.key, "a": $0.old ?? NSNull(), "b": $0.new ?? NSNull()] }
      .sorted { ($0["key"] as! String) < ($1["key"] as! String) }
  }
}
```

- [ ] **Step 4: Routes** (in `registerRoutes`; `let snapshots = SettingsSnapshots(directory: SettingsSnapshots.defaultDirectory)` as a property):

```swift
server.addCustomHandler(forMethod: "GET", path: "/api/settings/all") { _, _, _, _ in
  ["ok": true, "data": DOLSettingsKeyBridge.snapshotAllLayers()]
}
server.addCustomHandler(forMethod: "GET", path: "/api/settings/pergame") { _, _, _, _ in
  let all = DOLSettingsKeyBridge.snapshotAllLayers() as? [String: [String: Any]] ?? [:]
  let pergame = all.compactMapValues { ($0["layers"] as? [String: Any])?["PerGame"] }
  return ["ok": true, "data": pergame]
}
server.addCustomHandler(forMethod: "POST", path: "/api/settings/reset") { _, _, _, body in
  let keys = jsonBody(body)["keys"] as? [String] ?? []
  let ok = DispatchQueue.main.sync { DOLSettingsKeyBridge.resetKeys(keys) }
  return ok ? ["ok": true, "data": ["reset": keys.isEmpty ? "all" : keys] as [String: Any]]
            : ["ok": false, "status": 404, "error": "unknown key in list"]
}
server.addCustomHandler(forMethod: "GET", path: "/api/settings/snapshots") { [snapshots] _, _, _, _ in
  ["ok": true, "data": snapshots.list()]
}
server.addCustomHandler(forMethod: "POST", path: "/api/settings/snapshots") { [snapshots] _, _, _, body in
  guard let name = jsonBody(body)["name"] as? String else { return ["ok": false, "status": 400, "error": "missing name"] }
  do {
    try snapshots.save(name: name, snapshot: DOLSettingsKeyBridge.snapshotAllLayers() as? [String: Any] ?? [:],
                       gameId: TVEmulationBridge.currentGameID() ?? "")
    return ["ok": true, "data": ["name": SettingsSnapshots.sanitise(name)]]
  } catch { return ["ok": false, "status": 500, "error": "\(error)"] }
}
server.addCustomHandler(forMethod: "GET", pathRegex: "^/api/settings/snapshots/[^/]+/diff/[^/]+$") { [snapshots] _, path, _, _ in
  let parts = path.split(separator: "/").map(String.init)   // api settings snapshots A diff B
  guard let a = snapshots.load(name: parts[3]), let b = snapshots.load(name: parts[5]) else {
    return ["ok": false, "status": 404, "error": "snapshot not found"]
  }
  return ["ok": true, "data": SettingsSnapshots.diff(a, b)]
}
```

Register the regex route *before* the existing `POST /api/settings/.*` so it isn't shadowed; both are method-specific so order only matters within GET.

- [ ] **Step 5: Bridge additions** in `DOLSettingsKeyBridge.mm`: `snapshotAllLayers` iterates the same key table `snapshotAll` uses and, per key, reads `Config::GetLayer(Base/LocalGame/CurrentRun)->Get(...)` into `layers`, plus the resolved `value` and the winning `layer` name; `resetKeys:` validates every key with `isKnownKey`, then `Config::DeleteKey(layer, info)` for the three layers and `Config::Save()`.

- [ ] **Step 6: Run tests** (`SettingsSnapshotsTests`) — 3 PASS. Build the app.

- [ ] **Step 7: Commit**

```bash
git add Source/iOS/App/Common/Swift/Debug/SettingsSnapshots.swift Source/iOS/App/DolphiniOSTests/SettingsSnapshotsTests.swift Source/iOS/App/Common/Swift/Debug/DebugAPIRoutes.swift Source/iOS/App/Common/Bridging/DOLSettingsKeyBridge.h Source/iOS/App/Common/Bridging/DOLSettingsKeyBridge.mm
git commit -m "debug: settings snapshots, layer view, reset routes"
```

---

### Task 8: Docs, CI paths-ignore, Makefile targets

**Files:**
- Create: `docs/dev/debug-api.md`
- Modify: `.github/workflows/build.yml`, `Source/iOS/App/Makefile`

- [ ] **Step 1: `docs/dev/debug-api.md`** — a table per route group exactly mirroring the shapes implemented in Tasks 6–7, the event schema from Task 5, and the `iproxy 8723 8723` setup line. Copy the envelope rule and the status-code rules from the spec's *Errors* section.

- [ ] **Step 2: `build.yml`** — under `on.push` and `on.pull_request` add:

```yaml
    paths-ignore:
      - 'docs/**'
      - 'tools/mcp/**'
      - '**/*.md'
```

- [ ] **Step 3: Makefile** — append:

```make
# --- Debug MCP (tools/mcp) ---------------------------------------------------
mcp-install:
	cd "$(ROOT)/tools/mcp" && uv sync
mcp-test:
	cd "$(ROOT)/tools/mcp" && uv run pytest -q
# Needs a device on `iproxy 8723 8723` with a game booted.
mcp-smoke:
	cd "$(ROOT)/tools/mcp" && uv run python -m icube_debug.smoke
```

and the three names to `.PHONY` and `help`.

- [ ] **Step 4: Commit**

```bash
git add docs/dev/debug-api.md .github/workflows/build.yml Source/iOS/App/Makefile
git commit -m "docs(debug-api): route reference; ci: skip core builds for docs and tools/mcp"
```

---

### Task 9: Python project and device client

**Files:**
- Create: `tools/mcp/pyproject.toml`, `tools/mcp/icube_debug/__init__.py`, `tools/mcp/icube_debug/device.py`, `tools/mcp/tests/test_device.py`

**Interfaces:**
- Produces: `class DeviceError(Exception)`, `class Device: def __init__(self, base: str = "127.0.0.1:8723", timeout: float = 30) ; def get(self, path, **params) -> dict ; def post(self, path, body: dict | None = None) -> dict ; def get_bytes(self, path) -> bytes`. `get`/`post` return `data` from the envelope and raise `DeviceError(f"{status}: {error}")` on `ok: false` or non-2xx.

- [ ] **Step 1: pyproject**

```toml
[project]
name = "icube-debug"
version = "0.1.0"
requires-python = ">=3.12"
dependencies = ["fastmcp>=2.0", "httpx>=0.27", "websockets>=13", "pillow>=10", "scikit-image>=0.24", "numpy>=1.26"]

[project.optional-dependencies]
dev = ["pytest>=8", "respx>=0.21", "pytest-asyncio>=0.24"]

[project.scripts]
icube-debug-mcp = "icube_debug.server:main"

[tool.pytest.ini_options]
asyncio_mode = "auto"
```

- [ ] **Step 2: Failing tests**

```python
import httpx, pytest, respx
from icube_debug.device import Device, DeviceError

BASE = "http://127.0.0.1:8723"

@respx.mock
def test_get_unwraps_envelope():
    respx.get(f"{BASE}/api/health").mock(return_value=httpx.Response(200, json={"ok": True, "data": {"fps": 60}}))
    assert Device().get("/api/health") == {"fps": 60}

@respx.mock
def test_error_envelope_raises_with_status():
    respx.post(f"{BASE}/api/debug/frame-advance").mock(return_value=httpx.Response(409, json={"ok": False, "error": "core must be paused"}))
    with pytest.raises(DeviceError, match="409: core must be paused"):
        Device().post("/api/debug/frame-advance", {"n": 1})

@respx.mock
def test_get_bytes_returns_raw_body():
    respx.get(f"{BASE}/api/debug/screenshot").mock(return_value=httpx.Response(200, content=b"\x89PNG", headers={"content-type": "image/png"}))
    assert Device().get_bytes("/api/debug/screenshot") == b"\x89PNG"
```

- [ ] **Step 3: Run** — `uv sync --extra dev && uv run pytest tests/test_device.py -v`. Expected: ImportError.

- [ ] **Step 4: Implement `device.py`**

```python
from __future__ import annotations
import httpx

class DeviceError(Exception):
    pass

class Device:
    def __init__(self, base: str = "127.0.0.1:8723", timeout: float = 30):
        self.base = base if base.startswith("http") else f"http://{base}"
        self.client = httpx.Client(base_url=self.base, timeout=timeout)

    def _unwrap(self, r: httpx.Response) -> dict:
        try:
            body = r.json()
        except ValueError:
            raise DeviceError(f"{r.status_code}: non-JSON response") from None
        if r.status_code >= 400 or not body.get("ok", False):
            raise DeviceError(f"{r.status_code}: {body.get('error', 'unknown error')}")
        return body.get("data", {})

    def get(self, path: str, **params) -> dict:
        return self._unwrap(self.client.get(path, params=params or None))

    def post(self, path: str, body: dict | None = None) -> dict:
        return self._unwrap(self.client.post(path, json=body or {}))

    def get_bytes(self, path: str) -> bytes:
        r = self.client.get(path)
        if r.status_code >= 400:
            raise DeviceError(f"{r.status_code}: {r.text[:200]}")
        return r.content
```

- [ ] **Step 5: Run tests** — 3 PASS.

- [ ] **Step 6: Commit**

```bash
git add tools/mcp/pyproject.toml tools/mcp/icube_debug/__init__.py tools/mcp/icube_debug/device.py tools/mcp/tests/test_device.py
git commit -m "mcp: python project and device HTTP client"
```

---

### Task 10: Event stream client

**Files:**
- Create: `tools/mcp/icube_debug/events.py`, `tools/mcp/tests/test_events.py`

**Interfaces:**
- Produces: `async def collect_events(base: str, kinds: list[str] | None, seconds: float) -> list[dict]` — connects to `ws://{base}/ws/events`, returns parsed JSON events whose `kind` is in `kinds` (or all), stops after `seconds`.

- [ ] **Step 1: Failing test** (spins a local fake server with `websockets.serve`)

```python
import asyncio, json, pytest, websockets
from icube_debug.events import collect_events

async def fake(ws):
    for i in range(3):
        await ws.send(json.dumps({"t": i, "kind": "perf.sample" if i else "core.state"}))
        await asyncio.sleep(0.05)
    await asyncio.sleep(5)

async def test_collects_filtered_events_within_window():
    async with websockets.serve(fake, "127.0.0.1", 0) as srv:
        port = srv.sockets[0].getsockname()[1]
        events = await collect_events(f"127.0.0.1:{port}", ["perf.sample"], seconds=0.5)
    assert [e["kind"] for e in events] == ["perf.sample", "perf.sample"]
```

- [ ] **Step 2: Run** — ImportError.

- [ ] **Step 3: Implement**

```python
from __future__ import annotations
import asyncio, json
import websockets

async def collect_events(base: str, kinds: list[str] | None, seconds: float) -> list[dict]:
    url = f"ws://{base}/ws/events"
    out: list[dict] = []
    loop = asyncio.get_running_loop()
    deadline = loop.time() + seconds
    async with websockets.connect(url, open_timeout=5) as ws:
        while (remaining := deadline - loop.time()) > 0:
            try:
                raw = await asyncio.wait_for(ws.recv(), timeout=remaining)
            except asyncio.TimeoutError:
                break
            try:
                ev = json.loads(raw)
            except json.JSONDecodeError:
                continue
            if kinds is None or ev.get("kind") in kinds:
                out.append(ev)
    return out
```

- [ ] **Step 4: Run tests** — PASS.

- [ ] **Step 5: Commit**

```bash
git add tools/mcp/icube_debug/events.py tools/mcp/tests/test_events.py
git commit -m "mcp: bounded WebSocket event collector"
```

---

### Task 11: Image diff

**Files:**
- Create: `tools/mcp/icube_debug/imagediff.py`, `tools/mcp/tests/test_imagediff.py`

**Interfaces:**
- Produces: `def compare(a_png: bytes, b_png: bytes, tiles: int = 8) -> DiffResult` with `@dataclass DiffResult: score: float; tile_scores: list[list[float]]; diff_png: bytes; size: tuple[int,int]`. Both images are resized to the smaller common size, converted to grayscale for SSIM; `diff_png` is a heatmap (red intensity = 1 − tile score) over image A.

- [ ] **Step 1: Failing tests** (fixtures generated in-test with Pillow, no binary files)

```python
from io import BytesIO
from PIL import Image, ImageDraw
from icube_debug.imagediff import compare

def png(draw_fn, size=(256, 192)):
    im = Image.new("RGB", size, "white"); draw_fn(ImageDraw.Draw(im))
    b = BytesIO(); im.save(b, "PNG"); return b.getvalue()

def scene(d): d.rectangle([40, 40, 120, 150], fill="red"); d.ellipse([150, 60, 230, 140], fill="blue")
def scene_broken(d): scene(d); d.rectangle([60, 20, 200, 60], fill="red")   # a limb where none should be

def test_identical_scores_one():
    a = png(scene); assert compare(a, a).score == 1.0

def test_corruption_lowers_score_and_localises():
    r = compare(png(scene), png(scene_broken))
    assert r.score < 0.97
    top_row = r.tile_scores[0]; bottom_row = r.tile_scores[-1]
    assert min(top_row) < min(bottom_row)

def test_size_mismatch_is_handled():
    r = compare(png(scene), png(scene, size=(512, 384)))
    assert r.size == (256, 192) and r.score > 0.9
```

- [ ] **Step 2: Run** — ImportError.

- [ ] **Step 3: Implement**

```python
from __future__ import annotations
from dataclasses import dataclass
from io import BytesIO
import numpy as np
from PIL import Image
from skimage.metrics import structural_similarity

@dataclass
class DiffResult:
    score: float
    tile_scores: list[list[float]]
    diff_png: bytes
    size: tuple[int, int]

def _load(b: bytes) -> Image.Image:
    return Image.open(BytesIO(b)).convert("RGB")

def compare(a_png: bytes, b_png: bytes, tiles: int = 8) -> DiffResult:
    a, b = _load(a_png), _load(b_png)
    size = (min(a.width, b.width), min(a.height, b.height))
    a, b = a.resize(size, Image.LANCZOS), b.resize(size, Image.LANCZOS)
    ga, gb = np.asarray(a.convert("L"), dtype=np.float32), np.asarray(b.convert("L"), dtype=np.float32)
    score = float(structural_similarity(ga, gb, data_range=255.0))
    th, tw = size[1] // tiles, size[0] // tiles
    tile_scores = []
    heat = a.copy()
    px = heat.load()
    for ty in range(tiles):
        row = []
        for tx in range(tiles):
            sa, sb = ga[ty*th:(ty+1)*th, tx*tw:(tx+1)*tw], gb[ty*th:(ty+1)*th, tx*tw:(tx+1)*tw]
            s = float(structural_similarity(sa, sb, data_range=255.0, win_size=7)) if min(sa.shape) >= 7 else 1.0
            row.append(round(s, 4))
            red = int(255 * max(0.0, 1.0 - s))
            for y in range(ty*th, (ty+1)*th):
                for x in range(tx*tw, (tx+1)*tw):
                    r, g, bb = px[x, y]; px[x, y] = (min(255, r + red), g // 2 if red > 40 else g, bb // 2 if red > 40 else bb)
        tile_scores.append(row)
    out = BytesIO(); heat.save(out, "PNG")
    return DiffResult(score=round(score, 4), tile_scores=tile_scores, diff_png=out.getvalue(), size=size)
```

- [ ] **Step 4: Run tests** — 3 PASS (if the identical case yields 0.9999 due to float, compare with `>= 0.999`).

- [ ] **Step 5: Commit**

```bash
git add tools/mcp/icube_debug/imagediff.py tools/mcp/tests/test_imagediff.py
git commit -m "mcp: SSIM image diff with tile heatmap"
```

---

### Task 12: Config and upstream oracle

**Files:**
- Create: `tools/mcp/icube_debug/config.py`, `tools/mcp/icube_debug/oracle.py`, `tools/mcp/tests/test_oracle.py`

**Interfaces:**
- Produces: `def load_config(path: Path | None = None) -> Config` (`@dataclass Config: dolphin_app: Path; cpu_core: int; games: dict[str, Path]; home: Path`) reading `~/.icube-debug/config.toml` (create with defaults if missing); `def dump_frames(cfg: Config, game_id: str, frames: int, overrides: dict[str, str] | None = None, timeout: float = 300) -> Path` — runs Dolphin.app headless with frame dumping as PNGs into a temp user dir, waits until frame `frames` exists, kills Dolphin, returns the PNG path; `class OracleError(Exception)`.

- [ ] **Step 1: Failing tests** (subprocess is injected so no Dolphin is needed)

```python
from pathlib import Path
import pytest
from icube_debug.config import load_config
from icube_debug.oracle import build_command, pick_frame, OracleError

def test_config_defaults_created(tmp_path):
    cfg = load_config(tmp_path / "config.toml")
    assert cfg.dolphin_app == Path("/Applications/Dolphin.app") and cfg.cpu_core == 5 and cfg.games == {}

def test_build_command_sets_dump_and_core(tmp_path):
    cmd = build_command(Path("/Applications/Dolphin.app"), Path("/r/x.rvz"), tmp_path, cpu_core=5, overrides={"GFX.Hacks.FastMath": "False"})
    s = " ".join(cmd)
    assert "-b" in cmd and "-e /r/x.rvz" in s
    assert "Dolphin.Core.CPUCore=5" in s and "Dolphin.Core.CPUThread=False" in s
    assert "Dolphin.Movie.DumpFramesAsImages=True" in s and f"-u {tmp_path}" in s
    assert "GFX.Hacks.FastMath=False" in s

def test_pick_frame_requires_enough_frames(tmp_path):
    d = tmp_path / "Dump" / "Frames"; d.mkdir(parents=True)
    for i in range(3): (d / f"framedump_{i:04d}.png").write_bytes(b"x")
    assert pick_frame(tmp_path, 2).name == "framedump_0002.png"
    with pytest.raises(OracleError, match="only 3"):
        pick_frame(tmp_path, 10)
```

- [ ] **Step 2: Run** — ImportError.

- [ ] **Step 3: Implement `config.py`**

```python
from __future__ import annotations
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

DEFAULT = '''[oracle]
dolphin_app = "/Applications/Dolphin.app"
cpu_core = 5   # CachedInterpreter, matches the phone

[games]
# SMNE01 = "/path/to/New Super Mario Bros. Wii.rvz"
'''

@dataclass
class Config:
    dolphin_app: Path
    cpu_core: int
    games: dict[str, Path] = field(default_factory=dict)
    home: Path = Path.home() / ".icube-debug"

def load_config(path: Path | None = None) -> Config:
    path = path or Path.home() / ".icube-debug" / "config.toml"
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists():
        path.write_text(DEFAULT)
    doc = tomllib.loads(path.read_text())
    oracle = doc.get("oracle", {})
    return Config(dolphin_app=Path(oracle.get("dolphin_app", "/Applications/Dolphin.app")),
                  cpu_core=int(oracle.get("cpu_core", 5)),
                  games={k: Path(v) for k, v in doc.get("games", {}).items()},
                  home=path.parent)
```

- [ ] **Step 4: Implement `oracle.py`**

```python
from __future__ import annotations
import subprocess, tempfile, time
from pathlib import Path
from .config import Config

class OracleError(Exception):
    pass

def build_command(app: Path, iso: Path, user_dir: Path, cpu_core: int, overrides: dict[str, str] | None = None) -> list[str]:
    cmd = [str(app / "Contents/MacOS/Dolphin"), "-b", "-e", str(iso), "-u", str(user_dir),
           "-C", f"Dolphin.Core.CPUCore={cpu_core}", "-C", "Dolphin.Core.CPUThread=False",
           "-C", "Dolphin.Movie.DumpFrames=True", "-C", "Dolphin.Movie.DumpFramesAsImages=True",
           "-C", "Dolphin.Movie.DumpFramesSilent=True", "-C", "Dolphin.Core.EnableCheats=False"]
    for k, v in (overrides or {}).items():
        cmd += ["-C", f"{k}={v}"]
    return cmd

def pick_frame(user_dir: Path, frame: int) -> Path:
    frames = sorted((user_dir / "Dump" / "Frames").glob("framedump_*.png"))
    if len(frames) <= frame:
        raise OracleError(f"oracle produced only {len(frames)} frames, needed {frame + 1}")
    return frames[frame]

def dump_frames(cfg: Config, game_id: str, frames: int, overrides: dict[str, str] | None = None, timeout: float = 300) -> Path:
    iso = cfg.games.get(game_id)
    if iso is None:
        raise OracleError(f"no ISO mapped for {game_id} in {cfg.home / 'config.toml'}")
    if not (cfg.dolphin_app / "Contents/MacOS/Dolphin").exists():
        raise OracleError(f"Dolphin not found at {cfg.dolphin_app}")
    user_dir = Path(tempfile.mkdtemp(prefix="icube-oracle-"))
    proc = subprocess.Popen(build_command(cfg.dolphin_app, iso, user_dir, cfg.cpu_core, overrides),
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    deadline = time.time() + timeout
    try:
        while time.time() < deadline:
            try:
                return pick_frame(user_dir, frames)
            except OracleError:
                if proc.poll() is not None:
                    raise OracleError("Dolphin exited before producing enough frames")
                time.sleep(0.5)
        raise OracleError(f"oracle timed out after {timeout}s")
    finally:
        proc.terminate()
        try: proc.wait(5)
        except subprocess.TimeoutExpired: proc.kill()
```

Verify the frame-dump filename pattern on this machine once (`ls <user>/Dump/Frames`); Dolphin 2509 writes `framedump_<n>.png`-style names when `DumpFramesAsImages` is on — adjust the glob if it differs and update the test fixture names to match.

- [ ] **Step 5: Run tests** — 3 PASS.

- [ ] **Step 6: Commit**

```bash
git add tools/mcp/icube_debug/config.py tools/mcp/icube_debug/oracle.py tools/mcp/tests/test_oracle.py
git commit -m "mcp: config file and upstream Dolphin frame-dump oracle"
```

---

### Task 13: Scenarios and comparison

**Files:**
- Create: `tools/mcp/icube_debug/scenario.py`, `tools/mcp/tests/test_scenario.py`

**Interfaces:**
- Consumes: `Device` (Task 9), `compare` (Task 11), `dump_frames`/`Config` (Task 12).
- Produces: `@dataclass Scenario: game_id: str; frames: int; start: str = "boot"; settings_overrides: dict = {}`; `def run_on_device(dev: Device, sc: Scenario, boot: Callable[[str], None]) -> bytes` (PNG); `def compare_with_upstream(dev, cfg, sc, boot, threshold=0.97, guard=0.995) -> dict` with keys `score, verdict, device_png, upstream_png, diff_png` (paths under `cfg.home`); `def bisect_settings(dev, cfg, sc, keys, boot) -> list[dict]`; `def append_run(cfg, record: dict)` → `runs.jsonl`.

`boot(game_id)` is injected: on the device it is `dev.post("/api/debug/boot", {"game_id": …})` — **a route this plan does not add** (booting from the debug API needs the library lookup that `EmulationCoordinator` owns). Until it exists, `run_on_device` requires the game to be already booted and paused at power-on; `server.py` passes a `boot` that raises `NotImplementedError("boot via MCP not yet supported; boot the game manually and pause at frame 0")`. Track as follow-up.

- [ ] **Step 1: Failing tests** (fake Device)

```python
from pathlib import Path
from icube_debug.scenario import Scenario, run_on_device, compare_with_upstream
from icube_debug.config import Config

class FakeDevice:
    def __init__(self, png): self.png, self.calls = png, []
    def post(self, path, body=None): self.calls.append((path, body)); return {"frames_advanced": (body or {}).get("n", 0)}
    def get(self, path, **p): return {}
    def get_bytes(self, path): return self.png

def solid(color):
    from io import BytesIO; from PIL import Image
    b = BytesIO(); Image.new("RGB", (64, 48), color).save(b, "PNG"); return b.getvalue()

def test_run_on_device_pauses_advances_and_captures():
    d = FakeDevice(solid("red"))
    png = run_on_device(d, Scenario("SMNE01", 30), boot=lambda g: None)
    assert png == d.png
    assert ("/api/debug/pause", None) in d.calls and ("/api/debug/frame-advance", {"n": 30}) in d.calls

def test_compare_pass_and_fail(tmp_path, monkeypatch):
    cfg = Config(dolphin_app=Path("/x"), cpu_core=5, games={"SMNE01": Path("/x.rvz")}, home=tmp_path)
    monkeypatch.setattr("icube_debug.scenario.dump_frames", lambda *a, **k: _write(tmp_path / "up.png", solid("red")))
    r = compare_with_upstream(FakeDevice(solid("red")), cfg, Scenario("SMNE01", 30), boot=lambda g: None)
    assert r["verdict"] == "pass" and r["score"] >= 0.97
    r = compare_with_upstream(FakeDevice(solid("blue")), cfg, Scenario("SMNE01", 30), boot=lambda g: None)
    assert r["verdict"] == "fail"
    assert (tmp_path / "runs.jsonl").read_text().count("\n") == 2

def _write(p, b): p.write_bytes(b); return p
```

- [ ] **Step 2: Run** — ImportError.

- [ ] **Step 3: Implement**

```python
from __future__ import annotations
import json, time
from dataclasses import dataclass, field, asdict
from pathlib import Path
from typing import Callable
from .config import Config
from .imagediff import compare
from .oracle import dump_frames

@dataclass
class Scenario:
    game_id: str
    frames: int
    start: str = "boot"
    settings_overrides: dict = field(default_factory=dict)

def run_on_device(dev, sc: Scenario, boot: Callable[[str], None]) -> bytes:
    for k, v in sc.settings_overrides.items():
        dev.post(f"/api/settings/{k}", {"value": v})
    if sc.start == "boot":
        boot(sc.game_id)
    else:
        raise NotImplementedError("state-based scenarios need the STATE_VERSION shim (spec follow-up)")
    dev.post("/api/debug/pause")
    dev.post("/api/debug/frame-advance", {"n": sc.frames})
    return dev.get_bytes("/api/debug/screenshot")

def append_run(cfg: Config, record: dict) -> None:
    cfg.home.mkdir(parents=True, exist_ok=True)
    with (cfg.home / "runs.jsonl").open("a") as f:
        f.write(json.dumps(record) + "\n")

def compare_with_upstream(dev, cfg: Config, sc: Scenario, boot, threshold=0.97, guard=0.995) -> dict:
    ts = time.strftime("%Y%m%d-%H%M%S")
    shots = cfg.home / "shots"; diffs = cfg.home / "diffs"; goldens = cfg.home / "goldens"
    for d in (shots, diffs, goldens): d.mkdir(parents=True, exist_ok=True)
    a = run_on_device(dev, sc, boot)
    b = run_on_device(dev, sc, boot)
    if compare(a, b).score < guard:
        rec = {"ts": ts, "scenario": asdict(sc), "verdict": "indeterminate", "score": None}
        append_run(cfg, rec); return rec
    device_png = shots / f"{ts}-{sc.game_id}-device.png"; device_png.write_bytes(a)
    overrides = {k: str(v) for k, v in sc.settings_overrides.items()}
    upstream_path = dump_frames(cfg, sc.game_id, sc.frames, overrides)
    upstream_png = goldens / f"{ts}-{sc.game_id}-upstream.png"; upstream_png.write_bytes(Path(upstream_path).read_bytes())
    r = compare(a, upstream_png.read_bytes())
    diff_png = diffs / f"{ts}-{sc.game_id}-diff.png"; diff_png.write_bytes(r.diff_png)
    rec = {"ts": ts, "scenario": asdict(sc), "score": r.score, "tile_scores": r.tile_scores,
           "verdict": "pass" if r.score >= threshold else "fail",
           "device_png": str(device_png), "upstream_png": str(upstream_png), "diff_png": str(diff_png)}
    append_run(cfg, rec)
    return rec

def bisect_settings(dev, cfg: Config, sc: Scenario, keys: list[str], boot, upstream_png: bytes) -> list[dict]:
    baseline = {k: v["value"] for k, v in dev.get("/api/settings").items() if k in keys}
    results = []
    for key in keys:
        cur = baseline.get(key)
        flipped = (not cur) if isinstance(cur, bool) else cur
        if flipped == cur:
            results.append({"key": key, "from": cur, "to": cur, "score": None, "note": "non-boolean, skipped"}); continue
        dev.post(f"/api/settings/{key}", {"value": flipped})
        try:
            png = run_on_device(dev, sc, boot)
            results.append({"key": key, "from": cur, "to": flipped, "score": compare(png, upstream_png).score})
        finally:
            dev.post(f"/api/settings/{key}", {"value": cur})
    return results
```

- [ ] **Step 4: Run tests** — 2 PASS.

- [ ] **Step 5: Commit**

```bash
git add tools/mcp/icube_debug/scenario.py tools/mcp/tests/test_scenario.py
git commit -m "mcp: scenarios, upstream comparison with determinism guard, settings bisection"
```

---

### Task 14: FastMCP server, smoke, README, registration

**Files:**
- Create: `tools/mcp/icube_debug/server.py`, `tools/mcp/icube_debug/smoke.py`, `tools/mcp/README.md`, `tools/mcp/tests/test_server.py`

**Interfaces:**
- Consumes everything above.
- Produces: FastMCP server `icube` with tools `health, settings_get, settings_set, settings_all, settings_reset, snapshot_save, snapshot_list, snapshot_diff, pause, resume, frame_advance, savestate, loadstate, screenshot, render_state, logs, build_info, watch_events, run_scenario, compare_with_upstream, bisect_settings`; `main()` entry point.

- [ ] **Step 1: Failing test** (tools are plain functions; call them with a fake device via the module-level `_device` factory)

```python
import icube_debug.server as srv

class FakeDevice:
    def get(self, path, **p): return {"path": path, **p}
    def post(self, path, body=None): return {"path": path, "body": body}
    def get_bytes(self, path): return b"\x89PNG"

def test_tools_route_to_device(monkeypatch):
    monkeypatch.setattr(srv, "_device", lambda base: FakeDevice())
    assert srv.health.fn()["path"] == "/api/health"
    assert srv.frame_advance.fn(n=7)["body"] == {"n": 7}
    assert srv.settings_set.fn(key="GFX.Hacks.FastMath", value=False)["body"] == {"value": False}
    assert srv.logs.fn(tail=5)["tail"] == 5
```

- [ ] **Step 2: Run** — ImportError.

- [ ] **Step 3: Implement `server.py`**

```python
from __future__ import annotations
import asyncio, time
from pathlib import Path
from fastmcp import FastMCP
from fastmcp.utilities.types import Image
from .config import load_config
from .device import Device
from .events import collect_events
from .scenario import Scenario, run_on_device, compare_with_upstream as _compare, bisect_settings as _bisect

mcp = FastMCP("icube", instructions=(
    "Drive an iCube device over its debug API (port 8723 via `iproxy 8723 8723`). "
    "Read render_state to learn what is actually running, not just configured. "
    "compare_with_upstream needs the game already booted and paused at power-on."))

def _device(base: str) -> Device:
    return Device(base)

def _not_supported(game_id: str):
    raise NotImplementedError("boot via MCP not yet supported; boot the game manually and pause at frame 0")

@mcp.tool()
def health(device: str = "127.0.0.1:8723") -> dict:
    """Build, game, core state and fps."""
    return _device(device).get("/api/health")

@mcp.tool()
def settings_get(key: str, device: str = "127.0.0.1:8723") -> dict:
    """One setting with its metadata."""
    return _device(device).get("/api/settings").get(key, {"error": f"unknown key {key}"})

@mcp.tool()
def settings_set(key: str, value: bool | int | float | str, device: str = "127.0.0.1:8723") -> dict:
    """Set a setting; reply says whether it applied live or needs a reboot."""
    return _device(device).post(f"/api/settings/{key}", {"value": value})

@mcp.tool()
def settings_all(device: str = "127.0.0.1:8723") -> dict:
    """Every key with resolved value and per-layer values."""
    return _device(device).get("/api/settings/all")

@mcp.tool()
def settings_reset(keys: list[str] | None = None, device: str = "127.0.0.1:8723") -> dict:
    """Delete keys (or all) from Base/PerGame/CurrentRun layers."""
    return _device(device).post("/api/settings/reset", {"keys": keys or []})

@mcp.tool()
def snapshot_save(name: str, device: str = "127.0.0.1:8723") -> dict:
    return _device(device).post("/api/settings/snapshots", {"name": name})

@mcp.tool()
def snapshot_list(device: str = "127.0.0.1:8723") -> list:
    return _device(device).get("/api/settings/snapshots")

@mcp.tool()
def snapshot_diff(a: str, b: str, device: str = "127.0.0.1:8723") -> list:
    return _device(device).get(f"/api/settings/snapshots/{a}/diff/{b}")

@mcp.tool()
def pause(device: str = "127.0.0.1:8723") -> dict:
    return _device(device).post("/api/debug/pause")

@mcp.tool()
def resume(device: str = "127.0.0.1:8723") -> dict:
    return _device(device).post("/api/debug/resume")

@mcp.tool()
def frame_advance(n: int = 1, device: str = "127.0.0.1:8723") -> dict:
    """Advance exactly n emulated frames; core must be paused."""
    return _device(device).post("/api/debug/frame-advance", {"n": n})

@mcp.tool()
def savestate(slot: int = 1, device: str = "127.0.0.1:8723") -> dict:
    return _device(device).post("/api/debug/savestate", {"slot": slot})

@mcp.tool()
def loadstate(slot: int | None = None, path: str | None = None, device: str = "127.0.0.1:8723") -> dict:
    return _device(device).post("/api/debug/loadstate", {"path": path} if path else {"slot": slot or 1})

@mcp.tool()
def screenshot(device: str = "127.0.0.1:8723") -> Image:
    """Current frame as PNG; also saved under ~/.icube-debug/shots/."""
    png = _device(device).get_bytes("/api/debug/screenshot")
    cfg = load_config(); shots = cfg.home / "shots"; shots.mkdir(parents=True, exist_ok=True)
    (shots / f"{time.strftime('%Y%m%d-%H%M%S')}.png").write_bytes(png)
    return Image(data=png, format="png")

@mcp.tool()
def render_state(device: str = "127.0.0.1:8723") -> dict:
    """Runtime truth: backend, CPU core in use, vertex loader, hacks, clocks."""
    return _device(device).get("/api/debug/render-state")

@mcp.tool()
def logs(tail: int = 200, device: str = "127.0.0.1:8723") -> dict:
    return _device(device).get("/api/logs", tail=tail)

@mcp.tool()
def build_info(device: str = "127.0.0.1:8723") -> dict:
    return _device(device).get("/api/debug/build-info")

@mcp.tool()
def watch_events(kinds: list[str] | None = None, seconds: int = 10, device: str = "127.0.0.1:8723") -> list:
    """Collect WebSocket events (settings.changed, perf.sample, log.line, core.state) for up to 120 s."""
    return asyncio.run(collect_events(device, kinds, min(seconds, 120)))

@mcp.tool()
def run_scenario(game_id: str, frames: int, settings_overrides: dict | None = None, device: str = "127.0.0.1:8723") -> Image:
    """Pause, advance `frames`, screenshot. Game must already be booted and paused at power-on."""
    png = run_on_device(_device(device), Scenario(game_id, frames, "boot", settings_overrides or {}), lambda g: None)
    return Image(data=png, format="png")

@mcp.tool()
def compare_with_upstream(game_id: str, frames: int, settings_overrides: dict | None = None, threshold: float = 0.97, device: str = "127.0.0.1:8723") -> dict:
    """Same scenario on the device and on /Applications/Dolphin.app; SSIM score, verdict, image paths."""
    return _compare(_device(device), load_config(), Scenario(game_id, frames, "boot", settings_overrides or {}), lambda g: None, threshold)

@mcp.tool()
def bisect_settings(game_id: str, frames: int, keys: list[str], upstream_png: str, device: str = "127.0.0.1:8723") -> list:
    """Flip each boolean key, re-run the scenario, score against a saved upstream frame."""
    return _bisect(_device(device), load_config(), Scenario(game_id, frames), keys, lambda g: None, Path(upstream_png).read_bytes())

def main():
    mcp.run()

if __name__ == "__main__":
    main()
```

Because booting via the API is a follow-up, `run_scenario`/`compare_with_upstream` pass a no-op `boot` and rely on the operator having the game paused at frame 0; the docstrings say so.

- [ ] **Step 4: `smoke.py`**

```python
from .device import Device
def main():
    d = Device()
    print("health", d.get("/api/health"))
    d.post("/api/settings/snapshots", {"name": "smoke"})
    print("snapshots", d.get("/api/settings/snapshots"))
    d.post("/api/debug/pause")
    print("advance", d.post("/api/debug/frame-advance", {"n": 10}))
    print("screenshot bytes", len(d.get_bytes("/api/debug/screenshot")))
    d.post("/api/debug/resume")
if __name__ == "__main__":
    main()
```

- [ ] **Step 5: README** — setup (`brew install libimobiledevice` for `iproxy`, `uv sync`), registration:

```bash
claude mcp add icube -- uv --directory /ABS/PATH/tools/mcp run icube-debug-mcp
```

the `config.toml` game map, and a 5-line "first session" walkthrough (`health` → `render_state` → `snapshot_save before` → change → `snapshot_diff` → `compare_with_upstream`).

- [ ] **Step 6: Run all tests** — `uv run pytest -q`: all PASS.

- [ ] **Step 7: Register and smoke against a device**

```bash
claude mcp add icube -- uv --directory "$(pwd)" run icube-debug-mcp
make -C ../../Source/iOS/App mcp-smoke
```

Expected: health JSON, 10 frames advanced, a non-zero screenshot byte count.

- [ ] **Step 8: Commit**

```bash
git add tools/mcp/icube_debug/server.py tools/mcp/icube_debug/smoke.py tools/mcp/README.md tools/mcp/tests/test_server.py
git commit -m "mcp: FastMCP server with mirror, streaming and comparison tools"
```

---

## Follow-ups recorded, not in this plan

- `POST /api/debug/boot {"game_id"}` so scenarios can boot unattended (needs `EmulationCoordinator` library lookup).
- `STATE_VERSION` load-compat shim (accept 175) for state-based scenarios.
- Phase-2 geometry detector (`GFX_DEBUG_GEOMETRY_SENTINEL`).
- iFly: adopt the WebSocket event schema and the `render-state`/`frame-advance` routes.
