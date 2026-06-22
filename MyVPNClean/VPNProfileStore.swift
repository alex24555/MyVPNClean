import Foundation

@MainActor
final class VPNProfileStore: ObservableObject {
    static let shared = VPNProfileStore()

    @Published private(set) var profiles: [VPNProfile] = []

    private let storageKey = "vpnProfiles"
    private let selectedProfileIDKey = "selectedVPNProfileID"

    private init() {
        load()
    }

    var selectedProfile: VPNProfile? {
        guard let savedID = savedSelectedProfileID else {
            return profiles.first(where: { $0.isSelected }) ?? profiles.first
        }

        return profiles.first(where: { $0.id.uuidString == savedID })
            ?? profiles.first(where: { $0.isSelected })
            ?? profiles.first
    }

    func addProfile(from rawConfig: String, customName: String? = nil) -> Result<VPNProfile, ProfileStoreError> {
        guard let configuration = TunnelConfiguration.build(from: rawConfig),
              isUsableImportedConfiguration(configuration) else {
            return .failure(.invalidConfig)
        }

        let newProfile = VPNProfile.build(from: configuration, customName: customName)

        var updated = profiles.map { profile in
            var copy = profile
            copy.isSelected = false
            return copy
        }

        var insertedProfile = newProfile
        let shouldSelectNewProfile = updated.isEmpty
        insertedProfile.isSelected = shouldSelectNewProfile

        updated.insert(insertedProfile, at: 0)
        profiles = updated

        if shouldSelectNewProfile {
            saveSelectedProfileID(insertedProfile.id)
        }

        save()
        return .success(insertedProfile)
    }

    func addOrUpdateProfile(from rawConfig: String, customName: String? = nil) -> Result<UpsertProfileResult, ProfileStoreError> {
        guard let configuration = TunnelConfiguration.build(from: rawConfig),
              isUsableImportedConfiguration(configuration) else {
            return .failure(.invalidConfig)
        }

        let result = upsertConfiguration(configuration, customName: customName)
        save()
        return .success(result)
    }

    func importSubscriptionConfigs(_ rawConfigs: [String], subscriptionName: String? = nil) -> SubscriptionImportResult {
        let cleanSubscriptionName = resolvedSubscriptionName(subscriptionName)
        let oldSelectedID = savedSelectedProfileID

        let removedCount = profiles.filter {
            isProfileFromSubscription($0, subscriptionName: cleanSubscriptionName)
        }.count

        profiles.removeAll {
            isProfileFromSubscription($0, subscriptionName: cleanSubscriptionName)
        }

        var insertedCount = 0
        var failedCount = 0
        var insertedProfiles: [VPNProfile] = []

        for (index, rawConfig) in rawConfigs.enumerated() {
            let trimmed = rawConfig.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !trimmed.isEmpty,
                  let configuration = TunnelConfiguration.build(from: trimmed),
                  isUsableImportedConfiguration(configuration) else {
                failedCount += 1
                continue
            }

            let customName = subscriptionProfileName(
                subscriptionName: cleanSubscriptionName,
                configuration: configuration,
                index: index
            )

            var profile = VPNProfile.build(from: configuration, customName: customName)
            profile.isSelected = false

            insertedProfiles.append(profile)
            insertedCount += 1
        }

        profiles.insert(contentsOf: insertedProfiles.reversed(), at: 0)

        if let oldSelectedID,
           profiles.contains(where: { $0.id.uuidString == oldSelectedID }) {
            saveSelectedProfileID(UUID(uuidString: oldSelectedID) ?? profiles[0].id)
        } else if let firstInserted = insertedProfiles.first {
            saveSelectedProfileID(firstInserted.id)
        }

        profiles = normalizeSelection(in: profiles)
        save()

        return SubscriptionImportResult(
            insertedCount: insertedCount,
            updatedCount: removedCount,
            failedCount: failedCount,
            lastProfile: insertedProfiles.first
        )
    }

    func updateProfile(id: UUID, newName: String, rawConfig: String) -> Result<VPNProfile, ProfileStoreError> {
        guard let configuration = TunnelConfiguration.build(from: rawConfig),
              isUsableImportedConfiguration(configuration) else {
            return .failure(.invalidConfig)
        }

        guard let index = profiles.firstIndex(where: { $0.id == id }) else {
            return .failure(.profileNotFound)
        }

        let oldProfile = profiles[index]

        let rebuilt = VPNProfile(
            id: oldProfile.id,
            name: resolvedName(newName, fallback: VPNProfile.build(from: configuration).name),
            rawConfig: configuration.rawConfig,
            normalizedConfig: configuration.normalizedConfig,
            kind: configuration.kind,
            serverAddress: configuration.vless?.address ?? "",
            remark: configuration.vless?.remark ?? "",
            isSelected: oldProfile.isSelected,
            createdAt: oldProfile.createdAt,
            updatedAt: Date()
        )

        profiles[index] = rebuilt
        save()

        return .success(rebuilt)
    }

