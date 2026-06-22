import SwiftUI
import UIKit

struct RemoteVKTurnSetup: Codable {
    let engine: String
    let profileName: String?
    let vkLink: String
    let peerAddress: String
    let privateKey: String
    let peerPublicKey: String
    let tunnelAddress: String?
    let dnsServers: String?
    let numConnections: Int?
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage("configURL") private var configURL = ""
    @AppStorage("accessToken") private var accessToken = ""
    @AppStorage("vpnEngineKind") private var vpnEngineKindRawValue =
        "packetTunnel"

    @StateObject private var store = VPNProfileStore.shared

    @State private var manualConfigText = ""
    @State private var editorStatusMessage = ""
    @State private var urlStatusMessage = ""
    @State private var setupCode = ""
    @State private var isLoadingFromURL = false
    @State private var selectedProfileIDForDelete: UUID?
    @State private var showDeleteProfileConfirmation = false
    @State private var showQRScanner = false
    @State private var showAdvanced = false
    @State private var turnNumConnections = VKTurnSettings.numConnections

    private let appGroupID = "group.alex.MyVPNClean"

    private var isRussian: Bool {
        let appLanguage = Bundle.main.preferredLocalizations.first?.lowercased() ?? ""
        let systemLanguage = Locale.preferredLanguages.first?.lowercased() ?? ""

        return appLanguage.hasPrefix("ru") || systemLanguage.hasPrefix("ru")
    }

    private func text(_ en: String, _ ru: String) -> String {
        isRussian ? ru : en
    }

