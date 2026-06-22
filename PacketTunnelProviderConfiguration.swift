import Foundation

struct PacketTunnelProviderConfiguration: Codable, Equatable {
    let profileID: String?
    let profileName: String
    let rawConfig: String
    let normalizedConfig: String
    let kind: String
    let endpoint: Endpoint
    let policy: Policy

    struct Endpoint: Codable, Equatable {
        let address: String
        let port: Int?
        let uuid: String?
        let security: String?
        let transportType: String?
        let sni: String?
        let remark: String?
    }

    struct Policy: Codable, Equatable {
        let routingMode: String
        let directDomains: [String]
        let enableDirectForIP: Bool
        let enableDNSHandling: Bool
    }

    init(
        profileID: String?,
        profileName: String,
        rawConfig: String,
        normalizedConfig: String,
        kind: String,
        endpoint: Endpoint,
        policy: Policy
    ) {
        self.profileID = profileID
        self.profileName = profileName
        self.rawConfig = rawConfig
        self.normalizedConfig = normalizedConfig
        self.kind = kind
        self.endpoint = endpoint
        self.policy = policy
    }

    init?(providerDictionary: [String: Any]) {
        guard
            let profileName = providerDictionary["profileName"] as? String,
            let rawConfig = providerDictionary["rawConfig"] as? String,
            let normalizedConfig = providerDictionary["normalizedConfig"] as? String,
            let kind = providerDictionary["kind"] as? String,
            let endpointDictionary = providerDictionary["endpoint"] as? [String: Any],
            let address = endpointDictionary["address"] as? String
        else {
            return nil
        }

        let port: Int?
        if let intPort = endpointDictionary["port"] as? Int {
            port = intPort
        } else if let numberPort = endpointDictionary["port"] as? NSNumber {
            port = numberPort.intValue
        } else {
            port = nil
        }

        let endpoint = Endpoint(
            address: address,
            port: port,
            uuid: endpointDictionary["uuid"] as? String,
            security: endpointDictionary["security"] as? String,
            transportType: endpointDictionary["transportType"] as? String,
            sni: endpointDictionary["sni"] as? String,
            remark: endpointDictionary["remark"] as? String
        )

        let defaultPolicy = Policy(
            routingMode: "split",
            directDomains: [],
            enableDirectForIP: false,
            enableDNSHandling: true
        )

        let policy: Policy
        if let policyDictionary = providerDictionary["policy"] as? [String: Any] {
            policy = Policy(
                routingMode: (policyDictionary["routingMode"] as? String) ?? defaultPolicy.routingMode,
                directDomains: (policyDictionary["directDomains"] as? [String]) ?? defaultPolicy.directDomains,
                enableDirectForIP: (policyDictionary["enableDirectForIP"] as? Bool) ?? defaultPolicy.enableDirectForIP,
                enableDNSHandling: (policyDictionary["enableDNSHandling"] as? Bool) ?? defaultPolicy.enableDNSHandling
            )
        } else if let legacyRouting = providerDictionary["routing"] as? [String: Any] {
            policy = Policy(
                routingMode: (legacyRouting["mode"] as? String) ?? defaultPolicy.routingMode,
                directDomains: (legacyRouting["directDomains"] as? [String]) ?? defaultPolicy.directDomains,
                enableDirectForIP: (legacyRouting["enableDirectForIP"] as? Bool) ?? defaultPolicy.enableDirectForIP,
                enableDNSHandling: (legacyRouting["enableDNSHandling"] as? Bool) ?? defaultPolicy.enableDNSHandling
            )
        } else {
            policy = defaultPolicy
        }

        self.profileID = providerDictionary["profileID"] as? String
        self.profileName = profileName
        self.rawConfig = rawConfig
        self.normalizedConfig = normalizedConfig
        self.kind = kind
        self.endpoint = endpoint
        self.policy = policy
    }

    func asProviderDictionary() -> [String: Any] {
        var result: [String: Any] = [
            "profileName": profileName,
            "rawConfig": rawConfig,
            "normalizedConfig": normalizedConfig,
            "kind": kind,
            "endpoint": [
                "address": endpoint.address,
                "port": endpoint.port as Any,
                "uuid": endpoint.uuid as Any,
                "security": endpoint.security as Any,
                "transportType": endpoint.transportType as Any,
                "sni": endpoint.sni as Any,
                "remark": endpoint.remark as Any
            ],
            "policy": [
                "routingMode": policy.routingMode,
                "directDomains": policy.directDomains,
                "enableDirectForIP": policy.enableDirectForIP,
                "enableDNSHandling": policy.enableDNSHandling
            ]
        ]

        if let profileID {
            result["profileID"] = profileID
        }

        return result
    }
}
