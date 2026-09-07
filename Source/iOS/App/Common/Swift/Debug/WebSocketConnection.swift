// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later
//
// TARGET PATH (when integrated):
//   Source/iOS/App/Common/Swift/Debug/WebSocketConnection.swift
//
// Server-side WebSocket connection wrapper on top of an already-upgraded
// NWConnection. One-way bus: the server pushes text frames to the client
// (`send(text:)`); frames received from the client are only inspected for
// control opcodes (ping → pong, close → close) and otherwise ignored.

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
