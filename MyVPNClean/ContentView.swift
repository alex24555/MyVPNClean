import SwiftUI
import UIKit
import WebKit
import os.log

private let captchaLog = OSLog(subsystem: "alex.MyVPNClean.app", category: "Captcha")

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("serverAddress") private var serverAddress: String = ""

    @AppStorage("vpnEngineKind")
    private var vpnEngineKind =
    VPNEngineKind.packetTunnel.rawValue
    @AppStorage("configURL")
    private var configURL = ""

    @AppStorage("accessToken")
    private var accessToken = ""

    @AppStorage("hasSeenOnboarding")
    private var hasSeenOnboarding = false

    @AppStorage("antiDetectConfigured")
    private var antiDetectConfigured = false
    @StateObject private var vpnManager = VPNManager.shared
    @StateObject private var vkTunnel = TunnelManager()
    @StateObject private var profileStore = VPNProfileStore.shared
    @StateObject private var diagnostics = ConnectionDiagnostics()

    @State private var parsedConfiguration: TunnelConfiguration?
    @State private var statusText = "Disconnected"
    @State private var showVPNErrorAlert = false
    @State private var vpnErrorMessage = ""
    @State private var showSettings = false
    @State private var showProfilePicker = false
    @State private var showDeleteProfileConfirmation = false
    @State private var showAutoSetupGuide = false
    @State private var showOnboarding = false
    @State private var animatePulse = false
    @State private var connectionTask: Task<Void, Never>?
    @State private var quickStatusMessage = ""
    @State private var isUpdatingSubscription = false

    private var isRussian: Bool {
        Locale.current.identifier.lowercased().hasPrefix("ru")
    }

    private func text(_ en: String, _ ru: String) -> String {
        isRussian ? ru : en
    }

    private var antiDetectAppHint: String {
        text(
            "Choose marketplaces, banks, delivery apps, local services and any apps that should work without VPN.",
            "Выберите маркетплейсы, банки, доставку, локальные сервисы и любые приложения, которые должны работать без VPN."
        )
    }

    var body: some View {
        NavigationStack {
            mainScreen
        }
        .standardSheets(
            showSettings: $showSettings,
            showProfilePicker: $showProfilePicker,
            showAutoSetupGuide: $showAutoSetupGuide,
            showOnboarding: $showOnboarding,
            autoAntiDetectSetupSheet: AnyView(autoAntiDetectSetupSheet),
            onboardingSheet: AnyView(onboardingSheet)
        )
        .sheet(isPresented: $vkTunnel.captchaPending) {
            if let urlStr = vkTunnel.captchaImageURL, let url = URL(string: urlStr) {
                CaptchaWebView(
                    url: url,
                    captchaSID: vkTunnel.captchaSID ?? "",
                    onSolved: { token in
                        vkTunnel.solveCaptcha(answer: token)
                    },
                    onDismiss: {
                        vkTunnel.onCaptchaSheetDismissed()
                        vkTunnel.captchaPending = false
                        vkTunnel.captchaImageURL = nil
                    },
                    onLimitDetected: {
                        vkTunnel.onCaptchaLimitDetected()
                    },
                    onCaptchaReady: {
                        vkTunnel.onCaptchaReady()
                    },
                    onLog: { message in
                        vkTunnel.logFromCaptchaView(message)
                    },
                    tunnel: vkTunnel
                )
            } else {
                ProgressView("Loading captcha…")
                    .padding()
            }
        }
        .standardAlerts(
            showVPNErrorAlert: $showVPNErrorAlert,
            showDeleteProfileConfirmation: $showDeleteProfileConfirmation,
            vpnErrorMessage: vpnErrorMessage,
            errorTitle: text("Connection Error", "Ошибка подключения"),
            deleteTitle: text("Delete Profile?", "Удалить профиль?"),
            deleteMessage: text("The selected profile will be deleted.", "Выбранный профиль будет удалён."),
            deleteButtonTitle: text("Delete", "Удалить"),
            cancelButtonTitle: text("Cancel", "Отмена"),
            clearError: {
                vpnManager.clearError()
                syncStatusFromVPNState()
            },
            deleteProfile: {
                deleteSelectedProfile()
            }
        )
        .onChange(of: isConnectingUI || (isConnectedUI && !hasConfirmedInternet)) { newValue in
            animatePulse = newValue
        }


        .onAppear {
            refreshScreenState()

            if !hasSeenOnboarding {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    showOnboarding = true
                }
            }
        }
        .onChange(of: scenePhase) { newPhase in
            guard newPhase == .active else { return }
            refreshScreenState()
        }
        .onChange(of: profileStore.profiles) { _ in
            syncFromSelectedProfile()
            syncStatusFromVPNState()
        }
        .onChange(of: vpnManager.state) { newState in
            syncStatusFromVPNState()
            updatePulseAnimation()

            if newState == .connected {
                Task {
                    await diagnostics.check()
                }
            }
        }
        .onChange(of: vpnEngineKind) { _ in
            refreshScreenState()
        }
        .onReceive(vpnManager.$lastError) { newValue in
            guard let newValue, !newValue.isEmpty else { return }
            vpnErrorMessage = newValue
            showVPNErrorAlert = true
        }
        .onReceive(vkTunnel.$errorMessage) { newValue in
            guard vpnEngineKind == "packetTunnelVKTurn",
                  let newValue,
                  !newValue.isEmpty else { return }
            vpnErrorMessage = newValue
            showVPNErrorAlert = true
        }
        .onDisappear {
            connectionTask?.cancel()
            connectionTask = nil
        }
    }

    private var mainScreen: some View {
        ScrollView {
            VStack(spacing: 8) {
                headerSection

                Spacer()
                    .frame(height: 10)

                statusCircleSection

VStack(spacing: 4) {
    Text("Uptime: \(formatUptime(Int(vkTunnel.stats.tunnelUptimeSec)))")
        .font(.caption2)
        .foregroundColor(.gray)
}


                mainActionSection
                connectionDiagnosticsSection
                profileCardSection
                antiDetectStatusSection
                quickActionsSection
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        
.navigationBarTitleDisplayMode(.inline)
        .onAppear {
            cleanupStickyMessage()
        }
        .onChange(of: vkTunnel.stats.activeConns) { _ in
            cleanupStickyMessage()
        }

        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .foregroundColor(.primary)
                }
            }
        }
    }

    private var isVKTurnEngine: Bool {
        vpnEngineKind == "packetTunnelVKTurn"
    }

    private var selectedProfile: VPNProfile? {
        profileStore.selectedProfile
    }

    private var headerSection: some View {
        VStack(spacing: 8) {
            Text("MyVPN Clean")
                .font(.system(size: 34, weight: .bold))

            Text(statusHeadline)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(statusColor)

            Text(statusSubtitle)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }



    
    private var statusCircleSection: some View {
        HStack(alignment: .center, spacing: 18) {
            if isVKTurnEngine {
                trafficMiniBlock(symbol: "↓", value: downloadTrafficText)
                    .frame(width: 72)
            } else {
                Spacer().frame(width: 72)
            }

            ZStack {
                if isConnectingUI {
                    Circle()
                        .stroke(circleColor.opacity(0.36), lineWidth: 10)
                        .frame(width: animatePulse ? 188 : 160, height: animatePulse ? 188 : 160)
                        .opacity(animatePulse ? 0.22 : 0.75)
                        .animation(
                            .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                            value: animatePulse
                        )
                }

                Circle()
                    .fill(circleColor.opacity(0.13))
                    .frame(width: 164, height: 164)

                Circle()
                    .stroke(circleColor.opacity(0.28), lineWidth: 2)
                    .frame(width: 164, height: 164)

                Image(systemName: isConnectedUI ? "lock.shield.fill" : "shield")
                    .font(.system(size: 56, weight: .medium))
                    .foregroundColor(circleColor)
            }
            .frame(width: 190, height: 178)

            if isVKTurnEngine {
                trafficMiniBlock(symbol: "↑", value: uploadTrafficText)
                    .frame(width: 72)
            } else {
                Spacer().frame(width: 72)
            }
        }
        .frame(height: 176)
        .padding(.top, 6)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
    }

    private func trafficMiniBlock(symbol: String, value: String) -> some View {
        VStack(spacing: 5) {
            Text(symbol)
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.secondary)

            Text(value)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }

    private var downloadTrafficText: String {
        if !hasConfirmedInternet {
            return isConnectingUI ? "..." : "—"
        }

        return "\(Int(currentRXRateKB)) KB/s"
    }

    private var uploadTrafficText: String {
        if !hasConfirmedInternet {
            return isConnectingUI ? "..." : "—"
        }

        return "\(Int(currentTXRateKB)) KB/s"
    }

    private var currentRXRateKB: Double {
        if isVKTurnEngine {
            return vkTunnel.rxRate / 1024
        }

        return 0
    }

    private var currentTXRateKB: Double {
        if isVKTurnEngine {
            return vkTunnel.txRate / 1024
        }

        return 0
    }


    private var mainActionSection: some View {
        VStack(spacing: 12) {
            Spacer()
                .frame(height: 6)
            Button(action: toggleConnection) {
                Group {
                    if isVPNBusy {
                        HStack(spacing: 10) {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))

                            Text(busyButtonTitle)
                                .font(.system(size: 17, weight: .semibold))
                        }
                    } else {
                        Text(isConnectedUI ? text("Disconnect", "Отключить") : text("Connect", "Подключить"))
                            .font(.system(size: 19, weight: .bold))
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 58)
                .background(primaryButtonColor)
                .foregroundColor(.white)
                .cornerRadius(20)
                .shadow(color: primaryButtonColor.opacity(0.22), radius: 10, x: 0, y: 6)
            }
            .disabled(isVPNBusy)

            if !hasUsableConfig {
                Text(text("Add or select a VPN profile to continue.", "Добавьте или выберите VPN-профиль, чтобы продолжить."))
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            if !quickStatusMessage.isEmpty {
                Text(quickStatusMessage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(statusMessageColor)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var connectionDiagnosticsSection: some View {
        sectionCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: isVKTurnEngine
                        ? (hasConfirmedInternet ? "checkmark.circle.fill" : "xmark.circle.fill")
                        : diagnosticsIcon)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(
                            isVKTurnEngine
                            ? (hasConfirmedInternet ? .green : .red)
                            : diagnosticsColor
                        )

                    VStack(alignment: .leading, spacing: 3) {
                        Text(connectionCardTitle)
                            .font(.system(size: 16, weight: .bold))

                        Text(connectionCardSubtitle)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    if diagnostics.status == .checking {
                        ProgressView()
                    }
                }

                Divider()

                if isVKTurnEngine {
                    infoRow(
                        icon: "arrow.triangle.branch",
                        title: text("Active connections", "Активные соединения"),
                        value: "\(vkTunnel.stats.activeConns)/\(VKTurnSettings.numConnections)"
                    )

                    infoRow(
                        icon: "timer",
                        title: text("Live ping", "Живой пинг"),
                        value: vkTunnel.internetRTTms > 0 ? "\(Int(vkTunnel.internetRTTms)) ms" : "—"
                    )

                    infoRow(
                        icon: "antenna.radiowaves.left.and.right",
                        title: text("Last TURN RTT", "Последний TURN RTT"),
                        value: (vkTunnel.stats.activeConns > 0 && vkTunnel.stats.turnRTTms > 0) ? "\(Int(vkTunnel.stats.turnRTTms)) ms" : "—"
                    )

                    infoRow(
                        icon: "arrow.clockwise",
                        title: text("Reconnects", "Переподключения"),
                        value: "\(vkTunnel.stats.reconnects)"
                    )
                } else {
                    infoRow(icon: "timer", title: text("Latency", "Задержка"), value: diagnostics.latencyText)
                    infoRow(icon: "network", title: text("External IP", "Внешний IP"), value: diagnostics.externalIP)
                    infoRow(icon: "clock", title: text("Last check", "Последняя проверка"), value: diagnostics.lastCheckedText)
                }

                Button {
                    Task {
                        await diagnostics.check()
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.clockwise")
                        Text(text("Check Connection", "Проверить соединение"))
                    }
                    .font(.system(size: 15, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(Color.blue.opacity(0.13))
                    .foregroundColor(.blue)
                    .cornerRadius(15)
                }
                .disabled(diagnostics.status == .checking)
            }
        }
    }

    private var connectionCardTitle: String {
        if isVKTurnEngine {
            return "VK TURN"
        }

        if let kind = selectedProfile?.kind.rawValue.uppercased(), !kind.isEmpty {
            return kind
        }

        return text("Connection Check", "Проверка соединения")
    }

    private var connectionCardSubtitle: String {
        if isVKTurnEngine {
            if vkTunnel.status == .connected {
                return text("Tunnel statistics", "Статистика туннеля")
            }

            return diagnosticsStatusText
        }

        return diagnosticsStatusText
    }

    private var diagnosticsIcon: String {
        switch diagnostics.status {
        case .idle:
            return "wave.3.right.circle"
        case .checking:
            return "hourglass"
        case .success:
            return "checkmark.circle.fill"
        case .slow:
            return "exclamationmark.circle.fill"
        case .failed:
            return "xmark.circle.fill"
        }
    }

    private var diagnosticsColor: Color {
        switch diagnostics.status {
        case .idle, .checking:
            return .blue
        case .success:
            return .green
        case .slow:
            return Color.yellow
        case .failed:
            return .red
        }
    }

    private var diagnosticsStatusText: String {
        switch diagnostics.status {
        case .idle:
            return text("Tap to check real internet access.", "Нажмите, чтобы проверить реальный доступ в интернет.")
        case .checking:
            return text("Checking internet and external IP...", "Проверяем интернет и внешний IP...")
        case .success:
            return text("Internet is available.", "Интернет доступен.")
        case .slow:
            return text("Internet is available, but connection is slow.", "Интернет доступен, но соединение медленное.")
        case .failed(let message):
            if isConnectedUI {
                return text("VPN is connected, but internet is not available.", "VPN подключён, но интернет не работает.") + " \(message)"
            } else {
                return text("Check failed", "Проверка не пройдена") + ": \(message)"
            }
        }
    }

    private var profileCardSection: some View {
        sectionCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(text("Selected Profile", "Выбранный профиль"))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.secondary)

                        Text(selectedProfile?.displayName ?? text("No profile selected", "Профиль не выбран"))
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(selectedProfile == nil ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer()

                    Text("\(profileStore.profiles.count)")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color(.secondarySystemGroupedBackground))
                        .cornerRadius(10)
                }

                if let selectedProfile {
                    if !selectedProfile.serverAddress.isEmpty {
                        infoRow(icon: "server.rack", title: text("Server", "Сервер"), value: selectedProfile.serverAddress)
                    }

                    infoRow(icon: "network", title: text("Type", "Тип"), value: selectedProfile.kind.rawValue.uppercased())
                } else {
                    Text(text("Import a config or subscription to start using VPN.", "Импортируйте конфиг или подписку, чтобы начать пользоваться VPN."))
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var antiDetectStatusSection: some View {
        sectionCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: antiDetectConfigured ? "checkmark.shield.fill" : "bolt.shield.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(antiDetectConfigured ? .green : .blue)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(text("Smart App Protection", "Умная защита приложений"))
                            .font(.system(size: 16, weight: .bold))

                        Text(
                            antiDetectConfigured
                            ? text("Configured. Selected apps can automatically pause VPN.", "Настроено. Выбранные приложения могут автоматически приостанавливать VPN.")
                            : text("Recommended for banking, marketplaces and local services.", "Рекомендуется для банков, маркетплейсов и локальных сервисов.")
                        )
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()
                }

                Button {
                    showAutoSetupGuide = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "wand.and.stars")
                        Text(antiDetectConfigured ? text("Review Setup", "Посмотреть настройку") : text("Setup Auto Anti-Detect", "Настроить авто-защиту"))
                    }
                    .font(.system(size: 15, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(Color.blue.opacity(0.13))
                    .foregroundColor(.blue)
                    .cornerRadius(15)
                }
                .disabled(isVPNBusy)
            }
        }
    }

    private var quickActionsSection: some View {
        VStack(spacing: 12) {
            Button {
                showProfilePicker = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "list.bullet.rectangle")
                    Text(text("Profiles", "Профили"))
                }
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(Color.green)
                .foregroundColor(.white)
                .cornerRadius(17)
            }
            .disabled(isVPNBusy)

            HStack(spacing: 12) {
                if profileStore.profiles.count > 1 {
                    quickActionButton(
                        title: text("Next", "Следующий"),
                        icon: "arrow.forward.circle",
                        color: .blue,
                        action: selectNextProfile
                    )
                    .disabled(isVPNBusy)
                }

                quickActionButton(
                    title: text("Paste", "Вставить"),
                    icon: "doc.on.clipboard",
                    color: .purple,
                    action: pasteConfigQuickly
                )
                .disabled(isVPNBusy)

                quickActionButton(
                    title: isUpdatingSubscription ? text("Updating", "Обновление") : text("Update", "Обновить"),
                    icon: "arrow.clockwise",
                    color: .orange,
                    action: updateSubscriptionSmartly
                )
                .disabled(isVPNBusy || isUpdatingSubscription)
            }

            HStack(spacing: 12) {
                Button(action: clearStatus) {
                    Text(text("Clear Status", "Очистить статус"))
                        .font(.system(size: 14, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background(Color.orange.opacity(0.14))
                        .foregroundColor(.orange)
                        .cornerRadius(14)
                }
                .disabled(isVPNBusy)

                Button {
                    showDeleteProfileConfirmation = true
                } label: {
                    Text(text("Delete Profile", "Удалить профиль"))
                        .font(.system(size: 14, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background(Color.red.opacity(0.12))
                        .foregroundColor(.red)
                        .cornerRadius(14)
                }
                .disabled(selectedProfile == nil || isVPNBusy)
                .opacity(selectedProfile == nil ? 0.5 : 1)
            }
        }
    }

    private var onboardingSheet: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Spacer()

                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 64, weight: .semibold))
                    .foregroundColor(.blue)

                VStack(spacing: 10) {
                    Text(text("Welcome to MyVPN Clean", "Добро пожаловать в MyVPN Clean"))
                        .font(.system(size: 30, weight: .bold))
                        .multilineTextAlignment(.center)

                    Text(text(
                        "Secure connection, profile management and smart app protection in one simple app.",
                        "Безопасное подключение, управление профилями и умная защита приложений в одном приложении."
                    ))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                }

                VStack(spacing: 14) {
                    onboardingRow(
                        icon: "1.circle.fill",
                        title: text("Add a profile", "Добавьте профиль"),
                        subtitle: text("Import a VPN config or subscription.", "Импортируйте VPN-конфиг или подписку.")
                    )

                    onboardingRow(
                        icon: "2.circle.fill",
                        title: text("Connect safely", "Подключитесь безопасно"),
                        subtitle: text("Use the main Connect button to start VPN.", "Используйте кнопку подключения на главном экране.")
                    )

                    onboardingRow(
                        icon: "3.circle.fill",
                        title: text("Enable Smart App Protection", "Включите умную защиту"),
                        subtitle: text("Set up iOS Automation for selected local apps.", "Настройте автоматизацию iOS для выбранных локальных приложений.")
                    )
                }

                Spacer()

                Button {
                    hasSeenOnboarding = true
                    showOnboarding = false
                } label: {
                    Text(text("Get Started", "Начать"))
                        .font(.system(size: 17, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(18)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 18)
            }
            .padding(.horizontal, 20)
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
        }
    }

    private func onboardingRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.blue)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .bold))

                Text(subtitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(14)
        .background(Color(.systemBackground))
        .cornerRadius(18)
    }

    private var autoAntiDetectSetupSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    setupHeader
                    setupSteps
                    setupActionsCard
                    setupFooter
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle(text("Setup", "Настройка"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(text("Done", "Готово")) {
                        showAutoSetupGuide = false
                    }
                }
            }
        }
    }

    private var setupHeader: some View {
        VStack(spacing: 10) {
            Image(systemName: "bolt.shield.fill")
                .font(.system(size: 46, weight: .semibold))
                .foregroundColor(.blue)

            Text(text("Smart App Protection", "Умная защита приложений"))
                .font(.system(size: 28, weight: .bold))

            Text(text(
                "Set up iOS Automation so selected apps automatically pause VPN when opened and restore it when closed.",
                "Настройте автоматизацию iOS: выбранные приложения будут автоматически отключать VPN при открытии и включать обратно при закрытии."
            ))
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
        }
        .padding(.top, 10)
    }

    private var setupSteps: some View {
        VStack(spacing: 18) {
            setupStepCard(
                number: "1",
                title: text("Create Opened automation", "Создайте автоматизацию открытия"),
                text: text(
                    "Shortcuts → Automation → New Automation → App → choose apps → Is Opened → Run Immediately → Disconnect MyVPN.",
                    "Команды → Автоматизация → Новая автоматизация → Приложение → выберите приложения → Открыто → Запускать немедленно → Disconnect MyVPN."
                )
            )

            setupStepCard(
                number: "2",
                title: text("Create Closed automation", "Создайте автоматизацию закрытия"),
                text: text(
                    "Create the same App automation again, but choose Is Closed → Run Immediately → Connect MyVPN.",
                    "Создайте такую же автоматизацию, но выберите Закрыто → Запускать немедленно → Connect MyVPN."
                )
            )

            setupStepCard(
                number: "3",
                title: text("Use app actions only", "Используйте только действия приложения"),
                text: text(
                    "Choose system actions from this app: Disconnect MyVPN and Connect MyVPN. Do not use Open URL or old iCloud shortcuts.",
                    "Выбирайте системные действия этого приложения: Disconnect MyVPN и Connect MyVPN. Не используйте Open URL и старые iCloud-шорткаты."
                )
            )
        }
    }

    private var setupActionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(text("Which apps to choose", "Какие приложения выбрать"))
                .font(.system(size: 18, weight: .bold))

            Text(antiDetectAppHint)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemGroupedBackground))
                .cornerRadius(16)

            Button {
                openShortcutsApp()
            } label: {
                HStack {
                    Image(systemName: "arrow.up.forward.app.fill")
                    Text(text("Open Shortcuts", "Открыть Команды"))
                }
                .font(.system(size: 15, weight: .bold))
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(16)
            }

            Button {
                antiDetectConfigured = true
                quickStatusMessage = text("Smart App Protection configured", "Умная защита приложений настроена")
                showAutoSetupGuide = false
            } label: {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                    Text(text("I Completed Setup", "Я завершил настройку"))
                }
                .font(.system(size: 15, weight: .bold))
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(Color(.secondarySystemGroupedBackground))
                .foregroundColor(.primary)
                .cornerRadius(16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.systemBackground))
        .cornerRadius(22)
    }

    private var setupFooter: some View {
        Text(text(
            "The automation must be confirmed by the user in iOS Shortcuts. iOS does not allow apps to create Personal Automations silently.",
            "Автоматизацию нужно подтвердить вручную в приложении Команды. iOS не позволяет приложениям создавать личные автоматизации без участия пользователя."
        ))
        .font(.system(size: 12, weight: .medium))
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)
        .padding(.bottom, 12)
    }

    private func setupStepCard(number: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(number)
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 32, height: 32)
                .background(Color.blue)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 16, weight: .bold))

                Text(text)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Color(.systemBackground))
        .cornerRadius(22)
    }

    private func quickActionButton(title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))

                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .background(color.opacity(0.13))
            .foregroundColor(color)
            .cornerRadius(16)
        }
    }

    private func infoRow(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 22)

            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.secondary)

            Spacer()

            Text(value.isEmpty ? "—" : value)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func sectionCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color(.systemBackground))
            .cornerRadius(22)
    }

    private var statusHeadline: String {
        if isVKTurnEngine {
            if hasConfirmedInternet {
                return text("Protected", "Защита включена")
            }

            if vkTunnel.status == .connected {
                return text("Waiting for network...", "Ожидание сети...")
            }
            if vkTunnel.preBootstrapInProgress || vkTunnel.status == .connecting || vkTunnel.status == .reasserting {
                return text("Connecting...", "Подключение...")
            }
            if vkTunnel.status == .disconnecting { return text("Disconnecting...", "Отключение...") }
            return text("VK TURN ready", "VK TURN готов")
        }

        if hasConfirmedInternet { return text("Protected", "Защита включена") }

        if isConnectedUI {
            return text("Waiting for network...", "Ожидание сети...")
        }

        switch vpnManager.state {
        case .preparing, .connecting:
            return text("Connecting...", "Подключение...")
        case .disconnecting:
            return text("Disconnecting...", "Отключение...")
        case .failed:
            return text("Connection error", "Ошибка подключения")
        default:
            return hasUsableConfig ? text("Ready to connect", "Готово к подключению") : text("No profile selected", "Профиль не выбран")
        }
    }

    private var statusSubtitle: String {
        if isVKTurnEngine {
            if vkTunnel.preBootstrapInProgress {
                return text("Preparing connection...", "Подготовка подключения...")
            }
            if hasConfirmedInternet {
                return text("VK TURN connection is working", "VK TURN соединение работает")
            }

            if vkTunnel.status == .connected {
                return text("Waiting for network...", "Ожидание сети...")
            }
            return text("VK TURN branch", "Ветка VK TURN")
        }

        if isConnectedUI {
            return selectedProfile?.displayName ?? text("VPN is active", "VPN активен")
        }

        if let selectedProfile {
            return selectedProfile.displayName
        }

        return text("Import a profile to start", "Импортируйте профиль, чтобы начать")
    }

    private var hasUsableConfig: Bool {
        if isVKTurnEngine {
            return true
        }

        return selectedProfile != nil
    }

    private var isConnectedUI: Bool {
        if isVKTurnEngine { return vkTunnel.status == .connected }
        return vpnManager.state == .connected
    }

    private var hasConfirmedInternet: Bool {
        if isVKTurnEngine {
            guard vkTunnel.status == .connected else { return false }

            if vkTunnel.stats.activeConns > 0 &&
                vkTunnel.stats.turnRTTms > 0 {
                return true
            }

            // Soft UI: during Wi-Fi/LTE handover the TURN channels may briefly
            // drop to 0 while the tunnel is still reconnecting. If we still have
            // a valid RTT, keep the UI from immediately jumping to yellow.
            if vkTunnel.stats.turnRTTms > 0 &&
                vkTunnel.stats.tunnelUptimeSec > 15 &&
                vkTunnel.stats.reconnects > 0 {
                return true
            }

            return false
        }

        return vpnManager.state == .connected &&
            (diagnostics.status == .success ||
             diagnostics.status == .slow)
    }

    private var isConnectingUI: Bool {
        if isVKTurnEngine {
            return vkTunnel.preBootstrapInProgress ||
                vkTunnel.status == .connecting ||
                vkTunnel.status == .reasserting ||
                (vkTunnel.status == .connected && !hasConfirmedInternet)
        }

        return vpnManager.state == .connecting ||
            vpnManager.state == .preparing ||
            (vpnManager.state == .connected && !hasConfirmedInternet)
    }

    private var isVPNBusy: Bool {
        if isVKTurnEngine {
            return vkTunnel.preBootstrapInProgress || vkTunnel.status == .connecting || vkTunnel.status == .disconnecting || vkTunnel.status == .reasserting
        }
        return vpnManager.state == .connecting ||
        vpnManager.state == .disconnecting ||
        vpnManager.state == .preparing
    }

    private var busyButtonTitle: String {
        switch vpnManager.state {
        case .disconnecting:
            return text("Disconnecting...", "Отключение...")
        case .preparing, .connecting:
            return text("Connecting...", "Подключение...")
        default:
            return isConnectedUI ? text("Disconnecting...", "Отключение...") : text("Connecting...", "Подключение...")
        }
    }

    private var primaryButtonColor: Color {
        if isConnectedUI { return .red }
        return .blue
    }

    private var statusColor: Color {
        if isConnectedUI { return .green }

        switch vpnManager.state {
        case .preparing, .connecting, .disconnecting:
            return .blue
        case .failed:
            return .red
        default:
            return .blue
        }
    }

    private var circleColor: Color {
        if vpnManager.state == .failed { return .red }

        if hasConfirmedInternet {
            return .green
        }

        if isConnectingUI {
            return Color.yellow
        }

        return .blue
    }

    private var statusMessageColor: Color {
        let lower = quickStatusMessage.lowercased()

        if lower.contains("failed") ||
            lower.contains("invalid") ||
            lower.contains("empty") ||
            lower.contains("error") ||
            lower.contains("ошибка") {
            return .red
        }

        if lower.contains("saved") ||
            lower.contains("updated") ||
            lower.contains("selected") ||
            lower.contains("imported") ||
            lower.contains("loaded") ||
            lower.contains("copied") ||
            lower.contains("настроена") ||
            lower.contains("скопирован") {
            return .green
        }

        return .secondary
    }

    private func toggleConnection() {
        guard !isVPNBusy else { return }

        connectionTask?.cancel()
        connectionTask = nil

        if isConnectedUI {
            connectionTask = Task {
                await vpnManager.stopVPN()

                if Task.isCancelled { return }

                await MainActor.run {
                    syncStatusFromVPNState()
                    connectionTask = nil
                }
            }
            return
        }

        if isVKTurnEngine {

            if vkTunnel.status == .connected || vkTunnel.status == .connecting || vkTunnel.preBootstrapInProgress {
                vkTunnel.disconnect()
                quickStatusMessage = "VK TURN disconnect requested"
                return
            }

            quickStatusMessage = text("Preparing connection...", "Подготовка подключения...")

            var config = TunnelConfig()
            config.privateKey = VKTurnSettings.privateKey
            config.peerPublicKey = VKTurnSettings.peerPublicKey
            config.peerAddress = VKTurnSettings.peerAddress
            config.vkLink = VKTurnSettings.vkLink
            config.tunnelAddress = VKTurnSettings.tunnelAddress
            config.dnsServers = VKTurnSettings.dnsServers.isEmpty ? "1.1.1.1" : VKTurnSettings.dnsServers
            config.allowedIPs = "0.0.0.0/0"
            config.mtu = "1280"
            config.persistentKeepalive = 25
            config.useDTLS = true
            config.useUDP = false
            config.useWrap = false
            config.useSrtp = false
            config.numConnections = max(1, VKTurnSettings.numConnections)

            connectionTask = Task {
                await vkTunnel.connect(config: config)

                await MainActor.run {
                    syncStatusFromVPNState()
                    connectionTask = nil
                }
            }

            return
        }

        guard let profile = selectedProfile else {
            statusText = text("No profile selected", "Профиль не выбран")
            return
        }

        connectionTask = Task {
            await vpnManager.startVPN(using: profile)

            if Task.isCancelled { return }

            await MainActor.run {
                syncStatusFromVPNState()
                connectionTask = nil
            }
        }
    }

    private func selectNextProfile() {
        guard !profileStore.profiles.isEmpty else { return }

        let profiles = profileStore.profiles

        guard let selectedProfile,
              let currentIndex = profiles.firstIndex(where: { $0.id == selectedProfile.id }) else {
            profileStore.selectProfile(id: profiles[0].id)
            quickStatusMessage = text("Profile selected", "Профиль выбран")
            syncFromSelectedProfile()
            return
        }

        let nextIndex = profiles.index(after: currentIndex) < profiles.endIndex
            ? profiles.index(after: currentIndex)
            : profiles.startIndex

        profileStore.selectProfile(id: profiles[nextIndex].id)
        quickStatusMessage = text("Profile selected", "Профиль выбран") + ": \(profiles[nextIndex].displayName)"
        syncFromSelectedProfile()
    }

    private func pasteConfigQuickly() {
        guard let clipboardText = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !clipboardText.isEmpty else {
            quickStatusMessage = text("Clipboard is empty", "Буфер обмена пуст")
            return
        }

        let configs = extractConfigs(from: clipboardText)

        guard !configs.isEmpty else {
            quickStatusMessage = text("Invalid config in clipboard", "Некорректный конфиг в буфере обмена")
            return
        }

        if configs.count == 1 {
            let result = profileStore.addOrUpdateProfile(from: configs[0])

            switch result {
            case .success(let upsert):
                switch upsert {
                case .inserted(let profile), .updated(let profile):
                    profileStore.selectProfile(id: profile.id)
                    quickStatusMessage = text("Profile saved from clipboard", "Профиль сохранён из буфера обмена")
                    syncFromSelectedProfile()
                }

            case .failure:
                quickStatusMessage = text("Invalid config in clipboard", "Некорректный конфиг в буфере обмена")
            }

            return
        }

        let result = profileStore.importSubscriptionConfigs(configs, subscriptionName: "Clipboard")
        quickStatusMessage = importMessage(prefix: text("Clipboard imported", "Импорт из буфера"), result: result)
        syncFromSelectedProfile()
    }

    private func updateSubscriptionSmartly() {
        let trimmedURL = configURL.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedURL.isEmpty else {
            quickStatusMessage = text(
                "Subscription URL is empty. Open Settings and add a subscription link.",
                "Ссылка подписки пуста. Откройте настройки и добавьте ссылку подписки."
            )
            showSettings = true
            return
        }

        updateSubscriptionQuickly()
    }

    private func updateSubscriptionQuickly() {
        let trimmedURL = configURL.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let url = URL(string: trimmedURL), !trimmedURL.isEmpty else {
            quickStatusMessage = text("Subscription URL is empty", "Ссылка подписки пуста")
            return
        }

        isUpdatingSubscription = true
        quickStatusMessage = text("Updating subscription...", "Обновление подписки...")

        var request = URLRequest(url: url)
        request.timeoutInterval = 30

        let trimmedToken = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedToken.isEmpty {
            request.setValue("Bearer \(trimmedToken)", forHTTPHeaderField: "Authorization")
            request.setValue(trimmedToken, forHTTPHeaderField: "X-Access-Token")
            request.setValue(trimmedToken, forHTTPHeaderField: "token")
        }

        URLSession.shared.dataTask(with: request) { data, _, error in
            DispatchQueue.main.async {
                isUpdatingSubscription = false

                if let error {
                    quickStatusMessage = error.localizedDescription
                    return
                }

                guard let data, !data.isEmpty else {
                    quickStatusMessage = text("Empty subscription response", "Пустой ответ подписки")
                    return
                }

                guard let responseText = decodeResponseText(from: data) else {
                    quickStatusMessage = text("Unable to decode subscription", "Не удалось прочитать подписку")
                    return
                }

                let configs = extractConfigs(from: responseText)

                guard !configs.isEmpty else {
                    quickStatusMessage = text("Invalid subscription", "Некорректная подписка")
                    return
                }

                let result = profileStore.importSubscriptionConfigs(
                    configs,
                    subscriptionName: subscriptionDisplayName(from: trimmedURL)
                )

                quickStatusMessage = importMessage(prefix: text("Subscription updated", "Подписка обновлена"), result: result)
                syncFromSelectedProfile()
            }
        }.resume()
    }

    private func openShortcutsApp() {
        guard let url = URL(string: "shortcuts://") else {
            quickStatusMessage = text("Unable to open Shortcuts", "Не удалось открыть Команды")
            return
        }

        UIApplication.shared.open(url) { success in
            DispatchQueue.main.async {
                quickStatusMessage = success ? text("Shortcuts opened", "Команды открыты") : text("Unable to open Shortcuts", "Не удалось открыть Команды")
            }
        }
    }


    private func cleanupStickyMessage() {
        let prep1 = text("Preparing connection...", "Подготовка подключения...")

        if hasConfirmedInternet && quickStatusMessage == prep1 {
            quickStatusMessage = ""
        }
    }

    private func clearStatus() {
        guard !isVPNBusy else { return }
        quickStatusMessage = ""
        vpnManager.clearError()
        syncStatusFromVPNState()
    }

    private func deleteSelectedProfile() {
        guard !isVPNBusy else { return }

        guard let selectedProfile else {
            syncFromSelectedProfile()
            statusText = text("Disconnected", "Отключено")
            return
        }

        profileStore.deleteProfile(id: selectedProfile.id)
        vpnManager.clearError()
        syncFromSelectedProfile()
        syncStatusFromVPNState()
    }

    private func refreshScreenState() {
        syncFromSelectedProfile()

        Task {
            await vpnManager.refreshStateFromSystem()

            await MainActor.run {
                syncStatusFromVPNState()
                updatePulseAnimation()
            }
        }
    }

    private func syncFromSelectedProfile() {
        guard let profile = selectedProfile else {
            parsedConfiguration = nil
            return
        }

        parsedConfiguration = TunnelConfiguration.build(from: profile.rawConfig)
    }

    private func syncStatusFromVPNState() {
        switch vpnManager.state {
        case .idle:
            statusText = hasUsableConfig ? text("Ready", "Готово") : text("Disconnected", "Отключено")
        case .preparing:
            statusText = text("Connecting...", "Подключение...")
        case .ready:
            statusText = text("Ready", "Готово")
        case .connecting:
            statusText = text("Connecting...", "Подключение...")
        case .connected:
            statusText = text("Connected", "Подключено")
        case .disconnecting:
            statusText = text("Disconnecting...", "Отключение...")
        case .disconnected:
            statusText = text("Disconnected", "Отключено")
        case .failed:
            if let message = vpnManager.lastError, !message.isEmpty {
                statusText = message
            } else {
                statusText = text("VPN failed", "Ошибка VPN")
            }
        }
    }

    private func updatePulseAnimation() {

    }

    private func decodeResponseText(from data: Data) -> String? {
        if let utf8 = String(data: data, encoding: .utf8),
           !utf8.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return utf8
        }

        if let ascii = String(data: data, encoding: .ascii),
           !ascii.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ascii
        }

        return nil
    }

    private func extractConfigs(from rawText: String) -> [String] {
        let cleaned = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return [] }

        if let decoded = decodeBase64Subscription(cleaned) {
            let decodedConfigs = extractPlainConfigs(from: decoded)
            if !decodedConfigs.isEmpty {
                return decodedConfigs
            }
        }

        let plainConfigs = extractPlainConfigs(from: cleaned)
        if !plainConfigs.isEmpty {
            return plainConfigs
        }

        if isSupportedConfig(cleaned) {
            return [cleaned]
        }

        return []
    }

    private func extractPlainConfigs(from text: String) -> [String] {
        text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { isSupportedConfig($0) }
    }

    private func isSupportedConfig(_ value: String) -> Bool {
        let lower = value.lowercased()

        return lower.hasPrefix("vless://") ||
        lower.hasPrefix("vmess://") ||
        lower.hasPrefix("trojan://") ||
        lower.hasPrefix("ss://") ||
        lower.hasPrefix("hysteria://") ||
        lower.hasPrefix("hy2://") ||
        lower.hasPrefix("{")
    }

    private func decodeBase64Subscription(_ text: String) -> String? {
        let normalized = text
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: " ", with: "")

        guard !normalized.isEmpty else { return nil }

        let padding = normalized.count % 4
        let padded: String

        if padding == 0 {
            padded = normalized
        } else {
            padded = normalized + String(repeating: "=", count: 4 - padding)
        }

        guard let data = Data(base64Encoded: padded),
              let decoded = String(data: data, encoding: .utf8),
              !decoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        return decoded
    }

    private func subscriptionDisplayName(from urlString: String) -> String {
        guard let url = URL(string: urlString),
              let host = url.host,
              !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Subscription"
        }

        return host
    }

    private func importMessage(prefix: String, result: SubscriptionImportResult) -> String {
        let success = result.successCount

        guard success > 0 else {
            return text("Invalid subscription", "Некорректная подписка")
        }

        var parts: [String] = []
        parts.append("\(success) \(text("profiles", "профилей"))")

        if result.insertedCount > 0 {
            parts.append("\(result.insertedCount) \(text("new", "новых"))")
        }

        if result.updatedCount > 0 {
            parts.append("\(result.updatedCount) \(text("replaced", "заменено"))")
        }

        if result.failedCount > 0 {
            parts.append("\(result.failedCount) \(text("failed", "ошибок"))")
        }

        return "\(prefix): " + parts.joined(separator: ", ")
    }
}

