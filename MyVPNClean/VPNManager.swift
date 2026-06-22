import Foundation
#if canImport(NetworkExtension)
import NetworkExtension
#endif

enum VPNRoutingMode: String, Equatable, Codable {
    case split
    case full
}

struct PreparedTunnelPolicy: Equatable, Codable {
    let routingMode: VPNRoutingMode
    let directDomains: [String]
    let directDomainSuffixes: [String]
    let directIPCIDRs: [String]
    let excludedDomains: [String]
    let enableDirectForIP: Bool
    let enableDNSHandling: Bool

    static var `default`: PreparedTunnelPolicy {
        let domains = VPNRoutingRules.allDirectDomains

        return PreparedTunnelPolicy(
            routingMode: .split,
            directDomains: domains,
            directDomainSuffixes: domains,
            directIPCIDRs: [],
            excludedDomains: [],
            enableDirectForIP: false,
            enableDNSHandling: true
        )
    }
}

struct PreparedVPNConfiguration: Equatable {
    let profileID: UUID?
    let profileName: String
    let rawConfig: String
    let normalizedConfig: String
    let kind: TunnelConfiguration.Kind
    let serverAddress: String
    let port: Int?
    let uuid: String?
    let security: String?
    let transportType: String?
    let sni: String?
    let remark: String?
    let policy: PreparedTunnelPolicy

    static func build(from profile: VPNProfile) -> PreparedVPNConfiguration? {
        let engineKind = UserDefaults.standard.string(forKey: "vpnEngineKind") ?? "packetTunnel"

        if engineKind == "packetTunnelVKTurn" {
            return PreparedVPNConfiguration(
                profileID: profile.id,
                profileName: "VK TURN",
                rawConfig: profile.rawConfig,
                normalizedConfig: profile.normalizedConfig,
                kind: profile.kind,
                serverAddress: VKTurnSettings.peerAddress,
                port: nil,
                uuid: nil,
                security: nil,
                transportType: nil,
                sni: nil,
                remark: "VK TURN",
                policy: .default
            )
        }

        guard let parsed = TunnelConfiguration.build(from: profile.rawConfig) else {
            return nil
        }

        let resolvedServerAddress: String

        if parsed.kind == .wireguard {
            resolvedServerAddress = TunnelConfiguration.wireGuardEndpoint(
                from: parsed.rawConfig
            )
        } else {
            resolvedServerAddress = parsed.vless?.address ?? profile.serverAddress
        }

        return PreparedVPNConfiguration(
            profileID: profile.id,
            profileName: profile.displayName,
            rawConfig: parsed.rawConfig,
            normalizedConfig: parsed.normalizedConfig,
            kind: parsed.kind,
            serverAddress: resolvedServerAddress,
            port: parsed.vless?.port,
            uuid: parsed.vless?.uuid,
            security: emptyToNil(parsed.vless?.security),
            transportType: emptyToNil(parsed.vless?.transportType),
            sni: emptyToNil(parsed.vless?.sni),
            remark: emptyToNil(parsed.vless?.remark),
            policy: .default
        )
    }

    private static func emptyToNil(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }

        return trimmed
    }
}

protocol VPNEngine {
    func start(with configuration: PreparedVPNConfiguration) async throws
    func stop() async throws
}

enum VPNEngineError: LocalizedError {
    case invalidConfiguration
    case startFailed(String)
    case stopFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "Invalid VPN configuration"
        case .startFailed(let message):
            return message
        case .stopFailed(let message):
            return message
        }
    }
}

final class FakeVPNEngine: VPNEngine {
    func start(with configuration: PreparedVPNConfiguration) async throws {
        _ = configuration
        try await Task.sleep(nanoseconds: 300_000_000)
    }

    func stop() async throws {
        try await Task.sleep(nanoseconds: 200_000_000)
    }
}

enum VPNEngineKind: String {
    case fake
    case packetTunnel
    case packetTunnelVKTurn
}

enum VPNEngineFactory {
    static func makeEngine(for kind: VPNEngineKind) -> VPNEngine {
        switch kind {
        case .fake:
            return FakeVPNEngine()

        case .packetTunnel,
             .packetTunnelVKTurn:
            return PacketTunnelEngine()
        }
    }
}

@MainActor
final class VPNManager: ObservableObject {
    static let shared = VPNManager()

    enum ConnectionState: String {
        case idle
        case preparing
        case ready
        case connecting
        case connected
        case disconnecting
        case disconnected
        case failed
    }

    @Published private(set) var state: ConnectionState = .idle
    @Published private(set) var lastError: String?
    @Published private(set) var lastPreparedConfiguration: PreparedVPNConfiguration?

    private let debugLog = VPNDebugLog.shared
    private let engineKindDefaultsKey = "vpnEngineKind"

    private var engineInstance: VPNEngine?