    func deleteProfile(id: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }

        let wasSelected = profiles[index].id.uuidString == savedSelectedProfileID || profiles[index].isSelected
        let nextSelectionIndex = replacementSelectionIndex(afterDeletingAt: index, totalCount: profiles.count)

        profiles.remove(at: index)

        guard !profiles.isEmpty else {
            clearSelectedProfileID()
            save()
            return
        }

        if wasSelected {
            profiles = profiles.enumerated().map { offset, profile in
                var copy = profile
                copy.isSelected = (offset == nextSelectionIndex)
                return copy
            }

            if profiles.indices.contains(nextSelectionIndex) {
                saveSelectedProfileID(profiles[nextSelectionIndex].id)
            }
        } else {
            profiles = normalizeSelection(in: profiles)
        }

        save()
    }

    func selectProfile(id: UUID) {
        guard profiles.contains(where: { $0.id == id }) else { return }

        profiles = profiles.map { profile in
            var copy = profile
            copy.isSelected = (profile.id == id)
            return copy
        }

        saveSelectedProfileID(id)
        save()
    }

    func clearAll() {
        profiles = []
        clearSelectedProfileID()
        save()
    }

    func replaceAll(with newProfiles: [VPNProfile]) {
        let normalized = normalizeSelection(in: newProfiles)
        profiles = normalized
        persistProfiles(normalized)
    }

    func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            profiles = []
            clearSelectedProfileID()
            return
        }

        do {
            let decoded = try JSONDecoder().decode([VPNProfile].self, from: data)
            let normalized = normalizeSelection(in: decoded)
            profiles = normalized

            if let selected = normalized.first(where: { $0.isSelected }) {
                saveSelectedProfileID(selected.id)
            } else {
                clearSelectedProfileID()
            }
        } catch {
            profiles = []
            clearSelectedProfileID()
        }
    }

    func save() {
        let normalized = normalizeSelection(in: profiles)
        profiles = normalized
        persistProfiles(normalized)
    }

    private func isUsableImportedConfiguration(_ configuration: TunnelConfiguration) -> Bool {
        if configuration.kind == .wireguard {
            return true
        }

        guard let vless = configuration.vless else {
            return false
        }

        let address = vless.address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let uuid = vless.uuid.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !address.isEmpty,
              !uuid.isEmpty,
              vless.port > 0 else {
            return false
        }

        if address == "0.0.0.0" ||
            address == "127.0.0.1" ||
            address == "localhost" {
            return false
        }

        return true
    }

    private func upsertConfiguration(_ configuration: TunnelConfiguration, customName: String? = nil) -> UpsertProfileResult {
        if let existingIndex = findDuplicateIndex(for: configuration) {
            let existing = profiles[existingIndex]

            let updatedProfile = VPNProfile(
                id: existing.id,
                name: resolvedName(
                    customName ?? existing.name,
                    fallback: VPNProfile.build(from: configuration, customName: customName).name
                ),
                rawConfig: configuration.rawConfig,
                normalizedConfig: configuration.normalizedConfig,
                kind: configuration.kind,
                serverAddress: configuration.vless?.address ?? "",
                remark: configuration.vless?.remark ?? "",
                isSelected: existing.isSelected,
                createdAt: existing.createdAt,
                updatedAt: Date()
            )

            profiles[existingIndex] = updatedProfile
            return .updated(updatedProfile)
        }

        let newProfile = VPNProfile.build(from: configuration, customName: customName)

        var insertedProfile = newProfile
        let shouldSelectNewProfile = profiles.isEmpty
        insertedProfile.isSelected = shouldSelectNewProfile

        if shouldSelectNewProfile {
            saveSelectedProfileID(insertedProfile.id)
        }

        profiles.insert(insertedProfile, at: 0)
        return .inserted(insertedProfile)
    }

    private func resolvedSubscriptionName(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Subscription" : trimmed
    }

    private func isProfileFromSubscription(_ profile: VPNProfile, subscriptionName: String) -> Bool {
        let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.hasPrefix("\(subscriptionName) • ") || name.hasPrefix("\(subscriptionName) #")
    }

    private func subscriptionProfileName(
        subscriptionName: String?,
        configuration: TunnelConfiguration,
        index: Int
    ) -> String? {
        let trimmedSubscriptionName = subscriptionName?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !trimmedSubscriptionName.isEmpty else {
            return nil
        }

        if let remark = configuration.vless?.remark.trimmingCharacters(in: .whitespacesAndNewlines),
           !remark.isEmpty {
            return "\(trimmedSubscriptionName) • \(remark)"
        }

        if let address = configuration.vless?.address.trimmingCharacters(in: .whitespacesAndNewlines),
           !address.isEmpty {
            return "\(trimmedSubscriptionName) • \(address)"
        }

        return "\(trimmedSubscriptionName) #\(index + 1)"
    }

    private func persistProfiles(_ normalized: [VPNProfile]) {
        do {
            if let selected = normalized.first(where: { $0.isSelected }) {
                saveSelectedProfileID(selected.id)
            } else {
                clearSelectedProfileID()
            }

            let data = try JSONEncoder().encode(normalized)
            UserDefaults.standard.set(data, forKey: storageKey)
        } catch {
            UserDefaults.standard.removeObject(forKey: storageKey)
        }
    }

    private var savedSelectedProfileID: String? {
        let value = UserDefaults.standard.string(forKey: selectedProfileIDKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    private func saveSelectedProfileID(_ id: UUID) {
        UserDefaults.standard.set(id.uuidString, forKey: selectedProfileIDKey)
    }

    private func clearSelectedProfileID() {
        UserDefaults.standard.removeObject(forKey: selectedProfileIDKey)
    }

    private func normalizeSelection(in input: [VPNProfile]) -> [VPNProfile] {
        guard !input.isEmpty else { return [] }

        var result = input
        let savedID = savedSelectedProfileID

        if let savedID,
           let savedIndex = result.firstIndex(where: { $0.id.uuidString == savedID }) {
            for index in result.indices {
                result[index].isSelected = (index == savedIndex)
            }
            return result
        }

        let selectedIndices = result.indices.filter { result[$0].isSelected }

        if selectedIndices.isEmpty {
            for index in result.indices {
                result[index].isSelected = (index == 0)
            }
            return result
        }

        if selectedIndices.count == 1 {
            return result
        }

        let keepIndex = selectedIndices[0]
        for index in result.indices {
            result[index].isSelected = (index == keepIndex)
        }

        return result
    }

    private func replacementSelectionIndex(afterDeletingAt deletedIndex: Int, totalCount: Int) -> Int {
        let newCount = totalCount - 1

        guard newCount > 0 else { return 0 }

        if deletedIndex < newCount {
            return deletedIndex
        }

        return max(0, newCount - 1)
    }

    private func findDuplicateIndex(for configuration: TunnelConfiguration) -> Int? {
        if let newVLESS = configuration.vless {
            let newKey = stableVLESSKey(for: newVLESS)

            return profiles.firstIndex { profile in
                guard let existingConfiguration = TunnelConfiguration.build(from: profile.rawConfig),
                      let existingVLESS = existingConfiguration.vless else {
                    return false
                }

                return stableVLESSKey(for: existingVLESS) == newKey
            }
        }

        let normalized = configuration.normalizedConfig
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return profiles.firstIndex {
            $0.normalizedConfig.trimmingCharacters(in: .whitespacesAndNewlines) == normalized
        }
    }

    private func stableVLESSKey(for vless: TunnelConfiguration.ParsedVLESS) -> String {
        [
            vless.address.lowercased(),
            String(vless.port),
            vless.uuid.lowercased(),
            vless.security.lowercased(),
            vless.transportType.lowercased(),
            vless.sni.lowercased()
        ]
        .joined(separator: "|")
    }

    private func resolvedName(_ proposed: String, fallback: String) -> String {
        let trimmed = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}

enum ProfileStoreError: LocalizedError {
    case invalidConfig
    case profileNotFound

    var errorDescription: String? {
        switch self {
        case .invalidConfig:
            return "Invalid config"
        case .profileNotFound:
            return "Profile not found"
        }
    }
}

enum UpsertProfileResult {
    case inserted(VPNProfile)
    case updated(VPNProfile)
}

struct SubscriptionImportResult: Equatable {
    let insertedCount: Int
    let updatedCount: Int
    let failedCount: Int
    let lastProfile: VPNProfile?

    var successCount: Int {
        insertedCount + updatedCount
    }
}