    var body: some View {
        NavigationStack {
            Form {
                importSection
                subscriptionSection
                profilesSection
                advancedSection
            }
            .navigationTitle(text("Settings", "Настройки"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(text("Done", "Готово")) {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showQRScanner) {
                QRCodeScannerView { result in
                    handleQRResult(result)
                }
            }
            .alert(text("Delete Profile?", "Удалить профиль?"), isPresented: $showDeleteProfileConfirmation) {
                Button(text("Delete", "Удалить"), role: .destructive) {
                    deleteSelectedProfile()
                }

                Button(text("Cancel", "Отмена"), role: .cancel) {
                    selectedProfileIDForDelete = nil
                }
            } message: {
                Text(text("The selected profile will be deleted.", "Выбранный профиль будет удалён."))
            }
        }
    }

    private var importSection: some View {
        Section {
            ZStack(alignment: .topLeading) {
                if manualConfigText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(text(
                        "Paste VPN config, subscription content, or scan QR code",
                        "Вставьте VPN-конфиг, содержимое подписки или отсканируйте QR-код"
                    ))
                    .foregroundColor(.secondary)
                    .padding(.top, 8)
                    .padding(.leading, 5)
                }

                TextEditor(text: $manualConfigText)
                    .frame(minHeight: 150)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            HStack {
                Button(text("Paste", "Вставить")) {
                    pasteFromClipboard()
                }

                Spacer()

                Button(text("Scan QR", "QR-код")) {
                    showQRScanner = true
                }

                if !manualConfigText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button(text("Clear", "Очистить")) {
                        clearEditor()
                    }
                    .foregroundColor(.red)
                }
            }

            Button {
                addProfileFromEditor()
            } label: {
                HStack {
                    Image(systemName: "plus.circle.fill")
                    Text(text("Save Profile", "Сохранить профиль"))
                }
            }
            .disabled(manualConfigText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if !editorStatusMessage.isEmpty {
                Text(editorStatusMessage)
                    .font(.footnote)
                    .foregroundColor(colorForStatus(editorStatusMessage))
            }
        } header: {
            Text(text("Import Config", "Импорт конфига"))
        } footer: {
            Text(text(
                "Supported formats: VLESS, VMess, Trojan, Shadowsocks, Hysteria, JSON and Clash/FastCon YAML configs.",
                "Поддерживаются VLESS, VMess, Trojan, Shadowsocks, Hysteria, JSON и Clash/FastCon YAML-конфиги."
            ))
        }
    }

    private var subscriptionSection: some View {
        Section {
            TextField(text("Setup code", "Код настройки"), text: $setupCode)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()

            Button {
                activateSetupCode()
            } label: {
                Label(
                    text("Activate Setup Code", "Активировать код настройки"),
                    systemImage: "wand.and.stars"
                )
            }
            .disabled(isLoadingFromURL || setupCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Divider()

            TextField(text("Subscription URL", "Ссылка подписки"), text: $configURL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            TextField(text("Access token (optional)", "Токен доступа (необязательно)"), text: $accessToken)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            Button {
                loadProfileFromURL()
            } label: {
                HStack {
                    if isLoadingFromURL {
                        ProgressView()
                    }

                    Text(isLoadingFromURL ? text("Loading...", "Загрузка...") : text("Import from URL", "Импортировать по ссылке"))
                }
            }
            .disabled(isLoadingFromURL)

            if !urlStatusMessage.isEmpty {
                Text(urlStatusMessage)
                    .font(.footnote)
                    .foregroundColor(colorForStatus(urlStatusMessage))
            }
        } header: {
            Text(text("Subscription", "Подписка"))
        } footer: {
            Text(text(
                "Use this if your provider gives you a subscription link.",
                "Используйте этот раздел, если провайдер выдал ссылку подписки."
            ))
        }
    }

    private var profilesSection: some View {
        Section {
            if store.profiles.isEmpty {
                Text(text("No profiles yet", "Профилей пока нет"))
                    .foregroundColor(.secondary)
            } else {
                ForEach(store.profiles) { profile in
                    Button {
                        store.selectProfile(id: profile.id)
                        editorStatusMessage = ""
                        urlStatusMessage = text("Profile selected", "Профиль выбран") + ": \(profile.displayName)"
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(profile.displayName)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(.primary)
                                    .lineLimit(1)

                                Spacer()

                                if profile.isSelected {
                                    Text(text("Active", "Активен"))
                                        .font(.caption)
                                        .foregroundColor(.green)
                                }
                            }

                            if !profile.serverAddress.isEmpty {
                                Text(profile.serverAddress)
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }

                            Text(profile.kind.rawValue.uppercased())
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            selectedProfileIDForDelete = profile.id
                            showDeleteProfileConfirmation = true
                        } label: {
                            Text(text("Delete", "Удалить"))
                        }
                    }
                }
            }
        } header: {
            Text(text("Saved Profiles", "Сохранённые профили"))
        }
    }

    private var advancedSection: some View {
        Section {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showAdvanced.toggle()
                }
            } label: {
                HStack {
                    Text(text("Advanced", "Дополнительно"))
                        .foregroundColor(.primary)

                    Spacer()

                    Image(systemName: showAdvanced ? "chevron.up" : "chevron.down")
                        .foregroundColor(.secondary)
                }
            }

            if showAdvanced {
                Picker(
                    text("VPN Engine", "VPN-движок"),
                    selection: Binding(
                        get: {
                            vpnEngineKindRawValue
                        },
                        set: { newValue in
                            vpnEngineKindRawValue = newValue

                            guard let kind = VPNEngineKind(rawValue: newValue) else {
                                return
                            }

                            UserDefaults.standard.set(kind.rawValue, forKey: "vpnEngineKind")
                        }
                    )
                ) {
                    Text("SingBox (VLESS)")
                        .tag("packetTunnel")

                    Text("VK TURN")
                        .tag("packetTunnelVKTurn")
                }
                .pickerStyle(.segmented)

                Text(text(
                    "SingBox is the existing VLESS path. VK TURN is a separate engine branch.",
                    "SingBox — текущая VLESS-ветка. VK TURN — отдельная ветка движка."
                ))
                .font(.footnote)
                .foregroundColor(.secondary)

                if vpnEngineKindRawValue == "packetTunnelVKTurn" {

                    TextField(
                        "VK Call Link",
                        text: Binding(
                            get: { VKTurnSettings.vkLink },
                            set: { VKTurnSettings.vkLink = $0 }
                        )
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    TextField(
                        "Proxy Server host:port",
                        text: Binding(
                            get: { VKTurnSettings.peerAddress },
                            set: { VKTurnSettings.peerAddress = $0 }
                        )
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    SecureField(
                        "Private Key",
                        text: Binding(
                            get: { VKTurnSettings.privateKey },
                            set: { VKTurnSettings.privateKey = $0 }
                        )
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    TextField(
                        "Peer Public Key",
                        text: Binding(
                            get: { VKTurnSettings.peerPublicKey },
                            set: { VKTurnSettings.peerPublicKey = $0 }
                        )
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    TextField(
                        "Tunnel Address",
                        text: Binding(
                            get: { VKTurnSettings.tunnelAddress },
                            set: { VKTurnSettings.tunnelAddress = $0 }
                        )
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    TextField(
                        "DNS",
                        text: Binding(
                            get: { VKTurnSettings.dnsServers },
                            set: { VKTurnSettings.dnsServers = $0 }
                        )
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    Stepper(
                        text("Connections: \(turnNumConnections)", "Соединений: \(turnNumConnections)"),
                        value: Binding(
                            get: { turnNumConnections },
                            set: { newValue in
                                turnNumConnections = newValue
                                VKTurnSettings.numConnections = newValue
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            }
                        ),
                        in: 1...50
                    )
                    .onAppear {
                        turnNumConnections = VKTurnSettings.numConnections
                    }

                    Text(text(
                        "Fill these fields from the original VK TURN settings.",
                        "Заполните эти поля из оригинальных настроек VK TURN."
                    ))
                    .font(.footnote)
                    .foregroundColor(.secondary)

                    Button(role: .destructive) {
                        resetTURNCache()
                    } label: {
                        Label(
                            text("Reset TURN Cache", "Сбросить TURN-кэш"),
                            systemImage: "trash"
                        )
                        .foregroundColor(.red)
                    }

                    Button(role: .destructive) {
                        resetCapturedBrowserProfile()
                    } label: {
                        Label(
                            text(
                                "Reset Captured Browser Profile",
                                "Сбросить профиль браузера"
                            ),
                            systemImage: "trash"
                        )
                        .foregroundColor(.red)
                    }
                }

                NavigationLink {
                    VPNDebugView()
                } label: {
                    Label(
                        text("Diagnostics & Logs", "Диагностика и логи"),
                        systemImage: "stethoscope"
                    )
                }
            }
        } footer: {
            Text(text(
                "Advanced settings are for diagnostics and fine tuning. Normal users do not need to change them.",
                "Дополнительные настройки нужны для диагностики и тонкой настройки. Обычному пользователю их менять не нужно."
            ))
        }
    }

    private func resetTURNCache() {
        let fm = FileManager.default

        if let appGroupURL = fm.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) {
            let files = [
                "creds-pool.json",
                "vk_profile.json"
            ]

            for file in files {
                let url = appGroupURL.appendingPathComponent(file)
                try? fm.removeItem(at: url)
            }
        }

        removeDefaultsKeys([
            "lastTurnServerIP",
            "vk_lastTurnServerIP",
            "vk_turnServer",
            "vk_turnPort",
            "vk_seededTURN",
            "vk_seededTurn",
            "vk_turnCreds",
            "vk_turnCredentials",
            "vk_cachedTURN",
            "vk_cachedTurn"
        ])

        urlStatusMessage = text(
            "TURN cache reset",
            "TURN-кэш очищен"
        )
    }

    private func resetCapturedBrowserProfile() {
        let fm = FileManager.default

        if let appGroupURL = fm.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) {
            let files = [
                "vk_profile.json",
                "captcha-profile.json",
                "browser-profile.json"
            ]

            for file in files {
                let url = appGroupURL.appendingPathComponent(file)
                try? fm.removeItem(at: url)
            }
        }

        removeDefaultsKeys([
            "vk_profile",
            "vk_browserProfile",
            "vk_capturedBrowserProfile",
            "vk_captchaToken",
            "vk_successToken",
            "vk_success_token",
            "vk_captchaSuccessToken",
            "vk_captcha_sid",
            "vk_captchaSid",
            "vk_captcha_ts",
            "vk_captchaTs",
            "vk_lastJoinLink",
            "vk_joinLink",
            "vk_powProfile",
            "vk_deviceProfile",
            "vk_browserFingerprint"
        ])

        urlStatusMessage = text(
            "Browser profile reset",
            "Профиль браузера сброшен"
        )
    }

    private func removeDefaultsKeys(_ keys: [String]) {
        let standard = UserDefaults.standard
        let appGroupDefaults = UserDefaults(suiteName: appGroupID)

        for key in keys {
            standard.removeObject(forKey: key)
            appGroupDefaults?.removeObject(forKey: key)
        }

        standard.synchronize()
        appGroupDefaults?.synchronize()
    }

    private func handleQRResult(_ result: String?) {
        showQRScanner = false
        urlStatusMessage = ""

        guard let result else {
            editorStatusMessage = text("QR scan failed", "Не удалось считать QR-код")
            return
        }

        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            editorStatusMessage = text("QR scan failed", "Не удалось считать QR-код")
            return
        }

        let upsertResult = store.addOrUpdateProfile(from: trimmed)

        switch upsertResult {
        case .success(let upsert):
            switch upsert {
            case .inserted(let profile), .updated(let profile):
                store.selectProfile(id: profile.id)
                editorStatusMessage = text("QR profile saved", "Профиль из QR-кода сохранён")
            }

            manualConfigText = ""

        case .failure:
            manualConfigText = trimmed

            editorStatusMessage = text(
                "QR scanned. Review and save manually.",
                "QR-код считан. Проверьте и сохраните вручную."
            )
        }
    }

    private func addProfileFromEditor() {
        urlStatusMessage = ""

        let trimmed = manualConfigText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            editorStatusMessage = text("Config is empty", "Конфиг пуст")
            return
        }

        let configs = extractConfigs(from: trimmed)

        if configs.count > 1 {
            let result = store.importSubscriptionConfigs(configs, subscriptionName: "Manual")

            editorStatusMessage = importMessage(
                prefix: text("Imported", "Импортировано"),
                result: result
            )

            manualConfigText = ""
            return
        }

        if configs.count == 1 {
            let result = store.addOrUpdateProfile(from: configs[0])

            switch result {
            case .success(let upsert):
                switch upsert {
                case .inserted(let profile), .updated(let profile):
                    store.selectProfile(id: profile.id)
                    editorStatusMessage = text("Profile saved", "Профиль сохранён")
                }

                manualConfigText = ""

            case .failure(let error):
                editorStatusMessage = error.errorDescription ?? text(
                    "Invalid config",
                    "Некорректный конфиг"
                )
            }

            return
        }

        let result = store.addOrUpdateProfile(from: trimmed)

        switch result {
        case .success(let upsert):
            switch upsert {
            case .inserted(let profile), .updated(let profile):
                store.selectProfile(id: profile.id)
                editorStatusMessage = text("Profile saved", "Профиль сохранён")
            }

            manualConfigText = ""

        case .failure(let error):
            editorStatusMessage = error.errorDescription ?? text(
                "Invalid config",
                "Некорректный конфиг"
            )
        }
    }

    private func activateSetupCode() {
        let code = setupCode
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !code.isEmpty else {
            urlStatusMessage = text(
                "Enter setup code",
                "Введите код настройки"
            )
            return
        }

        guard code.range(of: #"^[a-z0-9_-]+$"#, options: .regularExpression) != nil else {
            urlStatusMessage = text(
                "Invalid setup code",
                "Некорректный код настройки"
            )
            return
        }

        guard let url = URL(string: "http://63.250.56.71/setup/\(code).json") else {
            urlStatusMessage = text(
                "Invalid setup URL",
                "Некорректный URL настройки"
            )
            return
        }

        urlStatusMessage = text(
            "Loading setup...",
            "Загружаю настройки..."
        )

        isLoadingFromURL = true

        Task {
            await loadRemoteVKTurnSetup(from: url)
        }
    }

    @MainActor
    private func loadRemoteVKTurnSetup(from url: URL) async {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let setup = try JSONDecoder().decode(RemoteVKTurnSetup.self, from: data)

            guard setup.engine == "packetTunnelVKTurn" else {
                isLoadingFromURL = false
                urlStatusMessage = text(
                    "Unsupported setup engine",
                    "Неподдерживаемый движок настройки"
                )
                return
            }

            vpnEngineKindRawValue = "packetTunnelVKTurn"
            UserDefaults.standard.set(
                "packetTunnelVKTurn",
                forKey: "vpnEngineKind"
            )

            VKTurnSettings.vkLink = setup.vkLink
            VKTurnSettings.peerAddress = setup.peerAddress
            VKTurnSettings.privateKey = setup.privateKey
            VKTurnSettings.peerPublicKey = setup.peerPublicKey
            VKTurnSettings.tunnelAddress = setup.tunnelAddress ?? "10.66.66.2/32"
            VKTurnSettings.dnsServers = setup.dnsServers ?? "1.1.1.1"
            VKTurnSettings.numConnections = setup.numConnections ?? 20

            let resolvedProfileName =
                setup.profileName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? setup.profileName!
                : codeFromSetupURL(url) ?? setup.peerAddress

            let profile = VPNProfile(
                name: resolvedProfileName,
                rawConfig: String(data: data, encoding: .utf8) ?? "",
                normalizedConfig: String(data: data, encoding: .utf8) ?? "",
                kind: .wireguard,
                serverAddress: setup.peerAddress,
                remark: "VK TURN",
                isSelected: true
            )

            var profiles = store.profiles.map { item in
                var copy = item
                copy.isSelected = false
                return copy
            }

            profiles.removeAll {
                $0.serverAddress == setup.peerAddress &&
                $0.kind == .wireguard &&
                $0.remark == "VK TURN"
            }

            profiles.insert(profile, at: 0)
            store.replaceAll(with: profiles)
            store.selectProfile(id: profile.id)

            turnNumConnections = VKTurnSettings.numConnections
            isLoadingFromURL = false

            urlStatusMessage = text(
                "Setup applied. Ready to connect.",
                "Настройки применены. Можно подключаться."
            )

        } catch {
            isLoadingFromURL = false
            urlStatusMessage = error.localizedDescription
        }
    }


    private func codeFromSetupURL(_ url: URL) -> String? {
        let name = url.deletingPathExtension().lastPathComponent
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func loadProfileFromURL() {
        editorStatusMessage = ""
        urlStatusMessage = text("Loading...", "Загрузка...")

        let trimmedURL = configURL.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let url = URL(string: trimmedURL),
              !trimmedURL.isEmpty else {
            urlStatusMessage = text("Invalid URL", "Некорректная ссылка")
            return
        }

        isLoadingFromURL = true

        Task {
            await loadProfileFromURLAsync(
                url: url,
                originalURLString: trimmedURL
            )
        }
    }

    @MainActor
    private func loadProfileFromURLAsync(
        url: URL,
        originalURLString: String
    ) async {
        do {
            let responseText = try await fetchSubscriptionTextWithFallback(url: url)

            let configs = extractConfigs(from: responseText)

            isLoadingFromURL = false

            guard !configs.isEmpty else {
                urlStatusMessage =
"""
Invalid subscription

RESPONSE:
\(responseText.prefix(1500))
"""
                return
            }

            if configs.count == 1 {
                let result = store.addOrUpdateProfile(from: configs[0])

                switch result {
                case .success(let upsert):
                    switch upsert {
                    case .inserted(let profile), .updated(let profile):
                        store.selectProfile(id: profile.id)
                        urlStatusMessage = text(
                            "Profile loaded from URL",
                            "Профиль загружен по ссылке"
                        )
                    }

                case .failure:
                    urlStatusMessage = text(
                        "Invalid config",
                        "Некорректный конфиг"
                    )
                }

                return
            }

            let subscriptionName = subscriptionDisplayName(
                from: originalURLString
            )

            let result = store.importSubscriptionConfigs(
                configs,
                subscriptionName: subscriptionName
            )

            urlStatusMessage = importMessage(
                prefix: text(
                    "Subscription imported",
                    "Подписка импортирована"
                ),
                result: result
            )

        } catch {
            isLoadingFromURL = false
            urlStatusMessage = error.localizedDescription
        }
    }

    private func fetchSubscriptionTextWithFallback(url: URL) async throws -> String {
        let userAgents = [
            "Hiddify/2.0",
            "Shadowrocket/1994 CFNetwork/1496.0.7 Darwin/23.5.0",
            "v2rayNG/1.8.22",
            "sing-box/1.9.0",
            "Clash",
            "ClashMetaForAndroid/2.10.1",
            "Mozilla/5.0"
        ]

        var lastText: String?
        var lastError: Error?

        for userAgent in userAgents {
            do {
                let text = try await fetchSubscriptionText(
                    url: url,
                    userAgent: userAgent
                )

                lastText = text

                let configs = extractConfigs(from: text)

                if !configs.isEmpty {
                    return text
                }

            } catch {
                lastError = error
            }
        }

        if let lastText {
            return lastText
        }

        if let lastError {
            throw lastError
        }

        throw SubscriptionLoadError.emptyResponse
    }

    private func fetchSubscriptionText(
        url: URL,
        userAgent: String
    ) async throws -> String {
        var request = URLRequest(url: url)

        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        if !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue(
                "Bearer \(accessToken.trimmingCharacters(in: .whitespacesAndNewlines))",
                forHTTPHeaderField: "Authorization"
            )
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            throw SubscriptionLoadError.httpStatus(http.statusCode)
        }

        guard let text = String(data: data, encoding: .utf8) ??
                String(data: data, encoding: .ascii) else {
            throw SubscriptionLoadError.invalidEncoding
        }

        return text
    }

    private func extractConfigs(from text: String) -> [String] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let directLines = normalized
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { isSupportedConfigLine($0) }

        if !directLines.isEmpty {
            return directLines
        }

        if let decoded = decodeBase64String(normalized) {
            let decodedLines = decoded
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { isSupportedConfigLine($0) }

            if !decodedLines.isEmpty {
                return decodedLines
            }
        }

        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.hasPrefix("{") || trimmed.lowercased().contains("proxies:") {
            return [trimmed]
        }

        return []
    }

