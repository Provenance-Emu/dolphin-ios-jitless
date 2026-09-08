// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later
//
// TARGET PATH (when integrated):
//   Source/iOS/App/Common/Swift/Debug/NativeWebServer.swift
//
// Pure-Swift HTTP + JSON server on NWListener (Network.framework), zero deps.
// Trimmed port of iFly's NativeWebServer: listener + HTTP request parse +
// custom-route table + JSON response helpers. WebDAV / multipart upload /
// file browser were dropped — this server only answers the debug JSON API.
//
// SECURITY: binds loopback only (127.0.0.1) instead of all interfaces, and
// additionally rejects any connection whose remote endpoint is not loopback.
// To reach it from a Mac over USB, forward the port with libimobiledevice:
//     iproxy 8723 8723   # then curl http://127.0.0.1:8723/api/perf/live

import Foundation
import Network

/// A lightweight loopback HTTP/JSON server for the debug + benchmark API.
final class NativeWebServer: @unchecked Sendable {
  // MARK: - Types

  /// Handler signature: returns a JSON-serializable dictionary, or nil for 404.
  typealias CustomHandlerBlock = (
    _ method: String,
    _ path: String,
    _ query: [String: String]?,
    _ body: Data?
  ) -> [String: Any]?

  private struct CustomRoute {
    let method: String
    /// Exact path match (nil when using regex).
    let path: String?
    /// Regex match (nil when using exact path).
    let regex: NSRegularExpression?
    let handler: CustomHandlerBlock
  }

  /// A raw (non-JSON) response: status, content type, and body bytes verbatim.
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

  // MARK: - Configuration

  let port: UInt16

  // MARK: - State

  private var listener: NWListener?
  private var activeConnections = [ObjectIdentifier: NWConnection]()
  private let queue = DispatchQueue(label: "com.icube.debugserver", qos: .userInitiated)
  private let lock = NSLock()
  private var customRoutes: [CustomRoute] = []
  private var rawRoutes: [RawRoute] = []

  /// When set, intercepts `Upgrade: websocket` requests: returning `false`
  /// rejects the upgrade with 404, `true` accepts it (the handler is
  /// expected to have already stashed `socket` for later use, e.g. to
  /// broadcast events to it).
  var webSocketHandler: ((_ path: String, _ socket: WebSocketConnection) -> Bool)?

  // MARK: - Public API

  var isRunning: Bool {
    lock.lock()
    defer { lock.unlock() }
    return listener?.state == .ready
  }

  /// The loopback URL the API is served on.
  var serverURL: URL? {
    guard isRunning else { return nil }
    return URL(string: "http://127.0.0.1:\(port)/")
  }

  // MARK: - Init

  init(port: UInt16 = 8723) {
    self.port = port
  }

  // MARK: - Start / Stop