    private var engine: VPNEngine {
        if let engineInstance {
            return engineInstance
        }

        let newEngine = VPNEngineFactory.makeEngine(for: selectedEngineKind)
        engineInstance = newEngine
        return newEngine
    }

    private var selectedEngineKind: VPNEngineKind {
        let rawValue = UserDefaults.standard.string(forKey: engineKindDefaultsKey)
        return VPNEngineKind(rawValue: rawValue ?? "") ?? .packetTunnel
    }

    private var selectedProviderBundleIdentifier: String {
        switch selectedEngineKind {
        case .packetTunnelVKTurn:
            return "alex.MyVPNClean.MyVPNVKTurnTunnel"

        case .fake,
             .packetTunnel:
            return "alex.MyVPNClean.MyVPNPacketTunnel"
        }
    }

    private init() {
        debugLog.log(
            "VPNManager initialized with engine: \(selectedEngineKind.rawValue)",
            category: .manager
        )
    }

    func refreshStateFromSystem() async {
        #if canImport(NetworkExtension)
        do {
            let managers = try await loadAllTunnelManagers()

            guard let manager = managers.first(where: { candidate in
                guard let proto = candidate.protocolConfiguration as? NETunnelProviderProtocol else {
                    return false
                }

                return proto.providerBundleIdentifier == selectedProviderBundleIdentifier
            }) else {
                state = .disconnected

                debugLog.log(
                    "System VPN state synced: disconnected. Engine: \(selectedEngineKind.rawValue)",
                    category: .manager
                )

                return
            }

            switch manager.connection.status {
            case .connected:
                state = .connected

            case .connecting, .reasserting:
                state = .connecting

            case .disconnecting:
                state = .disconnecting

            case .disconnected, .invalid:
                state = .disconnected

            @unknown default:
                state = .disconnected
            }

            debugLog.log(
                "System VPN state synced: \(state.rawValue). Engine: \(selectedEngineKind.rawValue)",
                category: .manager
            )
        } catch {
            debugLog.log(
                "Failed to sync VPN state: \(error.localizedDescription)",
                level: .error,
                category: .manager
            )
        }
        #endif
    }

    func startVPN(using profile: VPNProfile) async {
        lastError = nil

        debugLog.log(
            "Start requested for profile: \(profile.displayName). Engine: \(selectedEngineKind.rawValue)",
            category: .manager
        )

        guard let prepared = PreparedVPNConfiguration.build(from: profile) else {
            state = .failed
            lastError = "Invalid config"
            return
        }

        await startVPN(using: prepared)
    }

    func stopVPN() async {
        await refreshStateFromSystem()

        debugLog.log(
            "Stop requested. Current state: \(state.rawValue). Engine: \(selectedEngineKind.rawValue)",
            category: .manager
        )

        switch state {
        case .idle, .disconnected:
            state = .disconnected
            engineInstance = nil
            return

        default:
            break
        }

        state = .disconnecting

        do {
            try await engine.stop()
            try? await Task.sleep(nanoseconds: 500_000_000)

            await refreshStateFromSystem()

            if state == .disconnecting {
                state = .disconnected
            }

            engineInstance = nil
        } catch {
            state = .failed
            lastError = error.localizedDescription
        }
    }

    func clearError() {
        lastError = nil

        if state == .failed {
            state = lastPreparedConfiguration == nil ? .disconnected : .ready
        }
    }

    private func startVPN(using prepared: PreparedVPNConfiguration) async {
        lastPreparedConfiguration = prepared

        if prepared.kind == .wireguard {
            state = .failed
            lastError = "WireGuard engine is not ready yet"
            debugLog.log(
                "Blocked WireGuard profile start: separate WireGuard engine is not implemented yet",
                category: .manager
            )
            return
        }

        state = .connecting

        do {
            try await engine.start(with: prepared)

            await waitForRealConnection(timeoutSeconds: 120)
        } catch {
            state = .failed
            lastError = error.localizedDescription
            lastPreparedConfiguration = prepared
        }
    }

    private func waitForRealConnection(timeoutSeconds: Int) async {
        for _ in 0..<timeoutSeconds {
            await refreshStateFromSystem()

            if state == .connected {
                return
            }

            if state == .failed || state == .disconnected {
                return
            }

            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        state = .failed
        lastError = "VPN tunnel stuck in connecting state"

        debugLog.log(
            "VPN tunnel stuck in connecting state after \(timeoutSeconds)s. Engine: \(selectedEngineKind.rawValue)",
            level: .error,
            category: .manager
        )
    }

    #if canImport(NetworkExtension)
    private func loadAllTunnelManagers() async throws -> [NETunnelProviderManager] {
        try await withCheckedThrowingContinuation { continuation in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: managers ?? [])
                }
            }
        }
    }
    #endif
}
