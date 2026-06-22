import Foundation
import NetworkExtension

final class PacketTunnelRuntime {

    private let rawConfig: String
    private let packetFlow: NEPacketTunnelFlow
    private let tunnelProvider: NEPacketTunnelProvider
    private let singBoxRuntime: SingBoxRuntime

    private var isRunning = false
    private var runtimeTask: Task<Void, Never>?

    init(
        configuration: String,
        packetFlow: NEPacketTunnelFlow,
        tunnelProvider: NEPacketTunnelProvider
    ) {
        self.rawConfig = configuration
        self.packetFlow = packetFlow
        self.tunnelProvider = tunnelProvider

        self.singBoxRuntime = SingBoxRuntime(
            configuration: configuration,
            packetFlow: packetFlow,
            tunnelProvider: tunnelProvider
        )
    }

    func start() {
        guard !isRunning else { return }

        isRunning = true

        log("Runtime start")
        log("Config size: \(rawConfig.count) chars")

        runtimeTask = Task { [weak self] in
            await self?.run()
        }
    }

    func stop() {
        guard isRunning else { return }

        isRunning = false
        runtimeTask?.cancel()
        runtimeTask = nil

        singBoxRuntime.stop()

        log("Runtime stop")
    }

    private func run() async {
        await singBoxRuntime.start()

        guard isRunning, !Task.isCancelled else { return }

        switch singBoxRuntime.state {
        case .running:
            log("SingBox runtime is running")

        case .failed(let message):
            log("SingBox runtime failed: \(message)")

        case .idle, .starting, .stopped:
            log("SingBox runtime did not reach running state: \(describe(singBoxRuntime.state))")
        }
    }

    private func describe(_ state: SingBoxRuntime.RuntimeState) -> String {
        switch state {
        case .idle:
            return "idle"
        case .starting:
            return "starting"
        case .running:
            return "running"
        case .failed(let message):
            return "failed(\(message))"
        case .stopped:
            return "stopped"
        }
    }

    private func log(_ message: String) {
        NSLog("[MyVPN][Runtime] %@", message)
    }
}
