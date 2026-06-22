import Foundation

enum BackupError: Error {
    case noContainer
}

struct VKProfileEntry: Codable {
    let device: String
    let browser_fp: String
    let user_agent: String
    let captured_at: TimeInterval
}

enum VKProfileCache {
    private static let appGroupID = "group.alex.MyVPNClean"
    private static let filename = "vk_profile.json"

    private static var fileURL: URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else {
            return nil
        }

        return container.appendingPathComponent(filename)
    }

    static func save(
        device: String,
        browserFp: String,
        userAgent: String
    ) {
        guard !device.isEmpty, !browserFp.isEmpty else {
            SharedLogger.shared.log(
                "[AppDebug] VKProfileCache.save: empty fields, skipping (device=\(device.count)c, browser_fp=\(browserFp.count)c)"
            )
            return
        }

        guard let url = fileURL else {
            SharedLogger.shared.log(
                "[AppDebug] VKProfileCache.save: no App Group container"
            )
            return
        }

        let entry = VKProfileEntry(
            device: device,
            browser_fp: browserFp,
            user_agent: userAgent,
            captured_at: Date().timeIntervalSince1970
        )

        do {
            let data = try JSONEncoder().encode(entry)

            try data.write(
                to: url,
                options: .atomic
            )

            SharedLogger.shared.log(
                "[AppDebug] VKProfileCache.save: ok → \(url.path)"
            )

        } catch {
            SharedLogger.shared.log(
                "[AppDebug] VKProfileCache.save failed: \(error)"
            )
        }
    }

    static func update(
        device: String,
        browserFp: String,
        userAgent: String
    ) {
        guard let url = fileURL else {
            SharedLogger.shared.log(
                "[AppDebug] VKProfileCache.update: no container"
            )
            return
        }

        let existing = load()

        let mergedDevice =
            device.isEmpty
            ? (existing?.device ?? "")
            : device

        let mergedBrowserFp =
            browserFp.isEmpty
            ? (existing?.browser_fp ?? "")
            : browserFp

        let mergedUA =
            userAgent.isEmpty
            ? (existing?.user_agent ?? "")
            : userAgent

        if mergedDevice.isEmpty &&
            mergedBrowserFp.isEmpty {

            SharedLogger.shared.log(
                "[AppDebug] VKProfileCache.update: nothing to merge"
            )

            return
        }

        let entry = VKProfileEntry(
            device: mergedDevice,
            browser_fp: mergedBrowserFp,
            user_agent: mergedUA,
            captured_at: Date().timeIntervalSince1970
        )

        do {
            let data = try JSONEncoder().encode(entry)

            try data.write(
                to: url,
                options: .atomic
            )

        } catch {
            SharedLogger.shared.log(
                "[AppDebug] VKProfileCache.update failed: \(error)"
            )
        }
    }

    static func load() -> VKProfileEntry? {
        guard let url = fileURL else {
            return nil
        }

        guard let data = try? Data(contentsOf: url) else {
            return nil
        }

        return try? JSONDecoder().decode(
            VKProfileEntry.self,
            from: data
        )
    }

    static var hasProfile: Bool {
        guard let entry = load() else {
            return false
        }

        return !entry.device.isEmpty &&
        !entry.browser_fp.isEmpty
    }

    static func applyFromBackup(
        _ entry: VKProfileEntry
    ) throws {

        guard let url = fileURL else {
            throw BackupError.noContainer
        }

        let data = try JSONEncoder().encode(entry)

        try data.write(
            to: url,
            options: .atomic
        )
    }

    static func delete() throws {

        guard let url = fileURL else {
            throw BackupError.noContainer
        }

        do {

            try FileManager.default.removeItem(
                at: url
            )

        } catch CocoaError.fileNoSuchFile {

        } catch let nsErr as NSError
        where nsErr.code == NSFileNoSuchFileError {

        } catch {
            throw error
        }
    }
}
