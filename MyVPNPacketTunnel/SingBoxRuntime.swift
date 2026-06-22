import Foundation
import NetworkExtension
import Libbox

final class SingBoxRuntime {

    enum RuntimeState: Equatable {
        case idle
        case starting
        case running
        case failed(String)
        case stopped
    }

    private let config: String
    private let packetFlow: NEPacketTunnelFlow
    private let tunnelProvider: NEPacketTunnelProvider

    private(set) var state: RuntimeState = .idle

    private var service: LibboxBoxService?
    private var platformAdapter: LibboxPlatformAdapter?

    init(
        configuration: String,
        packetFlow: NEPacketTunnelFlow,
        tunnelProvider: NEPacketTunnelProvider
    ) {
        self.config = configuration
        self.packetFlow = packetFlow
        self.tunnelProvider = tunnelProvider
    }

    func start() async {
        guard case .idle = state else {
            log("Start skipped: already \(state)")
            return
        }

        state = .starting
        log("🚀 SingBox starting...")
        log("Config size: \(config.count) chars")

        do {
            try prepareLibboxEnvironment()

            let adapter = LibboxPlatformAdapter(tunnelProvider: tunnelProvider)
            self.platformAdapter = adapter

            var createError: NSError?
            guard let service = LibboxNewService(config, adapter, &createError) else {
                let message = createError?.localizedDescription ?? "LibboxNewService returned nil"
                state = .failed(message)
                log("❌ SingBox create failed: \(message)")
                return
            }

            self.service = service

            try service.start()
            state = .running
            log("✅ SingBox runtime running")

        } catch {
            state = .failed(error.localizedDescription)
            log("❌ SingBox start failed: \(error.localizedDescription)")
        }
    }

    func stop() {
        guard let service else {
            state = .stopped
            platformAdapter = nil
            return
        }

        do {
            try service.close()
            log("🛑 SingBox stopped")
        } catch {
            log("❌ Stop error: \(error.localizedDescription)")
        }

        self.service = nil
        self.platformAdapter = nil
        state = .stopped
    }

    private func prepareLibboxEnvironment() throws {
        let fm = FileManager.default

        let baseURL = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Libbox", isDirectory: true)

        let workingURL = baseURL.appendingPathComponent("working", isDirectory: true)
        let tempURL = baseURL.appendingPathComponent("temp", isDirectory: true)

        try fm.createDirectory(at: baseURL, withIntermediateDirectories: true)
        try fm.createDirectory(at: workingURL, withIntermediateDirectories: true)
        try fm.createDirectory(at: tempURL, withIntermediateDirectories: true)

        try copyGeoDatabaseIfNeeded(
            fileName: "geosite",
            fileExtension: "dat",
            destinationDirectory: workingURL
        )

        try copyGeoDatabaseIfNeeded(
            fileName: "geoip",
            fileExtension: "dat",
            destinationDirectory: workingURL
        )

        let options = LibboxSetupOptions()
        options.basePath = baseURL.path
        options.workingPath = workingURL.path
        options.tempPath = tempURL.path
        options.isTVOS = false
        options.fixAndroidStack = false

        var setupError: NSError?
        let success = LibboxSetup(options, &setupError)

        guard success else {
            throw setupError ?? NSError(
                domain: "MyVPN.LibboxSetup",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "LibboxSetup failed"]
            )
        }

        log("Libbox setup prepared")
        log("Geo databases prepared in: \(workingURL.path)")
    }

    private func copyGeoDatabaseIfNeeded(
        fileName: String,
        fileExtension: String,
        destinationDirectory: URL
    ) throws {
        let fm = FileManager.default

        guard let sourceURL = Bundle.main.url(
            forResource: fileName,
            withExtension: fileExtension
        ) else {
            log("⚠️ \(fileName).\(fileExtension) not found in bundle")
            return
        }

        let destinationURL = destinationDirectory
            .appendingPathComponent("\(fileName).\(fileExtension)")

        if fm.fileExists(atPath: destinationURL.path) {
            try fm.removeItem(at: destinationURL)
        }

        try fm.copyItem(at: sourceURL, to: destinationURL)
        log("Copied \(fileName).\(fileExtension) to Libbox working directory")
    }

    private func log(_ message: String) {
        NSLog("[MyVPN][SingBoxRuntime] %@", message)
    }
}
