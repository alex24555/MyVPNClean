import Foundation
import Network

final class TunnelConnection {

    private let queue = DispatchQueue(label: "MyVPN.TunnelConnection")
    private var connection: NWConnection?
    private(set) var isReady = false

    func connect(host: String, port: UInt16) {
        disconnect()

        let nwHost = NWEndpoint.Host(host)
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            log("Invalid port: \(port)")
            return
        }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        let newConnection = NWConnection(host: nwHost, port: nwPort, using: parameters)
        self.connection = newConnection
        self.isReady = false

        newConnection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }

            switch state {
            case .setup:
                self.log("State: setup")
            case .waiting(let error):
                self.isReady = false
                self.log("State: waiting (\(error.localizedDescription))")
            case .preparing:
                self.log("State: preparing")
            case .ready:
                self.isReady = true
                self.log("State: ready")
                self.receive()
            case .failed(let error):
                self.isReady = false
                self.log("State: failed (\(error.localizedDescription))")
            case .cancelled:
                self.isReady = false
                self.log("State: cancelled")
            @unknown default:
                self.isReady = false
                self.log("State: unknown")
            }
        }

        newConnection.start(queue: queue)
        log("Connecting to \(host):\(port)")
    }

    func send(_ data: Data) {
        guard let connection else {
            log("Send skipped: no connection")
            return
        }

        guard !data.isEmpty else {
            log("Send skipped: empty payload")
            return
        }

        guard isReady else {
            log("Send skipped: connection not ready")
            return
        }

        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error {
                self?.log("Send error: \(error.localizedDescription)")
            } else {
                self?.log("Sent \(data.count) bytes")
            }
        })
    }

    func disconnect() {
        if let connection {
            connection.cancel()
            self.connection = nil
        }

        isReady = false
        log("Disconnected")
    }

    private func receive() {
        guard let connection else { return }

        connection.receive(minimumIncompleteLength: 1, maximumLength: 65535) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let error {
                self.log("Receive error: \(error.localizedDescription)")
                return
            }

            if let data, !data.isEmpty {
                self.log("Received \(data.count) bytes")
            } else {
                self.log("Receive: empty payload")
            }

            if isComplete {
                self.log("Receive completed by remote peer")
                self.isReady = false
                return
            }

            self.receive()
        }
    }

    private func log(_ message: String) {
        NSLog("[MyVPN][TunnelConnection] %@", message)
    }
}
