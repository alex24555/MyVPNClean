import Foundation

struct PacketTunnelConfigurationBuilder {

    static func build(
        from configuration: PreparedVPNConfiguration,
        transportMode: PacketTunnelTransportMode = .default
    ) -> [String: Any] {

        let providerConfiguration = PacketTunnelProviderConfiguration(
            profileID: configuration.profileID?.uuidString,
            profileName: configuration.profileName,
            rawConfig: configuration.rawConfig,
            normalizedConfig: configuration.normalizedConfig,
            kind: configuration.kind.rawValue,
            endpoint: .init(
                address: configuration.serverAddress,
                port: configuration.port,
                uuid: configuration.uuid,
                security: configuration.security,
                transportType: configuration.transportType,
                sni: configuration.sni,
                remark: configuration.remark
            ),
            policy: .init(
                routingMode: configuration.policy.routingMode.rawValue,
                directDomains: configuration.policy.directDomains,
                enableDirectForIP: configuration.policy.enableDirectForIP,
                enableDNSHandling: configuration.policy.enableDNSHandling
            )
        )

        var result = providerConfiguration.asProviderDictionary()

        result["transportMode"] = transportMode.rawValue

        return result
    }
}