  /// Start the listener and wait until it reaches `.ready`.
  func start() async throws {
    guard !isRunning else { return }

    let params = NWParameters.tcp
    params.allowLocalEndpointReuse = true
    // Restrict the bind to loopback. `requiredLocalEndpoint` pins the listening
    // socket to 127.0.0.1 so the server is never reachable off-device even if
    // the reject in handleNewConnection were bypassed.
    params.requiredLocalEndpoint = NWEndpoint.hostPort(
      host: .ipv4(.loopback),
      port: NWEndpoint.Port(rawValue: port)!
    )

    // The port is already carried by `requiredLocalEndpoint`. Passing it again via
    // `NWListener(using:on:)` makes Network.framework reject the listener with
    // NWError 22 (EINVAL) on iOS 26 — the two port sources conflict — and the
    // server silently never binds ("[DebugServer] failed to start" in syslog).
    let listener = try NWListener(using: params)
    listener.newConnectionHandler = { [weak self] conn in
      self?.handleNewConnection(conn)
    }

    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      var resumed = false
      listener.stateUpdateHandler = { [weak self] state in
        switch state {
        case .ready:
          if !resumed { resumed = true
            continuation.resume()
          }
        case .failed(let error):
          self?.stop()
          if !resumed { resumed = true
            continuation.resume(throwing: error)
          }
        case .cancelled:
          if !resumed {
            resumed = true
            continuation.resume(throwing: DebugServerError.initializationFailed)
          }
        default:
          break
        }
      }
      listener.start(queue: self.queue)
    }
    self.listener = listener
  }

  func stop() {
    lock.lock()
    let conns = activeConnections
    activeConnections.removeAll()
    lock.unlock()

    for conn in conns.values { conn.cancel() }
    listener?.cancel()
    listener = nil
  }

  // MARK: - Route Registration

  func addCustomHandler(forMethod method: String, path: String,
                        handler: @escaping CustomHandlerBlock) {
    lock.lock()
    defer { lock.unlock() }
    customRoutes.append(CustomRoute(method: method.uppercased(),
                                    path: path, regex: nil, handler: handler))
  }

  func addCustomHandler(forMethod method: String, pathRegex pattern: String,
                        handler: @escaping CustomHandlerBlock) {
    lock.lock()
    defer { lock.unlock() }
    guard let regex = try? NSRegularExpression(pattern: "^\(pattern)$", options: [])
    else { return }
    customRoutes.append(CustomRoute(method: method.uppercased(),
                                    path: nil, regex: regex, handler: handler))
  }

  /// Register a raw-response handler for an exact method + path. Raw routes
  /// are checked before JSON `customRoutes` and can return non-JSON bodies
  /// (e.g. PNG bytes) with an explicit status/content type.
  func addRawHandler(forMethod method: String, path: String,
                     handler: @escaping RawHandlerBlock) {
    lock.lock()
    defer { lock.unlock() }
    rawRoutes.append(RawRoute(method: method.uppercased(), path: path, handler: handler))
  }

  // MARK: - Connection Handling

  /// True if a connection's remote endpoint is the loopback address.
  /// Compares the textual address rather than relying on an `isLoopback`
  /// property (which may not exist on every SDK) — `debugDescription` of an
  /// IPv4/IPv6 address is the numeric form, and `%` strips any zone id.
  private func isLoopback(_ connection: NWConnection) -> Bool {
    guard case let .hostPort(host, _) = connection.endpoint else { return false }
    let raw: String
    switch host {
    case .ipv4(let addr): raw = "\(addr)"
    case .ipv6(let addr): raw = "\(addr)"
    case .name(let name, _): raw = name
    @unknown default: return false
    }
    let normalized = raw.split(separator: "%").first.map(String.init) ?? raw
    return normalized == "127.0.0.1" || normalized == "::1" || normalized == "localhost"
  }

  private func handleNewConnection(_ connection: NWConnection) {
    // Defence in depth: even though the listener is loopback-bound, refuse
    // anything that is not coming from 127.0.0.1 / ::1.
    guard isLoopback(connection) else {
      connection.cancel()
      return
    }

    lock.lock()
    activeConnections[ObjectIdentifier(connection)] = connection
    lock.unlock()

    connection.stateUpdateHandler = { [weak self] state in
      switch state {
      case .cancelled, .failed:
        self?.lock.lock()
        self?.activeConnections.removeValue(forKey: ObjectIdentifier(connection))
        self?.lock.unlock()
      default:
        break
      }
    }
    connection.start(queue: queue)
    receiveHTTPRequest(on: connection, accumulated: Data())
  }

  /// Incrementally read until the full HTTP headers (\r\n\r\n) arrive, then
  /// read any declared body, then dispatch.
  private func receiveHTTPRequest(on connection: NWConnection, accumulated: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
      [weak self] data, _, isComplete, error in
      guard let self else { return }

      if error != nil { connection.cancel()
        return
      }

      var buffer = accumulated
      if let data { buffer.append(data) }

      if let headerEnd = buffer.findRange(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) {
        let headersData = buffer[buffer.startIndex ..< headerEnd.lowerBound]
        let bodyStart = buffer[headerEnd.upperBound...]

        guard let headersStr = String(data: headersData, encoding: .utf8),
              let request = HTTPRequest.parse(headersStr) else {
          self.sendResponse(on: connection, status: 400,
                            statusText: "Bad Request", body: "Bad Request")
          return
        }

        if request.headers["upgrade"]?.lowercased() == "websocket",
           let key = request.headers["sec-websocket-key"] {
          self.lock.lock()
          let webSocketHandler = self.webSocketHandler
          self.lock.unlock()
          guard let handler = webSocketHandler else {
            self.sendResponse(on: connection, status: 404, statusText: "Not Found", body: "Not Found")
            return
          }
          // Each WebSocket connection gets its own serial queue rather than sharing
          // the server's single `self.queue` (which also serializes every HTTP
          // connection's accept/parse/route work). Without this, one slow or
          // chatty WebSocket client's send/receive/drain work would contend with
          // -- and could stall -- unrelated HTTP requests and every other open
          // WebSocket connection, since they'd all funnel through one queue.
          // NOTE: `connection` (the underlying NWConnection) was already started
          // via `connection.start(queue: self.queue)` above, before we know it's
          // a WebSocket upgrade -- so its receive/send completions still arrive
          // on `self.queue`, not on this new queue. WebSocketConnection.swift
          // hops those completions onto its own queue explicitly before touching
          // any of its mutable state (`buffer`, `closed`).
          let socket = WebSocketConnection(
            connection: connection, queue: DispatchQueue(label: "com.icube.debugserver.ws")
          )
          guard handler(request.path, socket) else {
            self.sendResponse(on: connection, status: 404, statusText: "Not Found", body: "Not Found")
            return
          }
          connection.send(content: WebSocketHandshake.response(for: key), completion: .contentProcessed { _ in
            socket.start(initial: Data(bodyStart))
          })
          return
        }

        let contentLength = request.contentLength
        if contentLength > 0, bodyStart.count < contentLength {
          self.bufferRemainingBody(on: connection, initial: Data(bodyStart),
                                   remaining: contentLength - bodyStart.count) { fullBody in
            self.routeRequest(on: connection, request: request, body: fullBody)
          }
        } else {
          let body = contentLength > 0 ? Data(bodyStart.prefix(contentLength)) : Data()
          self.routeRequest(on: connection, request: request, body: body)
        }
      } else if buffer.count > 64 * 1024 {
        self.sendResponse(on: connection, status: 413,
                          statusText: "Request Entity Too Large", body: "Headers too large")
      } else if isComplete {
        connection.cancel()
      } else {
        self.receiveHTTPRequest(on: connection, accumulated: buffer)
      }
    }
  }

  private func bufferRemainingBody(on connection: NWConnection, initial: Data,
                                   remaining: Int, completion: @escaping (Data) -> Void) {
    var buffer = initial
    func readRemaining(_ bytesLeft: Int) {
      if bytesLeft <= 0 { completion(buffer)
        return
      }
      connection.receive(minimumIncompleteLength: 1,
                         maximumLength: min(bytesLeft, 65536)) { data, _, isComplete, error in
        if let data { buffer.append(data) }
        let newLeft = bytesLeft - (data?.count ?? 0)
        if newLeft <= 0 || isComplete || error != nil {
          completion(buffer)
        } else {
          readRemaining(newLeft)
        }
      }
    }
    readRemaining(remaining)
  }

  // MARK: - Routing

  private func routeRequest(on connection: NWConnection, request: HTTPRequest, body: Data) {
    lock.lock()
    let raws = rawRoutes
    lock.unlock()
    if let raw = raws.first(where: { $0.method == request.method && $0.path == request.path }) {
      let r = raw.handler(request, body.isEmpty ? nil : body)
      sendDataResponse(on: connection, status: r.status, statusText: Self.statusText(r.status),
                       contentType: r.contentType, body: r.body)
      return
    }

    lock.lock()
    let routes = customRoutes
    lock.unlock()

    for route in routes {
      guard route.method == request.method else { continue }
      if let exactPath = route.path {
        guard request.path == exactPath else { continue }
      } else if let regex = route.regex {
        let range = NSRange(request.path.startIndex..., in: request.path)
        guard regex.firstMatch(in: request.path, range: range) != nil else { continue }
      }

      let queryDict = request.queryParameters
      let result = route.handler(request.method, request.path,
                                 queryDict.isEmpty ? nil : queryDict,
                                 body.isEmpty ? nil : body)

      if var result {
        var status = 200
        if result["ok"] as? Bool == false {
          status = (result["status"] as? Int) ?? 400
          result.removeValue(forKey: "status")
        }
        if let jsonData = try? JSONSerialization.data(withJSONObject: result,
                                                      options: [.sortedKeys]) {
          sendDataResponse(on: connection, status: status, statusText: Self.statusText(status),
                           contentType: "application/json", body: jsonData)
        } else {
          sendResponse(on: connection, status: 500, statusText: "Internal Server Error",
                       body: "Handler returned invalid JSON")
        }
      } else {
        sendResponse(on: connection, status: 404, statusText: "Not Found", body: "Not Found")
      }
      return
    }

    sendResponse(on: connection, status: 404, statusText: "Not Found", body: "Not Found")
  }

  // MARK: - Response Helpers

  static func statusText(_ code: Int) -> String {
    switch code {
    case 200: return "OK"
    case 400: return "Bad Request"
    case 404: return "Not Found"
    case 409: return "Conflict"
    case 500: return "Internal Server Error"
    case 504: return "Gateway Timeout"
    default: return "Status \(code)"
    }
  }

  private func sendResponse(on connection: NWConnection, status: Int, statusText: String,
                            body: String,
                            contentType: String = "text/plain; charset=utf-8") {
    sendDataResponse(on: connection, status: status, statusText: statusText,
                     contentType: contentType, body: Data(body.utf8))
  }

  private func sendDataResponse(on connection: NWConnection, status: Int, statusText: String,
                                contentType: String, body: Data) {
    let header = """
    HTTP/1.1 \(status) \(statusText)\r\n\
    Content-Type: \(contentType)\r\n\
    Content-Length: \(body.count)\r\n\
    Connection: close\r\n\
    \r\n
    """
    var response = Data(header.utf8)
    response.append(body)
    connection.send(content: response,
                    completion: .contentProcessed { _ in connection.cancel() })
  }
}

