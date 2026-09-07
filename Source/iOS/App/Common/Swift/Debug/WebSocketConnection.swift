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

  /// Called from the completion of a `connection.send` (the 101 handshake
  /// response). NOTE: `connection` was started (via `connection.start(queue:)`)
  /// on the *server's* shared queue before the WebSocket upgrade was known --
  /// not on `self.queue`, which each connection now gets as its own dedicated
  /// serial queue. So this handshake completion, like every other NWConnection
  /// completion in this file, fires on the server's queue, not `self.queue`.
  /// Hop onto `self.queue` before touching `buffer`/`closed` so this
  /// connection's state is only ever touched from its own queue, never
  /// contending with the server's shared queue or other connections.
  func start(initial: Data) {
    queue.async { [weak self] in
      guard let self else { return }
      self.buffer = initial
      self.drain()
      self.receive()
    }
  }

  /// May be called from any thread (e.g. Task 5's event bus). Hops onto the
  /// connection's serial `queue` before touching `closed` / `connection` so
  /// there is no race with `receive()`/`drain()`/`close()`, which also only
  /// ever run on `queue`.
  func send(text: String) {
    queue.async { [weak self] in
      self?.sendOnQueue(text: text)
    }
  }

  private func sendOnQueue(text: String) {
    guard !closed else { return }
    let frame = WebSocketFrame(fin: true, opcode: .text, payload: Data(text.utf8)).encode()
    // NWConnection completions fire on whatever queue `connection.start(queue:)`
    // used -- the SERVER's shared queue, not `self.queue` (see the note on
    // `start(initial:)` above). Hop back onto `self.queue` before touching
    // `closed` so this stays confined to the connection's own queue.
    connection.send(content: frame, completion: .contentProcessed { [weak self] err in
      guard let self, err != nil else { return }
      self.queue.async { self.closeOnQueue() }
    })
  }

  /// May be called from any thread. See `send(text:)`.
  func close() {
    queue.async { [weak self] in
      self?.closeOnQueue()
    }
  }

  private func closeOnQueue() {
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
      // This completion, like every other NWConnection completion in this
      // file, fires on the server's shared queue (see `start(initial:)`),
      // not `self.queue` -- hop over before touching `buffer`/`closed`.
      guard let self else { return }
      self.queue.async {
        if let data { self.buffer.append(data); self.drain() }
        if error != nil || isComplete { self.closeOnQueue(); return }
        if !self.closed { self.receive() }
      }
    }
  }

  /// Consume every complete frame in the buffer. Text frames from the client are ignored
  /// (the bus is one-way); ping → pong; close → close. Always called already
  /// queue-confined (from `start(initial:)` or `receive()`'s hop).
  private func drain() {
    while let (frame, used) = WebSocketFrame.decode(buffer) {
      buffer.removeFirst(used)
      switch frame.opcode {
      case .ping:
        let pong = WebSocketFrame(fin: true, opcode: .pong, payload: frame.payload).encode()
        connection.send(content: pong, completion: .contentProcessed { _ in })
      case .close: closeOnQueue(); return
      default: break
      }
    }
  }
}