private extension View {
    func standardSheets(
        showSettings: Binding<Bool>,
        showProfilePicker: Binding<Bool>,
        showAutoSetupGuide: Binding<Bool>,
        showOnboarding: Binding<Bool>,
        autoAntiDetectSetupSheet: AnyView,
        onboardingSheet: AnyView
    ) -> some View {
        self
            .sheet(isPresented: showSettings) {
                NavigationStack {
                    SettingsView()
                }
            }
            .sheet(isPresented: showProfilePicker) {
                ProfilePickerView()
            }
            .sheet(isPresented: showAutoSetupGuide) {
                autoAntiDetectSetupSheet
            }
            .sheet(isPresented: showOnboarding) {
                onboardingSheet
            }
    }

    func standardAlerts(
        showVPNErrorAlert: Binding<Bool>,
        showDeleteProfileConfirmation: Binding<Bool>,
        vpnErrorMessage: String,
        errorTitle: String,
        deleteTitle: String,
        deleteMessage: String,
        deleteButtonTitle: String,
        cancelButtonTitle: String,
        clearError: @escaping () -> Void,
        deleteProfile: @escaping () -> Void
    ) -> some View {
        self
            .alert(errorTitle, isPresented: showVPNErrorAlert) {
                Button("OK", role: .cancel) {
                    clearError()
                }
            } message: {
                Text(vpnErrorMessage)
            }
            .alert(deleteTitle, isPresented: showDeleteProfileConfirmation) {
                Button(deleteButtonTitle, role: .destructive) {
                    deleteProfile()
                }

                Button(cancelButtonTitle, role: .cancel) {}
            } message: {
                Text(deleteMessage)
            }
    }
}

