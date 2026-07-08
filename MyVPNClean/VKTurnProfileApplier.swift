import Foundation

enum VKTurnProfileApplier {
    static func apply(_ profile: VPNProfile) -> Bool {
        guard profile.kind == .wireguard,
              profile.remark == "VK TURN",
              let data = profile.rawConfig.data(using: .utf8),
              let setup = try? JSONDecoder().decode(RemoteVKTurnSetup.self, from: data),
              setup.engine == "packetTunnelVKTurn" else {
            return false
        }

        VKTurnSettings.vkLink = setup.vkLink
        VKTurnSettings.peerAddress = setup.peerAddress
        VKTurnSettings.privateKey = setup.privateKey
        VKTurnSettings.peerPublicKey = setup.peerPublicKey
        VKTurnSettings.tunnelAddress = setup.tunnelAddress ?? "10.66.66.2/32"
        VKTurnSettings.dnsServers = setup.dnsServers ?? "1.1.1.1"
        VKTurnSettings.numConnections = setup.numConnections ?? 20

        UserDefaults.standard.set(
            "packetTunnelVKTurn",
            forKey: "vpnEngineKind"
        )

        return true
    }
}
