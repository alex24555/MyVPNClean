import SwiftUI
import UIKit

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
        .onDisappear {
            connectionTask?.cancel()
            connectionTask = nil
        }
    }

    private var mainScreen: some View {
        ScrollView {
            VStack(spacing: 22) {
                headerSection
                statusCircleSection
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
        ZStack {
            if isConnectingUI {
                Circle()
                    .stroke(circleColor.opacity(0.18), lineWidth: 10)
                    .frame(width: animatePulse ? 188 : 160, height: animatePulse ? 188 : 160)
                    .opacity(animatePulse ? 0.18 : 0.55)
                    .animation(
                        .easeInOut(duration: 1.1).repeatForever(autoreverses: true),
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
        .frame(height: 190)
        .frame(maxWidth: .infinity)
    }

    private var mainActionSection: some View {
        VStack(spacing: 12) {
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
                    Image(systemName: diagnosticsIcon)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(diagnosticsColor)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(text("Connection Check", "Проверка соединения"))
                            .font(.system(size: 16, weight: .bold))

                        Text(diagnosticsStatusText)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    if diagnostics.status == .checking {
                        ProgressView()
                    }
                }

                Divider()

                infoRow(icon: "timer", title: text("Latency", "Задержка"), value: diagnostics.latencyText)
                infoRow(icon: "network", title: text("External IP", "Внешний IP"), value: diagnostics.externalIP)
                infoRow(icon: "clock", title: text("Last check", "Последняя проверка"), value: diagnostics.lastCheckedText)

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
            return .orange
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
            VStack(spacing: 22) {
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
        if isConnectedUI { return text("Protected", "Защита включена") }

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
        if isConnectedUI {
            return selectedProfile?.displayName ?? text("VPN is active", "VPN активен")
        }

        if let selectedProfile {
            return selectedProfile.displayName
        }

        return text("Import a profile to start", "Импортируйте профиль, чтобы начать")
    }

    private var hasUsableConfig: Bool {
        let currentEngine =
            UserDefaults.standard.string(forKey: "vpnEngineKind") ?? vpnEngineKind

        if currentEngine == "packetTunnelVKTurn" {
            return true
        }

        return selectedProfile != nil
    }

    private var isConnectedUI: Bool {
        vpnManager.state == .connected
    }

    private var isConnectingUI: Bool {
        vpnManager.state == .connecting || vpnManager.state == .preparing
    }

    private var isVPNBusy: Bool {
        vpnManager.state == .connecting ||
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
        return hasUsableConfig ? .blue : .gray
    }

    private var statusColor: Color {
        if isConnectedUI { return .green }

        switch vpnManager.state {
        case .preparing, .connecting, .disconnecting:
            return .blue
        case .failed:
            return .red
        default:
            return hasUsableConfig ? .blue : .gray
        }
    }

    private var circleColor: Color {
        if vpnManager.state == .failed { return .red }
        return isConnectedUI ? .green : .blue
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

        if vpnEngineKind == "packetTunnelVKTurn" {

            quickStatusMessage = "Starting VK TURN branch"

            let fakeProfile = VPNProfile(
                id: UUID(),
                name: "VK TURN",
                rawConfig: "vkturn://local",
                normalizedConfig: "vkturn://local",
                kind: .json,
                serverAddress: VKTurnSettings.peerAddress,
                remark: "VK TURN"
            )

            connectionTask = Task {
                await vpnManager.startVPN(using: fakeProfile)
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
        animatePulse = isConnectingUI
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

#Preview {
    ContentView()
}
