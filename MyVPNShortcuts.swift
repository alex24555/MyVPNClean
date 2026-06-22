import Foundation
import AppIntents

@available(iOS 16.0, *)
struct ConnectMyVPNIntent: AppIntent {
    static var title: LocalizedStringResource = "shortcut_connect"
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let profile = VPNProfileStore.shared.selectedProfile else {
            return .result()
        }

        await VPNManager.shared.startVPN(using: profile)
        return .result()
    }
}

@available(iOS 16.0, *)
struct DisconnectMyVPNIntent: AppIntent {
    static var title: LocalizedStringResource = "shortcut_disconnect"
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        await VPNManager.shared.stopVPN()
        return .result()
    }
}

@available(iOS 16.0, *)
struct MyVPNShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ConnectMyVPNIntent(),
            phrases: [
                "\(.applicationName) shortcut_connect"
            ],
            shortTitle: "connect",
            systemImageName: "lock.shield.fill"
        )

        AppShortcut(
            intent: DisconnectMyVPNIntent(),
            phrases: [
                "\(.applicationName) shortcut_disconnect"
            ],
            shortTitle: "disconnect",
            systemImageName: "shield.slash"
        )
    }
}