// MARK: - Captcha WebView (captures token via JS interception)

struct CaptchaWebView: View {
    let url: URL
    let captchaSID: String
    let onSolved: (String) -> Void
    let onDismiss: () -> Void
    let onLimitDetected: () -> Void
    let onCaptchaReady: () -> Void
    let onLog: (String) -> Void
    @ObservedObject var tunnel: TunnelManager

    // First-content-visible overlay state. Replaces the blank white WebView
    // that the user stares at while the captcha page is parsing <head> and
    // hasn't put any bytes in <body> yet — observed up to 86s on cold cache
    // in 2026-05-07 vpn-export-megafon.log (issue #5). Signal: JS heartbeat
    // posts body=N; transitioning from N==0 to N>0 means DOM has rendered
    // something. We also drop the overlay when didFinish fires, as a
    // fallback in case JS hooks didn't install.
    @State private var pageHasContent: Bool = false
    @State private var loadingStartedAt: Date = .init()
    @State private var elapsedSec: Int = 0
    private let tickTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Solve Captcha")
                    .font(.headline)
                Spacer()
                Button("Done") { onDismiss() }
                    .font(.headline)
            }
            .padding()

            ZStack {
                CaptchaWKWebView(
                    url: url,
                    onTokenCaptured: onSolved,
                    onLimitDetected: onLimitDetected,
                    onCaptchaReady: onCaptchaReady,
                    onLog: onLog,
                    onPageLoadStarted: {
                        pageHasContent = false
                        loadingStartedAt = Date()
                        elapsedSec = 0
                    },
                    onPageContentVisible: {
                        pageHasContent = true
                    }
                )

                // Loading overlay: shown while the WebView's body is still
                // empty (cold-cache subresource fetch hangs the parser).
                // Hides as soon as DOM renders any content. Without this
                // the user just sees a blank white square for up to 90s
                // and assumes the app is broken.
                if !pageHasContent {
                    VStack(spacing: 16) {
                        ProgressView().scaleEffect(1.3)
                        Text("Loading captcha…")
                            .font(.headline)
                        Text("\(elapsedSec)s")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                    .padding(32)
                    .background(Color(.systemBackground).opacity(0.97))
                    .cornerRadius(16)
                    .shadow(radius: 12)
                }

                // Overlay shown ONLY while auto-refresh is hunting for a fresh
                // captcha after JS detected "Attempt limit reached". Goes away
                // as soon as the WebView reloads to a working captcha (JS
                // posts state:ready → tunnel.onCaptchaReady → captchaLimitReached=false).
                if tunnel.captchaLimitReached {
                    VStack(spacing: 16) {
                        ProgressView().scaleEffect(1.3)
                        Text("VK временно не отдаёт капчу")
                            .font(.headline)
                        Text("Ищем рабочую — попытка \(tunnel.captchaRefreshAttempt) из \(tunnel.maxCaptchaRefreshAttempts)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(32)
                    .background(Color(.systemBackground).opacity(0.97))
                    .cornerRadius(16)
                    .shadow(radius: 12)
                }
            }
            .onReceive(tickTimer) { _ in
                if !pageHasContent {
                    elapsedSec = Int(Date().timeIntervalSince(loadingStartedAt))
                }
            }
        }
    }
}