    private func isSupportedConfigLine(_ line: String) -> Bool {
        let lower = line.lowercased()

        return lower.hasPrefix("vless://") ||
        lower.hasPrefix("vmess://") ||
        lower.hasPrefix("trojan://") ||
        lower.hasPrefix("ss://") ||
        lower.hasPrefix("hysteria://") ||
        lower.hasPrefix("hysteria2://") ||
        lower.hasPrefix("hy2://")
    }

    private func decodeBase64String(_ value: String) -> String? {
        let cleaned = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\t", with: "")

        guard !cleaned.isEmpty else {
            return nil
        }

        var padded = cleaned

        let remainder = padded.count % 4
        if remainder > 0 {
            padded += String(repeating: "=", count: 4 - remainder)
        }

        guard let data = Data(base64Encoded: padded) else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    private func subscriptionDisplayName(from urlString: String) -> String {
        guard let url = URL(string: urlString),
              let host = url.host,
              !host.isEmpty else {
            return "Subscription"
        }

        return host
    }

    private func importMessage(
        prefix: String,
        result: Any
    ) -> String {

        let mirror = Mirror(reflecting: result)

        if let importedCount = mirror.children.first(
            where: { $0.label == "importedCount" }
        )?.value as? Int {

            return "\(prefix): \(importedCount)"
        }

        return prefix
    }

    private func pasteFromClipboard() {
        if let string = UIPasteboard.general.string {
            manualConfigText = string
        }
    }

    private func clearEditor() {
        manualConfigText = ""
        editorStatusMessage = ""
    }

    private func deleteSelectedProfile() {
        guard let selectedProfileIDForDelete else {
            return
        }

        store.deleteProfile(id: selectedProfileIDForDelete)
        self.selectedProfileIDForDelete = nil
    }

    private func colorForStatus(_ message: String) -> Color {
        let lower = message.lowercased()

        if lower.contains("invalid") ||
            lower.contains("error") ||
            lower.contains("failed") ||
            lower.contains("некоррект") ||
            lower.contains("ошиб") ||
            lower.contains("не удалось") {
            return .red
        }

        if lower.contains("saved") ||
            lower.contains("loaded") ||
            lower.contains("imported") ||
            lower.contains("selected") ||
            lower.contains("сохран") ||
            lower.contains("загруж") ||
            lower.contains("импорт") ||
            lower.contains("выбран") ||
            lower.contains("reset") ||
            lower.contains("сброш") ||
            lower.contains("очищ") {
            return .green
        }

        return .secondary
    }
}

enum SubscriptionLoadError: LocalizedError {
    case emptyResponse
    case invalidEncoding
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .emptyResponse:
            return "Empty subscription response"
        case .invalidEncoding:
            return "Invalid subscription encoding"
        case .httpStatus(let code):
            return "Subscription HTTP error: \(code)"
        }
    }
}
