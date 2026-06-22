import Foundation
#if canImport(NetworkExtension)
import NetworkExtension
#endif

final class PacketTunnelEngine: VPNEngine {

    enum EngineStatus: Equatable {
        case idle
        case prepared
        case managerLoading
        case managerReady
        case starting
        case running
        case stopping
        case stopped
        case failed
    }

    private(set) var status: EngineStatus = .idle
    private var lastConfiguration: PreparedVPNConfiguration?

    #if canImport(NetworkExtension)
    private var manager: NETunnelProviderManager?

    private var providerBundleIdentifier: String? {
        let engineKind =
        UserDefaults.standard.string(
            forKey: "vpnEngineKind"
        ) ?? "packetTunnel"

        switch engineKind {
        case "packetTunnelVKTurn":
            return "alex.MyVPNClean.MyVPNVKTurnTunnel"

        default:
            return "alex.MyVPNClean.MyVPNPacketTunnel"
        }
    }
    #endif

    func start(with configuration: PreparedVPNConfiguration) async throws {
        if let validationError = validate(configuration) {
            status = .failed
            try await log(
                "Engine validation failed: \(validationError.localizedDescription)",
                level: .error,
                category: .engine
            )
            throw validationError
        }

        lastConfiguration = configuration
        status = .prepared

        try await log(
            "Engine start requested. Profile: \(configuration.profileName)",
            category: .engine
        )

        logPreparedPolicy(configuration.policy)

        #if canImport(NetworkExtension)
        try await ensurePacketTunnelReadiness()
        try await prepareManagerIfNeeded(with: configuration)

        status = .starting

        do {
            try await startTunnelIfPossible(with: configuration)

            try await log(
                "Tunnel start requested with options payload",
                category: .packetTunnel
            )

            status = .running

            try await log(
                "Tunnel is running",
                category: .packetTunnel
            )
        } catch {
            status = .failed

            try await log(
                "Tunnel start failed: \(error.localizedDescription)",
                level: .error,
                category: .packetTunnel
            )

            throw error
        }
        #else
        status = .failed

        try await log(
            "PacketTunnelEngine is unavailable on this build because NetworkExtension is not available.",
            level: .error,
            category: .packetTunnel
        )

        throw VPNEngineError.startFailed("Packet Tunnel is unavailable on this build")
        #endif
    }

    func stop() async throws {
        try await log(
            "Engine stop requested",
            category: .engine
        )

        status = .stopping

        do {
            #if canImport(NetworkExtension)
            try await refreshManagerForStopIfNeeded()
            try await stopTunnelIfPossible()
            #endif

            status = .stopped
            lastConfiguration = nil

            try await log(
                "Tunnel stopped",
                category: .packetTunnel
            )
        } catch {
            status = .failed

            try await log(
                "Tunnel stop failed: \(error.localizedDescription)",
                level: .error,
                category: .packetTunnel
            )

            throw error
        }
    }

    private func logPreparedPolicy(_ policy: PreparedTunnelPolicy) {
        Task {
            try? await log(
                """
                Tunnel policy prepared. \
                routingMode: \(policy.routingMode.rawValue), \
                directDomains: \(policy.directDomains.count), \
                enableDirectForIP: \(policy.enableDirectForIP), \
                enableDNSHandling: \(policy.enableDNSHandling)
                """,
                category: .engine
            )
        }
    }

    private func validate(_ configuration: PreparedVPNConfiguration) -> VPNEngineError? {
        let engineKind =
        UserDefaults.standard.string(
            forKey: "vpnEngineKind"
        ) ?? "packetTunnel"

        if engineKind == "packetTunnelVKTurn" {
            let privateKey = VKTurnSettings.privateKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let peerPublicKey = VKTurnSettings.peerPublicKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let peerAddress = VKTurnSettings.peerAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            let vkLink = VKTurnSettings.vkLink.trimmingCharacters(in: .whitespacesAndNewlines)

            if privateKey.isEmpty {
                return .startFailed("VK TURN private key is missing")
            }

            if peerPublicKey.isEmpty {
                return .startFailed("VK TURN peer public key is missing")
            }

            if peerAddress.isEmpty {
                return .startFailed("VK TURN proxy server is missing")
            }

            if vkLink.isEmpty {
                return .startFailed("VK TURN call link is missing")
            }

            return nil
        }

        let server = configuration.serverAddress.trimmingCharacters(in: .whitespacesAndNewlines)

        if configuration.kind == .vless {
            if server.isEmpty {
                return .invalidConfiguration
            }

            guard let port = configuration.port, port > 0 else {
                return .startFailed("Invalid port")
            }

            let uuid = configuration.uuid?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if uuid.isEmpty {
                return .startFailed("Missing UUID")
            }
        }

        return nil
    }

