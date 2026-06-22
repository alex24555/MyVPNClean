import SwiftUI

@main
struct MyVPNCleanApp: App {

    @StateObject private var vpnManager = VPNManager.shared
    @StateObject private var profileStore = VPNProfileStore.shared

    @State private var lastHandledURL: URL?
    @State private var isHandlingURLCommand = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(vpnManager)
                .environmentObject(profileStore)
                .onOpenURL { url in
                    handleURL(url)
                }
        }
    }

    private func handleURL(_ url: URL) {
        guard url.scheme == "myvpnclean" else { return }
        guard lastHandledURL != url || !isHandlingURLCommand else { return }

        lastHandledURL = url
        isHandlingURLCommand = true

        switch url.host {
        case "connect":
            Task {
                defer {
                    Task { @MainActor in
                        isHandlingURLCommand = false
                    }
                }

                if let profile = profileStore.selectedProfile {
                    await vpnManager.startVPN(using: profile)
                }
            }

        case "disconnect":
            Task {
                defer {
                    Task { @MainActor in
                        isHandlingURLCommand = false
                    }
                }

                await vpnManager.stopVPN()
            }

        default:
            isHandlingURLCommand = false
        }
    }
}
