import Foundation

struct VPNProfile: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var rawConfig: String
    var normalizedConfig: String
    var kind: TunnelConfiguration.Kind
    var serverAddress: String
    var remark: String
    var isSelected: Bool
    var createdAt: Date
    var updatedAt: Date

    // Subscription metadata
    var subscriptionURL: String?
    var subscriptionName: String?
    var subscriptionIndex: Int?

    init(
        id: UUID = UUID(),
        name: String,
        rawConfig: String,
        normalizedConfig: String,
        kind: TunnelConfiguration.Kind,
        serverAddress: String,
        remark: String,
        isSelected: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        subscriptionURL: String? = nil,
        subscriptionName: String? = nil,
        subscriptionIndex: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.rawConfig = rawConfig
        self.normalizedConfig = normalizedConfig
        self.kind = kind
        self.serverAddress = serverAddress
        self.remark = remark
        self.isSelected = isSelected
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.subscriptionURL = subscriptionURL
        self.subscriptionName = subscriptionName
        self.subscriptionIndex = subscriptionIndex
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }

        if !remark.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return remark.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if !serverAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "\(kind.rawValue.uppercased()) \(serverAddress)"
        }

        return kind.rawValue.uppercased()
    }

    var subtitle: String {
        let address = serverAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = remark.trimmingCharacters(in: .whitespacesAndNewlines)

        if let subscriptionName,
           !subscriptionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if !address.isEmpty {
                return "\(subscriptionName) • \(address)"
            }

            return subscriptionName
        }

        if !address.isEmpty, !note.isEmpty, note != name {
            return "\(address) • \(note)"
        }

        if !address.isEmpty {
            return address
        }

        if !note.isEmpty, note != name {
            return note
        }

        return kind.rawValue.uppercased()
    }

    var isSubscriptionProfile: Bool {
        subscriptionURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    static func build(
        from configuration: TunnelConfiguration,
        customName: String? = nil,
        subscriptionURL: String? = nil,
        subscriptionName: String? = nil,
        subscriptionIndex: Int? = nil
    ) -> VPNProfile {
        let resolvedProfileName = resolvedName(
            for: configuration,
            customName: customName,
            subscriptionName: subscriptionName,
            subscriptionIndex: subscriptionIndex
        )

        let resolvedServerAddress = configuration.vless?.address.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedRemark = configuration.vless?.remark.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return VPNProfile(
            name: resolvedProfileName,
            rawConfig: configuration.rawConfig,
            normalizedConfig: configuration.normalizedConfig,
            kind: configuration.kind,
            serverAddress: resolvedServerAddress,
            remark: resolvedRemark,
            isSelected: false,
            subscriptionURL: subscriptionURL,
            subscriptionName: subscriptionName,
            subscriptionIndex: subscriptionIndex
        )
    }

    private static func resolvedName(
        for configuration: TunnelConfiguration,
        customName: String?,
        subscriptionName: String?,
        subscriptionIndex: Int?
    ) -> String {
        let trimmedCustom = customName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedCustom.isEmpty {
            return trimmedCustom
        }

        if let vless = configuration.vless {
            let trimmedRemark = vless.remark.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedRemark.isEmpty {
                return trimmedRemark
            }

            let trimmedAddress = vless.address.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedAddress.isEmpty {
                return "\(configuration.kind.rawValue.uppercased()) \(trimmedAddress)"
            }
        }

        let trimmedSubscriptionName = subscriptionName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedSubscriptionName.isEmpty, let subscriptionIndex {
            return "\(trimmedSubscriptionName) #\(subscriptionIndex + 1)"
        }

        return configuration.kind.rawValue.uppercased()
    }
}