// MARK: - Errors

enum DebugServerError: Error, LocalizedError {
  case initializationFailed
  case startFailed(Error)

  var errorDescription: String? {
    switch self {
    case .initializationFailed: return "Failed to initialize debug server"
    case .startFailed(let error): return "Failed to start debug server: \(error.localizedDescription)"
    }
  }
}

// MARK: - HTTP Request Parsing

struct HTTPRequest {
  let method: String
  let path: String
  let queryString: String?
  let headers: [String: String]

  var contentLength: Int { Int(headers["content-length"] ?? "") ?? 0 }

  var queryParameters: [String: String] {
    guard let qs = queryString else { return [:] }
    var params: [String: String] = [:]
    for pair in qs.split(separator: "&") {
      let parts = pair.split(separator: "=", maxSplits: 1)
      let key = String(parts[0]).removingPercentEncoding ?? String(parts[0])
      let value = parts.count > 1
        ? (String(parts[1]).removingPercentEncoding ?? String(parts[1]))
        : ""
      params[key] = value
    }
    return params
  }

  static func parse(_ headerString: String) -> HTTPRequest? {
    let lines = headerString.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else { return nil }

    let parts = requestLine.split(separator: " ", maxSplits: 2)
    guard parts.count >= 2 else { return nil }

    let method = String(parts[0]).uppercased()
    let rawURI = String(parts[1])

    let (path, query): (String, String?)
    if let qIdx = rawURI.firstIndex(of: "?") {
      path = String(rawURI[rawURI.startIndex ..< qIdx])
      query = String(rawURI[rawURI.index(after: qIdx)...])
    } else {
      path = rawURI
      query = nil
    }

    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
      guard let colonIdx = line.firstIndex(of: ":") else { continue }
      let key = line[line.startIndex ..< colonIdx]
        .trimmingCharacters(in: .whitespaces).lowercased()
      let value = line[line.index(after: colonIdx)...]
        .trimmingCharacters(in: .whitespaces)
      headers[key] = value
    }

    return HTTPRequest(method: method, path: path, queryString: query, headers: headers)
  }
}

// MARK: - Data Extension

private extension Data {
  /// Range of the first occurrence of `pattern`.
  func findRange(of pattern: Data) -> Range<Data.Index>? {
    guard !pattern.isEmpty, pattern.count <= count else { return nil }
    let end = count - pattern.count
    for i in 0 ... end {
      let start = index(startIndex, offsetBy: i)
      let stop = index(start, offsetBy: pattern.count)
      if self[start ..< stop] == pattern { return start ..< stop }
    }
    return nil
  }
}
