import Foundation
import Network

/// An HTTP server on 127.0.0.1 that reads one request per connection and closes the connection after its response.
@MainActor
public final class LoopbackServer {
    /// Gets each request. It answers once, at once or later.
    public typealias Handler = (HTTPRequest, @escaping (HTTPResponse) -> Void) -> Void

    private let handler: Handler
    private var listener: NWListener?
    private var starting: CheckedContinuation<Int, any Error>?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Listens on an ephemeral port and returns it.
    public func start() async throws -> Int {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.listener(listener, changedTo: state) }
        }
        return try await withCheckedThrowingContinuation { continuation in
            starting = continuation
            listener.start(queue: .main)
        }
    }

    /// Stops listening and drops every open connection, answered or not.
    public func stop() {
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.cancel() }
        connections = [:]
    }

    private func listener(_ listener: NWListener, changedTo state: NWListener.State) {
        switch state {
        case .ready:
            starting?.resume(returning: Int(listener.port?.rawValue ?? 0))
            starting = nil
        case .failed(let error):
            starting?.resume(throwing: error)
            starting = nil
            listener.cancel()
        case .cancelled:
            starting?.resume(throwing: CancellationError())
            starting = nil
        case .setup, .waiting:
            break
        @unknown default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: MainActor.assumeIsolated { _ = self?.connections.removeValue(forKey: key) }
            default: break
            }
        }
        connection.start(queue: .main)
        receive(on: connection, HTTPRequestReader())
    }

    private func receive(on connection: NWConnection, _ reader: HTTPRequestReader) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                self?.received(data, on: connection, reader, isComplete: isComplete || error != nil)
            }
        }
    }

    private func received(_ data: Data?, on connection: NWConnection, _ reader: HTTPRequestReader, isComplete: Bool) {
        var reader = reader
        switch data.map({ reader.read($0) }) ?? .incomplete {
        case .complete(let request):
            var answered = false
            handler(request) { [weak self] response in
                guard !answered else { return }
                answered = true
                self?.send(response, on: connection)
            }
        case .rejected:
            send(HTTPResponse(status: 400), on: connection)
        case .incomplete where isComplete:
            connection.cancel()
        case .incomplete:
            receive(on: connection, reader)
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        guard connections[ObjectIdentifier(connection)] != nil else { return }
        connection.send(
            content: response.serialized,
            contentContext: .finalMessage,
            isComplete: true,
            completion: .contentProcessed { _ in connection.cancel() }
        )
    }
}