struct CaptchaWKWebView: UIViewRepresentable {
    let url: URL
    let onTokenCaptured: (String) -> Void
    // Called when JS detector concludes the loaded page is in "Attempt limit
    // reached" state (no interactive element + error text). TunnelManager
    // uses this to start the auto-refresh timer.
    let onLimitDetected: () -> Void
    // Called when JS detector sees a normal interactive captcha. TunnelManager
    // uses this to stop any running auto-refresh timer.
    let onCaptchaReady: () -> Void
    // Routes log lines from the WKWebView coordinator (which lives in the
    // main-app process) into vpn.log — so raw JS bridge messages and
    // state-transition diagnostics land in the same log file as the
    // extension's output instead of only in os_log / Console.app.
    let onLog: (String) -> Void
    // Called when a fresh main-frame navigation starts (didStartProvisional).
    // Parent uses this to reset its loading-overlay state — show the
    // "Loading captcha…" spinner and start counting elapsed time.
    let onPageLoadStarted: () -> Void
    // Called once per navigation, the first moment we observe non-empty body
    // content (heartbeat reports body>0) or didFinish fires. Parent hides
    // the loading overlay on this signal.
    let onPageContentVisible: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onTokenCaptured: onTokenCaptured,
            onLimitDetected: onLimitDetected,
            onCaptchaReady: onCaptchaReady,
            onLog: onLog,
            onPageLoadStarted: onPageLoadStarted,
            onPageContentVisible: onPageContentVisible
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true