    #if canImport(NetworkExtension)
    private func ensurePacketTunnelReadiness() async throws {
        guard let providerBundleIdentifier,
              !providerBundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            status = .failed

            try await log(
                "Packet Tunnel extension is not configured yet. providerBundleIdentifier is missing.",
                level: .error,
                category: .packetTunnel
            )

            throw VPNEngineError.startFailed("Packet Tunnel extension is not configured yet")
        }
    }

    private func prepareManagerIfNeeded(with configuration: PreparedVPNConfiguration) async throws {
        status = .managerLoading

        try await log(
            "Loading or creating tunnel manager",
            category: .manager
        )

        let loadedManager = try await loadOrCreateManager()
        let providerConfiguration = makeProviderConfiguration(from: configuration)

        let proto = NETunnelProviderProtocol()
        proto.serverAddress = providerServerAddress(for: configuration)
        proto.providerBundleIdentifier = providerBundleIdentifier
        proto.providerConfiguration = providerConfiguration
        proto.disconnectOnSleep = false

        loadedManager.protocolConfiguration = proto

        loadedManager.localizedDescription =
        providerBundleIdentifier?.contains(
            "MyVPNVKTurnTunnel"
        ) == true
        ? "MyVPN VK TURN"
        : "MyVPN"

        loadedManager.isEnabled = true

        do {
            try await saveToPreferences(loadedManager)
            try await loadFromPreferences(loadedManager)

            try await log(
                "Manager prepared successfully",
                category: .manager
            )
        } catch {
            status = .failed

            try await log(
                "Manager prepare failed: \(error.localizedDescription)",
                level: .error,
                category: .manager
            )

            throw VPNEngineError.startFailed("Manager prepare failed: \(error.localizedDescription)")
        }

        manager = loadedManager
        status = .managerReady
    }

    private func providerServerAddress(for configuration: PreparedVPNConfiguration) -> String {
        let engineKind =
        UserDefaults.standard.string(
            forKey: "vpnEngineKind"
        ) ?? "packetTunnel"

        if engineKind == "packetTunnelVKTurn" {
            let peerAddress = VKTurnSettings.peerAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            let host = peerAddress.components(separatedBy: ":").first ?? peerAddress
            return host.isEmpty ? "VK TURN" : host
        }

        return configuration.serverAddress
    }

    private func refreshManagerForStopIfNeeded() async throws {
        let managers = try await loadAllManagers()

        if let matchingManager = managers.first(where: { candidate in
            guard let proto = candidate.protocolConfiguration as? NETunnelProviderProtocol else {
                return false
            }
            return proto.providerBundleIdentifier == providerBundleIdentifier
        }) {
            manager = matchingManager

            try await log(
                "Manager refreshed for stop",
                category: .manager
            )
            return
        }

        if let first = managers.first {
            manager = first

            try await log(
                "No exact manager match found; using first available manager for stop",
                level: .warning,
                category: .manager
            )
            return
        }

        manager = nil

        try await log(
            "No managers found while preparing stop",
            level: .warning,
            category: .manager
        )
    }

    private func startTunnelIfPossible(with configuration: PreparedVPNConfiguration) async throws {
        guard let manager else {
            throw VPNEngineError.startFailed("Manager not ready")
        }

        guard manager.isEnabled else {
            throw VPNEngineError.startFailed("Tunnel manager is disabled")
        }

        guard let session = manager.connection as? NETunnelProviderSession else {
            throw VPNEngineError.startFailed("Invalid session")
        }

        let options = makeTunnelOptions(from: configuration)

        do {
            try session.startVPNTunnel(options: options)
        } catch {
            throw VPNEngineError.startFailed("Failed to start VPN tunnel: \(error.localizedDescription)")
        }
    }

    private func stopTunnelIfPossible() async throws {
        guard let manager else {
            try await log(
                "Stop requested but manager is nil",
                level: .warning,
                category: .packetTunnel
            )
            return
        }

        guard let session = manager.connection as? NETunnelProviderSession else {
            throw VPNEngineError.stopFailed("Invalid session during stop")
        }

        try await log(
            "Stopping tunnel via NETunnelProviderSession",
            category: .packetTunnel
        )

        session.stopVPNTunnel()

        try await log(
            "stopVPNTunnel() called",
            category: .packetTunnel
        )
    }

    private func makeProviderConfiguration(from configuration: PreparedVPNConfiguration) -> [String: Any] {
        let engineKind =
        UserDefaults.standard.string(
            forKey: "vpnEngineKind"
        ) ?? "packetTunnel"

        if engineKind == "packetTunnelVKTurn" {
            let peerAddress = VKTurnSettings.peerAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            let dnsServers = VKTurnSettings.dnsServers.trimmingCharacters(in: .whitespacesAndNewlines)
            let numConnections = max(1, VKTurnSettings.numConnections)

            func wgKeyHex(_ input: String) -> String {
                let cleaned = input
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "-", with: "+")
                    .replacingOccurrences(of: "_", with: "/")

                guard let data = Data(
                    base64Encoded: cleaned,
                    options: [.ignoreUnknownCharacters]
                ) else {
                    return cleaned
                }

                return data.map {
                    String(format: "%02x", $0)
                }.joined()
            }

            let wgConfig = """
private_key=\(wgKeyHex(VKTurnSettings.privateKey))
replace_peers=true
public_key=\(wgKeyHex(VKTurnSettings.peerPublicKey))
endpoint=\(peerAddress)
persistent_keepalive_interval=25
allowed_ip=0.0.0.0/0
"""

            let proxyConfig = """
{
  "vk_link":"\(VKTurnSettings.vkLink.trimmingCharacters(in: .whitespacesAndNewlines))",
  "peer_addr":"\(peerAddress)",
  "use_dtls":true,
  "use_udp":false,
  "use_wrap":false,
  "use_srtp":false,
  "num_conns":\(numConnections)
}
"""

            return [
                "wg_config": wgConfig,
                "proxy_config": proxyConfig,
                "tunnel_address": VKTurnSettings.tunnelAddress,
                "dns_servers": dnsServers.isEmpty ? "1.1.1.1" : dnsServers,
                "mtu": "1280"
            ]
        }

        return [
            "config": configuration.normalizedConfig,
            "profileName": configuration.profileName,
            "routingMode": configuration.policy.routingMode.rawValue,
            "manualStart": true
        ]
    }

    private func makeTunnelOptions(from configuration: PreparedVPNConfiguration) -> [String: NSObject] {
        let engineKind =
        UserDefaults.standard.string(
            forKey: "vpnEngineKind"
        ) ?? "packetTunnel"

        if engineKind == "packetTunnelVKTurn" {
            return [
                "manualStart": NSNumber(value: true)
            ]
        }

        var options: [String: NSObject] = [:]

        options["config"] =
        NSString(string: configuration.normalizedConfig)

        options["profileName"] =
        NSString(string: configuration.profileName)

        options["manualStart"] =
        NSNumber(value: true)

        options["systemProxyEnabled"] =
        NSNumber(value: true)

        options["excludeDefaultRoute"] =
        NSNumber(value: false)

        options["autoRouteUseSubRangesByDefault"] =
        NSNumber(value: false)

        options["excludeAPNsRoute"] =
        NSNumber(value: false)

        options["includeAllNetworks"] =
        NSNumber(value: false)

        return options
    }

    private func loadOrCreateManager() async throws -> NETunnelProviderManager {
        let managers = try await loadAllManagers()

        if let existing = managers.first(where: { candidate in
            guard let proto = candidate.protocolConfiguration as? NETunnelProviderProtocol else {
                return false
            }
            return proto.providerBundleIdentifier == providerBundleIdentifier
        }) {
            return existing
        }

        return NETunnelProviderManager()
    }

    private func loadAllManagers() async throws -> [NETunnelProviderManager] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[NETunnelProviderManager], Error>) in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: managers ?? [])
                }
            }
        }
    }

    private func saveToPreferences(_ manager: NETunnelProviderManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.saveToPreferences { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func loadFromPreferences(_ manager: NETunnelProviderManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.loadFromPreferences { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }
    #else
    private func prepareManagerIfNeeded(with configuration: PreparedVPNConfiguration) async throws {
        _ = configuration
        throw VPNEngineError.startFailed("NetworkExtension is unavailable on this build")
    }

    private func startTunnelIfPossible(with configuration: PreparedVPNConfiguration) async throws {
        _ = configuration
        throw VPNEngineError.startFailed("NetworkExtension is unavailable on this build")
    }

    private func stopTunnelIfPossible() async throws {}
    #endif

    private func log(
        _ message: String,
        level: VPNDebugLog.Level = .info,
        category: VPNDebugLog.Category
    ) async throws {
        await MainActor.run {
            VPNDebugLog.shared.log(
                message,
                level: level,
                category: category
            )
        }
    }
}
