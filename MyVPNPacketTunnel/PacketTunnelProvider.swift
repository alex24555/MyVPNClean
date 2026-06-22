import Foundation
import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider {

    private var runtime: PacketTunnelRuntime?

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        log("startTunnel called")

        guard let configString = options?["config"] as? String else {
            let error = makeError(
                code: -1,
                message: "No config received from VPNManager"
            )

            log("startTunnel failed: \(error.localizedDescription)")
            completionHandler(error)
            return
        }

        let trimmedConfig = configString.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedConfig.isEmpty else {
            let error = makeError(
                code: -2,
                message: "Received empty config"
            )

            log("startTunnel failed: \(error.localizedDescription)")
            completionHandler(error)
            return
        }

        log("Received config length: \(trimmedConfig.count)")
        log("Received config preview: \(preview(trimmedConfig))")

        let settings = makeTunnelNetworkSettings()

        log("Applying tunnel network settings...")

        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else {
                let providerError = Self.makeStaticError(
                    code: -3,
                    message: "PacketTunnelProvider deallocated"
                )

                NSLog("[MyVPN][PacketTunnelProvider] startTunnel failed: %@", providerError.localizedDescription)
                completionHandler(providerError)
                return
            }

            if let error = error {
                self.log("setTunnelNetworkSettings failed: \(error.localizedDescription)")
                completionHandler(error)
                return
            }

            self.log("Tunnel network settings applied")
            self.startRuntime(
                configuration: trimmedConfig,
                completionHandler: completionHandler
            )
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        log("stopTunnel called, reason=\(reason.rawValue), description=\(stopReasonDescription(reason))")

        runtime?.stop()
        runtime = nil

        log("Tunnel stopped")
        completionHandler()
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        log("Provider sleep called")
        completionHandler()
    }

    override func wake() {
        log("Provider wake called")
    }

    private func startRuntime(
        configuration: String,
        completionHandler: @escaping (Error?) -> Void
    ) {
        log("Creating PacketTunnelRuntime...")

        let runtime = PacketTunnelRuntime(
            configuration: configuration,
            packetFlow: packetFlow,
            tunnelProvider: self
        )

        self.runtime = runtime

        log("Starting PacketTunnelRuntime...")
        runtime.start()

        log("Tunnel started")
        completionHandler(nil)
    }

    private func makeTunnelNetworkSettings() -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(
            tunnelRemoteAddress: "1.1.1.1"
        )

        let ipv4 = NEIPv4Settings(
            addresses: ["172.19.0.2"],
            subnetMasks: ["255.255.255.252"]
        )

        ipv4.includedRoutes = [
            NEIPv4Route.default()
        ]

        settings.ipv4Settings = ipv4

        let ipv6 = NEIPv6Settings(
            addresses: ["fdfe:dcba:9876::2"],
            networkPrefixLengths: [126]
        )

        ipv6.includedRoutes = [
            NEIPv6Route.default()
        ]

        settings.ipv6Settings = ipv6

        settings.dnsSettings = NEDNSSettings(
            servers: [
                "1.1.1.1",
                "8.8.8.8"
            ]
        )

        log("Prepared network settings: IPv4=172.19.0.2/30, IPv6=fdfe:dcba:9876::2/126, DNS=1.1.1.1,8.8.8.8")

        return settings
    }

    private func preview(_ value: String) -> String {
        let singleLine = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")

        let maxLength = 700

        if singleLine.count <= maxLength {
            return singleLine
        }

        return String(singleLine.prefix(maxLength)) + "..."
    }

    private func log(_ message: String) {
        NSLog("[MyVPN][PacketTunnelProvider] %@", message)
    }

    private func makeError(
        code: Int,
        message: String
    ) -> NSError {
        NSError(
            domain: "MyVPN.PacketTunnelProvider",
            code: code,
            userInfo: [
                NSLocalizedDescriptionKey: message
            ]
        )
    }

    private static func makeStaticError(
        code: Int,
        message: String
    ) -> NSError {
        NSError(
            domain: "MyVPN.PacketTunnelProvider",
            code: code,
            userInfo: [
                NSLocalizedDescriptionKey: message
            ]
        )
    }

    private func stopReasonDescription(_ reason: NEProviderStopReason) -> String {
        switch reason {
        case .none:
            return "none"

        case .userInitiated:
            return "userInitiated"

        case .providerFailed:
            return "providerFailed"

        case .noNetworkAvailable:
            return "noNetworkAvailable"

        case .unrecoverableNetworkChange:
            return "unrecoverableNetworkChange"

        case .providerDisabled:
            return "providerDisabled"

        case .authenticationCanceled:
            return "authenticationCanceled"

        case .configurationFailed:
            return "configurationFailed"

        case .idleTimeout:
            return "idleTimeout"

        case .configurationDisabled:
            return "configurationDisabled"

        case .configurationRemoved:
            return "configurationRemoved"

        case .superceded:
            return "superceded"

        case .userLogout:
            return "userLogout"

        case .userSwitch:
            return "userSwitch"

        case .connectionFailed:
            return "connectionFailed"

        case .sleep:
            return "sleep"

        case .appUpdate:
            return "appUpdate"

        @unknown default:
            return "unknown"
        }
    }
}