        // Use an ephemeral data store so every CaptchaWKWebView instance starts
        // with a clean cookie jar. VK's anti-abuse cookies otherwise persist
        // across WebView recreations and cause the captcha page to return a
        // pre-solved state ("green checkmark on open"), which leaves the user
        // stuck — JS hooks never fire because the solve flow never runs.
        config.websiteDataStore = WKWebsiteDataStore.nonPersistent()

        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "captchaToken")

        // Approach based on https://github.com/cacggghp/vk-turn-proxy/pull/97:
        // Load the captcha page directly (top-level, no iframe needed).
        // Intercept fetch/XHR to captchaNotRobot.check — the response contains
        // success_token which is what VK needs for the retry.
        // No need for postMessage interception or iframe wrapper.
        let js = """
        (function() {
            var h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.captchaToken;
            if (!h) return;

            // Helper: extract whichever of device + browser_fp are non-empty
            // from a form-encoded body and post 'profile-capture:' to Swift.
            // Empirically (vpn.wifi.[1-3].log 2026-05-08): VK's
            // captchaNotRobot.componentDone body has device populated but
            // browser_fp EMPTY. browser_fp gets a real value only in the
            // captchaNotRobot.check body — so we have to intercept BOTH
            // requests and accumulate fields across them. Swift side
            // merges via VKProfileCache.update (preserves existing field
            // on empty input).
            function captureProfileFromBody(bodyStr, source) {
                try {
                    if (!bodyStr) {
                        h.postMessage('profile-capture-err:empty body (' + source + ')');
                        return;
                    }
                    var fields = [];
                    var deviceMatch = /(?:^|&)device=([^&]*)/.exec(bodyStr);
                    if (deviceMatch && deviceMatch[1].length > 0) {
                        fields.push('device=' + deviceMatch[1]);
                    }
                    var fpMatch = /(?:^|&)browser_fp=([^&]*)/.exec(bodyStr);
                    if (fpMatch && fpMatch[1].length > 0) {
                        fields.push('browser_fp=' + fpMatch[1]);
                    }
                    if (fields.length === 0) {
                        h.postMessage('profile-capture-err:both fields empty/absent in body len=' + bodyStr.length + ' (' + source + ')');
                        return;
                    }
                    fields.push('ua=' + encodeURIComponent(navigator.userAgent || ''));
                    h.postMessage('profile-capture:' + fields.join('&'));
                } catch (e) {
                    h.postMessage('profile-capture-err:' + e.message + ' (' + source + ')');
                }
            }

            // Hook fetch to intercept:
            //   - captchaNotRobot.check RESPONSE (for success_token)
            //   - captchaNotRobot.check REQUEST body (for browser_fp)
            //   - captchaNotRobot.componentDone REQUEST body (for device)
            // Profile fields accumulate on the Swift side via
            // VKProfileCache.update — componentDone gives device, check
            // gives browser_fp; merging produces a complete saved profile.
            var origFetch = window.fetch;
            window.fetch = function() {
                var url = arguments[0];
                var init = arguments[1];
                if (typeof url === 'object' && url.url) url = url.url;
                var urlStr = String(url);
                var p = origFetch.apply(this, arguments);
                if (urlStr.indexOf('captchaNotRobot.check') !== -1) {
                    captureProfileFromBody(init && init.body ? String(init.body) : '', 'fetch-check');
                    p.then(function(response) {
                        return response.clone().json();
                    }).then(function(data) {
                        h.postMessage('check:' + JSON.stringify(data).substring(0, 1000));
                        if (data.response && data.response.success_token) {
                            h.postMessage('token:' + data.response.success_token);
                        } else if (data.response && data.response.status === 'ERROR_LIMIT') {
                            // VK explicitly said "rate limited". Trigger auto-refresh
                            // immediately — don't wait for the 2.5s DOM heuristic
                            // (which would miss the limit state that only appears
                            // AFTER the user clicks the checkbox and the page
                            // dynamically switches to the error screen).
                            h.postMessage('state:limit:api_error_limit');
                        }
                    }).catch(function(e) {
                        h.postMessage('check-err:' + e.message);
                    });
                }
                if (urlStr.indexOf('captchaNotRobot.componentDone') !== -1) {
                    captureProfileFromBody(init && init.body ? String(init.body) : '', 'fetch-componentDone');
                }
                return p;
            };

            // Hook XMLHttpRequest as fallback (same triple capture as fetch).
            var origOpen = XMLHttpRequest.prototype.open;
            var origSend = XMLHttpRequest.prototype.send;
            XMLHttpRequest.prototype.open = function(method, url) {
                this._url = url;
                return origOpen.apply(this, arguments);
            };
            XMLHttpRequest.prototype.send = function() {
                var xhr = this;
                var urlStr = this._url ? String(this._url) : '';
                if (urlStr.indexOf('captchaNotRobot.componentDone') !== -1) {
                    captureProfileFromBody(arguments[0] ? String(arguments[0]) : '', 'xhr-componentDone');
                }
                if (urlStr.indexOf('captchaNotRobot.check') !== -1) {
                    captureProfileFromBody(arguments[0] ? String(arguments[0]) : '', 'xhr-check');
                    xhr.addEventListener('load', function() {
                        try {
                            var data = JSON.parse(xhr.responseText);
                            h.postMessage('xhr-check:' + JSON.stringify(data).substring(0, 1000));
                            if (data.response && data.response.success_token) {
                                h.postMessage('token:' + data.response.success_token);
                            } else if (data.response && data.response.status === 'ERROR_LIMIT') {
                                // Same as fetch path: VK hard-rate-limited us,
                                // trigger auto-refresh without waiting for the
                                // DOM heuristic.
                                h.postMessage('state:limit:api_error_limit');
                            }
                        } catch(e) {}
                    });
                }
                return origSend.apply(this, arguments);
            };

            h.postMessage('init:hooks installed');

            // Page-state detector: 2.5s after first render, look at whether
            // VK showed us an interactive captcha or an "Attempt limit reached"
            // (or equivalent) error. Post state:limit / state:ready to Swift —
            // TunnelManager runs the auto-refresh timer only on state:limit.
            function checkCaptchaState(source) {
                try {
                    var text = (document.body && document.body.innerText) || '';
                    var hasLimitText = /limit.*reached|лимит.*исчерп|превышен|try\\s*again\\s*later|attempt\\s*limit/i.test(text);
                    var hasInteractive = !!document.querySelector(
                        '[role="checkbox"], input[type="checkbox"], .VkIdNotRobotButton, [data-test-id*="captcha"], .vkuiCheckbox'
                    );
                    var state;
                    if (hasLimitText) {
                        state = 'limit';
                    } else if (hasInteractive) {
                        state = 'ready';
                    } else {
                        state = 'unknown';
                    }
                    h.postMessage('state:' + state + ':' + source);
                } catch (e) {
                    h.postMessage('state-err:' + e.message);
                }
            }

            // Run initial detection once DOM is ready + a 2.5s settle.
            function scheduleInitialDetection() {
                setTimeout(function() { checkCaptchaState('initial'); }, 2500);
            }
            if (document.readyState === 'complete' || document.readyState === 'interactive') {
                scheduleInitialDetection();
            } else {
                window.addEventListener('DOMContentLoaded', scheduleInitialDetection);
            }

            // Diagnostic heartbeat: every 1s while page hasn't reached
            // 'complete', post readyState + content sizes. Diagnoses the
            // "white captcha" symptom from issue #5 — when WKWebView
            // navigates but no didFinish/didFail fires, we need to know
            // whether DOM is stuck in 'loading', sitting empty in
            // 'interactive', or what. Stops itself on 'complete' or after
            // 180s (whichever first) so it can't spam the log indefinitely.
            // The 180s cap covers the worst observed cold-cache load
            // (86s on issue #5 vpn-export-megafon.log, build 49) with
            // headroom — earlier 60s cap cut visibility short.
            (function() {
                var startTime = Date.now();
                var heartbeatId = setInterval(function() {
                    var elapsed = Date.now() - startTime;
                    var ready = document.readyState || 'null';
                    var bodyLen = (document.body && document.body.innerHTML.length) || 0;
                    var titleLen = (document.title || '').length;
                    var url = (location && location.href || '').substring(0, 80);
                    h.postMessage('heartbeat:elapsed=' + elapsed + 'ms readyState=' + ready
                        + ' body=' + bodyLen + ' title=' + titleLen + ' url=' + url);
                    if (ready === 'complete' || elapsed > 180000) {
                        clearInterval(heartbeatId);
                    }
                }, 1000);
            })();

            // Diagnostic: log per-resource timing as it completes. Reveals
            // exactly which subresource(s) hang during cold-cache slow
            // first-load (issue #5 — body=0 for 60-86s while parser is
            // blocked on a synchronous <script src>). Each fetched
            // resource gets one log line with DNS / TCP / TLS / TTFB /
            // body-bytes phases broken out — so we can tell whether the
            // bottleneck is name resolution, connection setup, or actual
            // bytes flowing slow. Stays on for the lifetime of the page;
            // overhead is one postMessage per resource (~10-30 per
            // captcha load, manageable). Query strings stripped from
            // names for log brevity, names truncated at 120 chars.
            if (typeof PerformanceObserver !== 'undefined') {
                try {
                    var po = new PerformanceObserver(function(list) {
                        list.getEntries().forEach(function(entry) {
                            if (entry.entryType !== 'resource') return;
                            var name = entry.name || '';
                            var qIdx = name.indexOf('?');
                            if (qIdx > 0) name = name.substring(0, qIdx);
                            if (name.length > 120) name = name.substring(0, 120) + '...';
                            var dns = Math.round(entry.domainLookupEnd - entry.domainLookupStart);
                            var tcp = Math.round(entry.connectEnd - entry.connectStart);
                            var tls = entry.secureConnectionStart > 0
                                ? Math.round(entry.connectEnd - entry.secureConnectionStart)
                                : 0;
                            var ttfb = Math.round(entry.responseStart - entry.requestStart);
                            var bodyMs = Math.round(entry.responseEnd - entry.responseStart);
                            var total = Math.round(entry.duration);
                            var size = entry.transferSize || 0;
                            h.postMessage('perf:' + (entry.initiatorType || '?')
                                + ' total=' + total + 'ms'
                                + ' dns=' + dns + 'ms'
                                + ' tcp=' + tcp + 'ms'
                                + ' tls=' + tls + 'ms'
                                + ' ttfb=' + ttfb + 'ms'
                                + ' bodyMs=' + bodyMs + 'ms'
                                + ' size=' + size + 'B'
                                + ' name=' + name);
                        });
                    });
                    po.observe({entryTypes: ['resource']});
                } catch (e) {
                    h.postMessage('perf-err:' + e.message);
                }
            } else {
                h.postMessage('perf-err:PerformanceObserver unavailable');
            }

            // Catch JS errors and unhandled promise rejections so we can
            // see if the page is failing on its own scripts (e.g. a
            // sub-resource referenced by VK's captcha JS that the
            // network blocks).
            window.addEventListener('error', function(e) {
                var src = (e.filename || '?');
                if (src.length > 80) src = src.substring(0, 80) + '…';
                h.postMessage('js-error:' + (e.message || 'unknown')
                    + ' at ' + src + ':' + (e.lineno || '?'));
            });
            window.addEventListener('unhandledrejection', function(e) {
                var reason = e.reason ? String(e.reason).substring(0, 200) : 'unknown';
                h.postMessage('js-rejection:' + reason);
            });
        })();
        """
        let userScript = WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        contentController.addUserScript(userScript)
        config.userContentController = contentController

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

        // iOS 16.4+ no longer auto-enables Safari Web Inspector for WKWebViews
        // even in Debug builds; explicit opt-in required. Wrapped in #if DEBUG
        // so Release/TestFlight IPAs don't expose the WebView to USB-attached
        // dev tools. Enables: Mac Safari → Develop → iPhone → captcha WebView,
        // then Network tab shows the real HTTP/2 headers Safari mobile sends
        // to id.vk.ru. Needed for matching our Go-side PoW client to the
        // captured Safari fingerprint.
        #if DEBUG
        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }
        #endif

        // Load captcha URL directly — no iframe needed
        context.coordinator.lastLoadedURL = url.absoluteString
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // When VK rejects a success_token and the Go side fetches a fresh
        // captcha URL, SwiftUI rebinds this view with a new `url` but keeps
        // the same underlying WKWebView alive. Without an explicit reload the
        // user sees the stale page (still showing the green checkmark from
        // the previous solve) and has no way to interact — the only escape
        // is pressing Done. Detect the URL change and reload so the new
        // captcha appears automatically.
        let newURLStr = url.absoluteString
        if context.coordinator.lastLoadedURL != newURLStr {
            context.coordinator.log("URL changed, reloading WebView (\(String(newURLStr.prefix(80))))")
            context.coordinator.lastLoadedURL = newURLStr
            context.coordinator.resetForNewCaptcha()
            uiView.load(URLRequest(url: url))
        }
    }

    class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let onTokenCaptured: (String) -> Void
        let onLimitDetected: () -> Void
        let onCaptchaReady: () -> Void
        let onLog: (String) -> Void
        let onPageLoadStarted: () -> Void
        let onPageContentVisible: () -> Void
        private var solved = false
        // One-shot guard for onPageContentVisible — first heartbeat with
        // body>0 (or didFinish, whichever first) fires it; subsequent
        // heartbeats stay quiet. Reset on every fresh navigation.
        private var contentVisibleFired = false
        weak var webView: WKWebView?
        // Tracks which URL we last handed to `webView.load(...)`. Used by
        // updateUIView to detect real URL changes vs. SwiftUI re-renders with
        // the same state — avoids redundant reloads.
        var lastLoadedURL: String?

        init(
            onTokenCaptured: @escaping (String) -> Void,
            onLimitDetected: @escaping () -> Void,
            onCaptchaReady: @escaping () -> Void,
            onLog: @escaping (String) -> Void,
            onPageLoadStarted: @escaping () -> Void,
            onPageContentVisible: @escaping () -> Void
        ) {
            self.onTokenCaptured = onTokenCaptured
            self.onLimitDetected = onLimitDetected
            self.onCaptchaReady = onCaptchaReady
            self.onLog = onLog
            self.onPageLoadStarted = onPageLoadStarted
            self.onPageContentVisible = onPageContentVisible
        }

        func log(_ msg: String) {
            // os_log / NSLog visible in Console.app when device is connected
            // to a Mac (useful for live debugging). onLog tunnels the same
            // message through TunnelManager → extension → vpn.log so
            // post-mortem analysis from a vpn.log dump is possible too.
            os_log("%{public}s", log: captchaLog, type: .default, msg)
            NSLog("[Captcha] %@", msg)
            onLog(msg)
        }

        // Called by updateUIView when the captcha URL changes mid-flight
        // (VK rejected a success_token and Go fetched a fresh captcha).
        // Resets the one-shot `solved` guard so the next success_token from
        // the new page is forwarded to the tunnel — otherwise the guard would
        // silently swallow every token after the first. Also resets the
        // contentVisibleFired guard so the loading overlay shows again
        // for the new page.
        func resetForNewCaptcha() {
            solved = false
            contentVisibleFired = false
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? String else { return }
            log("JS: \(String(body.prefix(400)))")

            // First non-empty body in a heartbeat fires onPageContentVisible
            // exactly once per navigation, dropping the loading overlay.
            // Heartbeat format: "heartbeat:elapsed=Xms readyState=Y body=N title=M url=..."
            if !contentVisibleFired && body.hasPrefix("heartbeat:") {
                if let r = body.range(of: "body=") {
                    let after = body[r.upperBound...]
                    let digits = after.prefix(while: { $0.isNumber })
                    if let n = Int(digits), n > 0 {
                        contentVisibleFired = true
                        DispatchQueue.main.async { self.onPageContentVisible() }
                    }
                }
            }

            if body.hasPrefix("token:") {
                let token = String(body.dropFirst(6))
                log("SUCCESS_TOKEN (\(token.count) chars)")
                captureToken(token)
                return
            }

            // Browser-profile capture from intercepted VK API request bodies.
            // Format: "profile-capture:[device=URLENC&][browser_fp=URLENC&]ua=URLENC".
            // device and browser_fp are OPTIONAL (each captured from a
            // different request type — componentDone has device, check has
            // browser_fp). Empty/absent fields are not overwritten on disk;
            // VKProfileCache.update merges with whatever's already saved.
            //
            // Important: device and browser_fp are stored in their RAW
            // URL-encoded form (as VK's JS originally serialized them
            // into the request body). Go-side splices them back into a
            // form-encoded body verbatim — re-encoding would double-escape.
            // Only `ua` (which we add ourselves via encodeURIComponent in
            // JS) gets percent-decoded for human-readable storage.
            if body.hasPrefix("profile-capture:") {
                let payload = String(body.dropFirst("profile-capture:".count))
                var raw: [String: String] = [:]
                for pair in payload.split(separator: "&") {
                    let kv = pair.split(separator: "=", maxSplits: 1)
                    if kv.count == 2 {
                        raw[String(kv[0])] = String(kv[1])
                    }
                }
                let deviceRaw = raw["device"] ?? ""
                let browserFpRaw = raw["browser_fp"] ?? ""
                let uaDecoded = (raw["ua"] ?? "").removingPercentEncoding ?? ""
                log("profile-capture received: device=\(deviceRaw.count)c browser_fp=\(browserFpRaw.count)c ua=\(uaDecoded.count)c")
                VKProfileCache.update(device: deviceRaw, browserFp: browserFpRaw, userAgent: uaDecoded)
                return
            }
            if body.hasPrefix("profile-capture-err:") {
                log("profile capture error: \(String(body.dropFirst("profile-capture-err:".count)))")
                return
            }

            // State detector posts `state:<kind>:<source>` — e.g.
            // "state:limit:initial" or "state:ready:initial". We react to
            // `limit` and `ready` kinds; `unknown` is logged for diagnostics
            // but no action taken (auto-refresh doesn't start on unknown to
            // avoid refresh loops on unrecognised layouts).
            if body.hasPrefix("state:") {
                let parts = body.split(separator: ":", maxSplits: 2).map(String.init)
                let kind = parts.count >= 2 ? parts[1] : ""
                switch kind {
                case "limit":
                    log("state=limit — delegating to auto-refresh handler")
                    DispatchQueue.main.async { self.onLimitDetected() }
                case "ready":
                    log("state=ready — delegating to stop-auto-refresh handler")
                    DispatchQueue.main.async { self.onCaptchaReady() }
                case "unknown":
                    log("state=unknown — no action (no interactive element and no known limit text)")
                default:
                    log("state=<unrecognised kind \(kind)>")
                }
                return
            }
        }

        private func captureToken(_ token: String) {
            guard !solved else { return }
            solved = true
            log("TOKEN CAPTURED (\(token.count) chars), sending to tunnel")
            DispatchQueue.main.async {
                self.onTokenCaptured(token)
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url {
                log("Nav: \(String(url.absoluteString.prefix(200)))")
            }
            decisionHandler(.allow)
        }

        // Diagnostic: confirms the request was actually sent to the server
        // (between Nav (decision) and didStartProvisional (sent on the wire)
        // there's a window where iOS could drop the request without firing
        // any other event). Added 2026-05-07 for issue #5 "white captcha"
        // diagnosis — vpn.from.github.1.log on build 48 had Nav fire then
        // 7.4s of silence with no Loaded / didFail. Need to know which
        // network-layer stage hangs.
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            log("StartProvisional: request sent on wire")
            // Fresh main-frame navigation — reset the loading overlay state
            // so the parent view shows the spinner again for this attempt.
            // Iframe / subresource navigations don't fire this delegate
            // method, so this fires exactly once per top-level captcha load.
            contentVisibleFired = false
            DispatchQueue.main.async { self.onPageLoadStarted() }
        }

        // Diagnostic: HTTP redirect mid-navigation. Logged so we can see if
        // VK is sending us through some redirect chain that hangs.
        func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
            log("Redirect: \(String((webView.url?.absoluteString ?? "nil").prefix(200)))")
        }

        // Diagnostic: response headers received, body about to start. If
        // didCommit fires but didFinish doesn't, the body load is hanging
        // (server stops sending / TLS issue / sub-resource block). If
        // didCommit doesn't fire at all, the request is stuck before
        // headers arrived (TCP / TLS handshake / server unresponsive).
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            log("Commit: response headers received")
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            let nsErr = error as NSError
            log("FAIL: \(error.localizedDescription) (domain=\(nsErr.domain) code=\(nsErr.code))")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            let nsErr = error as NSError
            log("FAIL provisional: \(error.localizedDescription) (domain=\(nsErr.domain) code=\(nsErr.code))")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            log("Loaded: \(String((webView.url?.absoluteString ?? "nil").prefix(150)))")
            // Fallback: if heartbeat never reported body>0 (e.g. JS hooks
            // failed to install for some reason), at least drop the
            // loading overlay when the page fully loads.
            if !contentVisibleFired {
                contentVisibleFired = true
                DispatchQueue.main.async { self.onPageContentVisible() }
            }
        }
    }
}

