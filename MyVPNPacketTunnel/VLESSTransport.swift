import Foundation
import NetworkExtension

final class VLESSTransport {

    private let configuration: String
    private let packetFlow: NEPacketTunnelFlow

    init(
        configuration: String,
        packetFlow: NEPacketTunnelFlow
    ) {
        self.configuration = configuration
        self.packetFlow = packetFlow
    }

    func start() {
        NSLog("[MyVPN][VLESSTransport] start() placeholder")
    }

    func stop() {
        NSLog("[MyVPN][VLESSTransport] stop() placeholder")
    }
}
