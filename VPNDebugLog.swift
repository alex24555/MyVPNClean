import Foundation

@MainActor
final class VPNDebugLog: ObservableObject {
    static let shared = VPNDebugLog()

    struct Entry: Identifiable, Codable, Equatable {
        let id: UUID
        let timestamp: Date
        let level: Level
        let category: Category
        let message: String

        init(
            id: UUID = UUID(),
            timestamp: Date = Date(),
            level: Level,
            category: Category,
            message: String
        ) {
            self.id = id
            self.timestamp = timestamp
            self.level = level
            self.category = category
            self.message = message
        }
    }

    enum Level: String, Codable, CaseIterable {
        case info
        case warning
        case error
    }

    enum Category: String, Codable, CaseIterable {
        case ui
        case manager
        case engine
        case packetTunnel
        case configuration
        case profile
    }

    @Published private(set) var entries: [Entry] = []

    private let storageKey = "vpnDebugLogEntries"
    private let maxEntries = 200

    private init() {
        load()
    }

    func log(
        _ message: String,
        level: Level = .info,
        category: Category
    ) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let entry = Entry(
            level: level,
            category: category,
            message: trimmed
        )

        entries.insert(entry, at: 0)
        trimIfNeeded()
        save()
    }

    func clear() {
        entries = []
        save()
    }

    func formattedTimestamp(for date: Date) -> String {
        Self.timestampFormatter.string(from: date)
    }

    func exportText() -> String {
        entries.map { entry in
            "[\(Self.exportTimestampFormatter.string(from: entry.timestamp))] [\(entry.level.rawValue.uppercased())] [\(entry.category.rawValue)] \(entry.message)"
        }
        .joined(separator: "\n")
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            entries = []
            return
        }

        do {
            let decoded = try JSONDecoder().decode([Entry].self, from: data)
            entries = Array(decoded.prefix(maxEntries))
        } catch {
            entries = []
            UserDefaults.standard.removeObject(forKey: storageKey)
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(entries)
            UserDefaults.standard.set(data, forKey: storageKey)
        } catch {
            UserDefaults.standard.removeObject(forKey: storageKey)
        }
    }

    private func trimIfNeeded() {
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static let exportTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}