// MARK: - Logs View

struct LogsView: View {
    @ObservedObject var tunnel: TunnelManager
    @State private var logText = ""
    @State private var autoScroll = true
    @State private var showShareSheet = false
    @State private var usingOSLogFallback = false
    // Cached fallback content + last-fetch timestamp + in-flight guard.
    // Without these the fallback path (OSLogReader.readOwnLogs +
    // sendProviderMessage) ran on EVERY 2-second timer tick whenever the
    // file was empty, blocking the main thread on the synchronous
    // OSLogStore query for hundreds of milliseconds-to-seconds depending
    // on ring-buffer size. Symptom: tapping "Clear" emptied the file,
    // then the UI lagged badly because every tick re-ran the heavy
    // fallback query. With caching: query runs at most once per
    // fallbackTTL seconds, off the main thread.
    @State private var fallbackText: String = ""
    @State private var fallbackFetchedAt: Date = .distantPast
    @State private var fallbackInFlight = false
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    private let fallbackTTL: TimeInterval = 4.0

    /// Maximum characters to display — keeps UI responsive.
    /// The full file is still available via Share.
    private let maxDisplayChars = 100_000

    var body: some View {
        VStack(spacing: 0) {
            LogTextView(text: logText, autoScroll: autoScroll)

            Divider()

            HStack {
                Toggle("Auto-scroll", isOn: $autoScroll)
                    .font(.caption)
                    .toggleStyle(.switch)
                    .fixedSize()

                Spacer()

                Button(action: {
                    SharedLogger.shared.clearLogs()
                    // Wipe the fallback cache too — otherwise after
                    // clearing the on-disk log the next loadLogs() tick
                    // would still show the stale cached fallback content
                    // until the TTL elapses, which looks like Clear
                    // didn't work.
                    fallbackText = ""
                    fallbackFetchedAt = .distantPast
                    logText = ""
                }) {
                    Label("Clear", systemImage: "trash")
                        .font(.caption)
                }

                Button(action: { showShareSheet = true }) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .font(.caption)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .navigationTitle("Logs")
        .onAppear { loadLogs() }
        .onReceive(timer) { _ in loadLogs() }
        .sheet(isPresented: $showShareSheet) {
            // Export the COMBINED log (archive .1 + current) as a single
            // temp file so the user gets the full history, not just the
            // tail since the last rotation. If SharedLogger is empty
            // (App Group unavailable), Share the os_log fallback text
            // by writing it to a temp file first so the user can still
            // attach a log file to a bug report.
            if let url = exportShareableLogURL(),
               FileManager.default.fileExists(atPath: url.path) {
                ShareSheet(activityItems: [url])
            }
        }
    }

    private func loadLogs() {
        let fileText = SharedLogger.shared.readLogs()
        if !fileText.isEmpty {
            usingOSLogFallback = false
            logText = truncated(fileText)
            return
        }
        // Empty result. Distinguish "intentionally empty" (Clear was
        // pressed, or extension just rotated/started) from "broken"
        // (App Group container unreachable, or the file never existed).
        // The first case is normal user state — Clear is used routinely
        // — and showing a fallback banner there surprises the user with
        // os_log content unrelated to the fresh-start they just asked
        // for. Only fall back when the file storage itself is missing.
        let status = SharedLogger.shared.inspectStorage()
        if status.hasContainer && status.currentExists {
            usingOSLogFallback = false
            // Wipe stale fallback cache so a subsequent failure path
            // doesn't render leftover content.
            fallbackText = ""
            fallbackFetchedAt = .distantPast
            logText = "(log is empty — waiting for new activity)"
            return
        }

        // Genuine fallback: no container (entitlement / provisioning
        // issue) or file never existed (fresh install before any
        // SharedLogger.log call landed). Read per-process os_log: main
        // app reads its own ring buffer, extension reads its own via
        // providerMessage. Surface a banner explaining the source.
        //
        // Both the OSLogStore query and the providerMessage round-trip
        // can take hundreds of milliseconds each — running them on every
        // 2-second timer tick on the main thread caused noticeable UI
        // lag. So: cache the result for `fallbackTTL` seconds, refresh
        // in a background task, and only one fetch may be in flight at
        // a time.
        usingOSLogFallback = true

        // Show last-cached content immediately if we have any; otherwise
        // a minimal placeholder so the user knows fetching is in progress.
        if !fallbackText.isEmpty {
            logText = truncated(fallbackText)
        } else if logText.isEmpty {
            logText = "Loading os_log fallback…"
        }

        let cacheStale = Date().timeIntervalSince(fallbackFetchedAt) > fallbackTTL
        guard !fallbackInFlight && cacheStale else { return }
        fallbackInFlight = true

        Task.detached(priority: .userInitiated) {
            // OSLogReader.readOwnLogs is the heavy synchronous call —
            // running it on a detached task moves it off the main thread.
            // Subsequent awaits (providerMessage, MainActor.run) come
            // back to MainActor naturally because tunnel is @MainActor.
            let mainAppLogs = OSLogReader.readOwnLogs(maxAge: 1800)
            let extensionLogs = await tunnel.fetchExtensionOSLogs() ?? ""

            // Pick a precise banner reason from SharedLogger storage state
            // instead of conflating "container unavailable" with "file empty"
            // and "file unreadable" — each has a different cause and remedy.
            // Also include container path so the reader can compare with
            // wgSetLogFilePath in the extension's os_log output (mismatching
            // paths would indicate a provisioning/entitlement skew between
            // main app and extension processes).
            let status = SharedLogger.shared.inspectStorage()
            let reason: String
            if !status.hasContainer {
                reason = "App Group container unavailable to main app (entitlement missing or provisioning issue)"
            } else if !status.currentExists && !status.archivedExists {
                reason = "Log file doesn't exist yet at \(status.containerPath)/vpn.log (fresh install or container reset)"
            } else if status.currentBytes == 0 && status.archivedBytes <= 0 {
                reason = "Log file is empty (\(status.containerPath)/vpn.log: 0 bytes; recently cleared, or extension hasn't written since clear)"
            } else if status.currentBytes < 0 {
                reason = "Log file unreadable despite existing (\(status.containerPath)/vpn.log; permissions / corruption?)"
            } else {
                reason = "Log file present but readLogs returned empty (current=\(status.currentBytes)B, archived=\(status.archivedBytes)B at \(status.containerPath))"
            }

            var combined = mainAppLogs + extensionLogs
            if combined.isEmpty {
                combined = "No logs available.\n\nReason: \(reason)\n\n" +
                    "Try reconnecting the tunnel, or — if the issue persists — " +
                    "Reset TURN Cache and reconnect to force a fresh log session."
            } else {
                combined = "⚠️ Showing os_log fallback (recent ~30 min only, " +
                    "may be incomplete and out of order).\n" +
                    "Reason: \(reason)\n\n" +
                    combined
            }

            await MainActor.run {
                fallbackText = combined
                fallbackFetchedAt = Date()
                fallbackInFlight = false
                if usingOSLogFallback {
                    logText = truncated(combined)
                }
            }
        }
    }

    private func truncated(_ text: String) -> String {
        guard text.count > maxDisplayChars else { return text }
        let startIndex = text.index(text.endIndex, offsetBy: -maxDisplayChars)
        return "… (truncated)\n" + String(text[startIndex...])
    }

    /// Decide what URL to hand to the Share sheet. Default path: the
    /// file-backed export (archive + current). Fallback path: write
    /// the current `logText` (which is the os_log fallback view) to
    /// a temp file so the user can still attach a log to a bug report
    /// even when the App Group file is empty.
    private func exportShareableLogURL() -> URL? {
        if let url = SharedLogger.shared.exportSnapshotURL(),
           let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int, size > 0 {
            return url
        }
        // SharedLogger empty — write the on-screen fallback text to a
        // temp file so Share has something to attach.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("vpn-export-oslog.log")
        try? logText.write(to: tmp, atomically: true, encoding: .utf8)
        return FileManager.default.fileExists(atPath: tmp.path) ? tmp : nil
    }
}

/// UITextView wrapper — handles large text without SwiftUI layout explosion.
struct LogTextView: UIViewRepresentable {
    let text: String
    let autoScroll: Bool

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.font = UIFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        tv.textColor = .label
        tv.backgroundColor = .systemBackground
        tv.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        // Only update if text actually changed to avoid unnecessary work
        if tv.text != text {
            tv.text = text
            if autoScroll && !text.isEmpty {
                let bottom = NSRange(location: text.count - 1, length: 1)
                tv.scrollRangeToVisible(bottom)
            }
        }
    }
}

/// UIActivityViewController wrapper for sharing the log file.
struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#Preview {
    ContentView()
}

private func formatUptime(_ seconds: Int) -> String {
    let h = seconds / 3600

    let m = (seconds % 3600) / 60
    let s = seconds % 60
    return String(format: "%02d:%02d:%02d", h, m, s)
}

