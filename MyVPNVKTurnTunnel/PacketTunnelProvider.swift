import NetworkExtension
import Network
import os.log

class PacketTunnelProvider: NEPacketTunnelProvider {

    private var tunnelHandle: Int32 = -1
    private let log = OSLog(subsystem: "com.vkturnproxy.tunnel", category: "PacketTunnel")

    private var pathMonitor: NWPathMonitor?
    private let pathMonitorQueue = DispatchQueue(label: "com.vkturnproxy.tunnel.pathmonitor")
    private var lastPathDescription: String?
    private var lastPathEssentialIdentity: String?
    private var currentWiFiSSID: String?
    private var pendingPathStatsWorkItem: DispatchWorkItem?
    private var pathChangeSequence: UInt64 = 0
    private var lastReconnectAt: Date?
    private var reconnectAttempt: Int = 0
    private let reconnectCooldown: TimeInterval = 20
    private var extensionWatchdogTimer: DispatchSourceTimer?
    private var extensionWatchdogEmptyTicks: Int = 0

    private static let sharedDefaultsSuiteName = "group.alex.MyVPNClean"
    private static let turnServerIPKey = "lastTurnServerIP"

    private func logMsg(_ msg: String) {
        os_log("%{public}s", log: log, type: .default, msg)
        NSLog("[PacketTunnel] %@", msg)
        SharedLogger.shared.log("[Tunnel] \(msg)")
    }

    private func safeForceReconnect(
        _ handle: Int32,
        reason: String
    ) {
        let now = Date()

        let isManualRequest = reason == "app_request"

        let cooldown: TimeInterval
        if isManualRequest {
            cooldown = reconnectCooldown
        } else {
            switch reconnectAttempt {
            case 0:
                cooldown = 0
            case 1:
                cooldown = 20
            case 2:
                cooldown = 30
            default:
                cooldown = 45
            }
        }

        if let last = lastReconnectAt,
           now.timeIntervalSince(last) < cooldown {

            let remaining = Int(cooldown - now.timeIntervalSince(last))
            logMsg("safeForceReconnect: skipped (backoff \(remaining)s left) reason=\(reason) attempt=\(reconnectAttempt)")
            return
        }

        lastReconnectAt = now
        reconnectAttempt += 1

        logMsg("safeForceReconnect: forcing reconnect reason=\(reason) attempt=\(reconnectAttempt) cooldown=\(Int(cooldown))s")
        wgForceReconnect(handle)
    }

    private func startExtensionWatchdog() {
        stopExtensionWatchdog()

        let timer = DispatchSource.makeTimerSource(queue: pathMonitorQueue)
        timer.schedule(deadline: .now() + 20, repeating: 25)

        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.runExtensionWatchdogTick()
        }

        extensionWatchdogTimer = timer
        timer.resume()

        logMsg("[ExtensionWatchdog] started")
    }

    private func stopExtensionWatchdog() {
        extensionWatchdogTimer?.cancel()
        extensionWatchdogTimer = nil
        extensionWatchdogEmptyTicks = 0
    }

    private func runExtensionWatchdogTick() {
        let handle = tunnelHandle
        guard handle >= 0 else { return }

        guard let ptr = wgGetStats(handle) else {
            logMsg("[ExtensionWatchdog] stats=nil")
            return
        }

        let json = String(cString: ptr)
        free(UnsafeMutableRawPointer(mutating: ptr))

        let active = extractActiveConns(json)
        let rtt = extractTurnRTT(json)

        logMsg("[ExtensionWatchdog] tick active_conns=\(active) rtt=\(rtt) stats=\(json)")

        if active > 0 && rtt > 0 {
            extensionWatchdogEmptyTicks = 0

            if reconnectAttempt > 0 {
                logMsg("[ExtensionWatchdog] tunnel healthy — reset reconnectAttempt")
            }

            reconnectAttempt = 0
            return
        }

        extensionWatchdogEmptyTicks += 1

        guard extensionWatchdogEmptyTicks >= 2 else {
            return
        }

        logMsg("[ExtensionWatchdog] empty tunnel for \(extensionWatchdogEmptyTicks) ticks — force reconnect")
        extensionWatchdogEmptyTicks = 0
        safeForceReconnect(handle, reason: "extension_watchdog")
    }

    private func extractTurnRTT(_ json: String?) -> Double {
        guard let json = json,
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return -1
        }

        if let v = obj["turn_rtt_ms"] as? Double { return v }
        if let v = obj["turn_rtt_ms"] as? Int { return Double(v) }
        if let v = obj["turn_rtt_ms"] as? Int64 { return Double(v) }
        return -1
    }

    private func persistTurnServerIP(_ ip: String) {
        guard !ip.isEmpty else { return }

        guard let shared = UserDefaults(suiteName: Self.sharedDefaultsSuiteName) else {
            logMsg("persistTurnServerIP: UserDefaults(suiteName:) returned nil — AppGroup misconfigured?")
            return
        }

        if shared.string(forKey: Self.turnServerIPKey) != ip {
            shared.set(ip, forKey: Self.turnServerIPKey)
            logMsg("persistTurnServerIP: saved \(ip) to AppGroup for next connect()'s serverAddress")
        }
    }

    override func startTunnel(
        options: [String : NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let startupStartedAt = Date()
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        logMsg("startup timing: T+0.000s startTunnel called (build \(build))")

        startPathMonitoring()
        wgSetTimezoneOffset(Int32(TimeZone.current.secondsFromGMT()))

        if let path = SharedLogger.shared.logFilePath {
            path.withCString { ptr in
                wgSetLogFilePath(UnsafeMutablePointer(mutating: ptr))
            }
            logMsg("Go log file path set: \(path)")
        } else {
            logMsg("WARNING: SharedLogger.shared.logFilePath is nil")
        }

        guard let protocolConfig = protocolConfiguration as? NETunnelProviderProtocol else {
            logMsg("ERROR: protocolConfiguration is not NETunnelProviderProtocol")
            completionHandler(VPNError.noConfiguration)
            return
        }

        guard let config = protocolConfig.providerConfiguration else {
            logMsg("ERROR: no provider configuration")
            completionHandler(VPNError.noConfiguration)
            return
        }

        guard let wgConfig = config["wg_config"] as? String,
              let proxyConfigJSON = config["proxy_config"] as? String else {
            logMsg("ERROR: missing wg_config or proxy_config")
            logMsg("providerConfiguration dump=\(config)")
            completionHandler(VPNError.invalidConfiguration)
            return
        }

        let tunnelAddress = config["tunnel_address"] as? String ?? "192.168.102.3/24"
        let dnsServers = config["dns_servers"] as? String ?? "1.1.1.1"
        let mtu = config["mtu"] as? String ?? "1280"

        logMsg("tunnelAddress=\(tunnelAddress) dns=\(dnsServers) mtu=\(mtu)")
        logMsg("proxyConfig=\(proxyConfigJSON)")
        logMsg("wg_config size=\(wgConfig.count) chars")

        logMsg(String(format: "startup timing: T+%.3fs BEFORE wgStartVKBootstrap", Date().timeIntervalSince(startupStartedAt)))

        let handle = proxyConfigJSON.withCString { proxyPtr in
            wgStartVKBootstrap(UnsafeMutablePointer(mutating: proxyPtr))
        }

        logMsg(String(format: "startup timing: T+%.3fs AFTER wgStartVKBootstrap handle=%d", Date().timeIntervalSince(startupStartedAt), handle))

        if handle < 0 {
            logMsg("ERROR: wgStartVKBootstrap returned \(handle)")
            completionHandler(VPNError.backendFailed(code: handle))
            return
        }

        tunnelHandle = handle
        logMsg("wgStartVKBootstrap OK, handle=\(handle)")
        startExtensionWatchdog()

        var turnIP = ""

        if let turnIPPtr = wgGetTURNServerIP(handle) {
            turnIP = String(cString: turnIPPtr)
            free(UnsafeMutableRawPointer(mutating: turnIPPtr))
        }

        if !turnIP.isEmpty {
            logMsg("Initial TURN server IP=\(turnIP)")
            persistTurnServerIP(turnIP)
        } else {
            logMsg("Initial TURN server IP empty — using placeholder tunnelRemoteAddress")
        }

        let finalSettings = createTunnelSettings(
            address: tunnelAddress,
            dns: dnsServers,
            mtu: mtu,
            tunnelRemoteAddress: turnIP.isEmpty ? "10.0.0.1" : turnIP
        )

        logMsg(String(format: "startup timing: T+%.3fs setTunnelNetworkSettings BEGIN", Date().timeIntervalSince(startupStartedAt)))

        setTunnelNetworkSettings(finalSettings) { [weak self] error in
            guard let self = self else {
                completionHandler(VPNError.providerDeallocated)
                return
            }

            if let error = error {
                self.logMsg("setTunnelNetworkSettings ERROR: \(error)")
                wgTurnOff(handle)
                self.tunnelHandle = -1
                completionHandler(error)
                return
            }

            self.logMsg(String(format: "startup timing: T+%.3fs setTunnelNetworkSettings OK", Date().timeIntervalSince(startupStartedAt)))
            completionHandler(nil)
            self.logMsg(String(format: "startup timing: T+%.3fs completionHandler(nil) returned", Date().timeIntervalSince(startupStartedAt)))

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }

                let waitDeadline = Date().addingTimeInterval(2.0)

                while Date() < waitDeadline {
                    if self.findTunFileDescriptor() != nil {
                        break
                    }
                    Thread.sleep(forTimeInterval: 0.05)
                }

                self.logMsg(String(format: "startup timing: T+%.3fs smart attach started", Date().timeIntervalSince(startupStartedAt)))
                self.logMsg("findTunFileDescriptor: scanning fd 0...1024")

                guard let tunFd = self.findTunFileDescriptor() else {
                    self.logMsg("ERROR: could not find TUN fd after delayed attach")
                    wgTurnOff(handle)
                    self.tunnelHandle = -1
                    return
                }

                self.logMsg("TUN fd candidate selected=\(tunFd)")
                self.logMsg(String(format: "startup timing: T+%.3fs BEFORE wgAttachWireGuard", Date().timeIntervalSince(startupStartedAt)))
                self.logMsg("BEFORE wgAttachWireGuard handle=\(handle) fd=\(tunFd) wg_config_size=\(wgConfig.count)")

                let rc = wgConfig.withCString { cfgPtr in
                    wgAttachWireGuard(
                        handle,
                        UnsafeMutablePointer(mutating: cfgPtr),
                        tunFd
                    )
                }

                self.logMsg("wgAttachWireGuard returned rc=\(rc)")
                self.logMsg(String(format: "startup timing: T+%.3fs AFTER wgAttachWireGuard rc=%d", Date().timeIntervalSince(startupStartedAt), rc))

                if rc < 0 {
                    self.logMsg("ERROR: wgAttachWireGuard returned \(rc)")
                    wgTurnOff(handle)
                    self.tunnelHandle = -1
                    return
                }

                self.logMsg("wgAttachWireGuard OK — tunnel attached")

                DispatchQueue.global(qos: .utility).async { [weak self] in
                    guard let self = self else { return }

                    self.logMsg(String(format: "startup timing: T+%.3fs wgWaitBootstrapReady BEGIN", Date().timeIntervalSince(startupStartedAt)))

                    let ready = wgWaitBootstrapReady(handle, 120_000)

                    self.logMsg(String(format: "startup timing: T+%.3fs wgWaitBootstrapReady END code=%d", Date().timeIntervalSince(startupStartedAt), ready))

                    switch ready {
                    case 1:
                        self.logMsg("Background wgWaitBootstrapReady: ready")

                        if let ptr = wgGetTURNServerIP(handle) {
                            let ip = String(cString: ptr)
                            free(UnsafeMutableRawPointer(mutating: ptr))

                            if !ip.isEmpty {
                                self.logMsg("Background TURN server IP=\(ip)")
                                self.persistTurnServerIP(ip)
                            }
                        }

                    case 0:
                        self.logMsg("Background wgWaitBootstrapReady: timeout after 120s")

                    default:
                        self.logMsg("Background wgWaitBootstrapReady: failed with code \(ready)")
                    }
                }
            }
        }
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let msg = String(data: messageData, encoding: .utf8) else {
            completionHandler?(nil)
            return
        }

        if msg == "get_stats" {
            guard tunnelHandle >= 0 else {
                completionHandler?(nil)
                return
            }

            if let ptr = wgGetStats(tunnelHandle) {
                let json = String(cString: ptr)
                free(UnsafeMutableRawPointer(mutating: ptr))
                logMsg("handleAppMessage: get_stats response=\(json)")
                completionHandler?(json.data(using: .utf8))
            } else {
                completionHandler?(nil)
            }

        } else if msg == "get_logs" {
            let text = OSLogReader.readOwnLogs(maxAge: 1800)
            completionHandler?(text.data(using: .utf8))

        } else if msg == "force_reconnect" {
            logMsg("handleAppMessage: force_reconnect requested")

            if tunnelHandle >= 0 {
                safeForceReconnect(tunnelHandle, reason: "app_request")
                completionHandler?("ok".data(using: .utf8))
            } else {
                completionHandler?("no_tunnel".data(using: .utf8))
            }

        } else if msg.hasPrefix("solve_captcha:") {
            let answer = String(msg.dropFirst("solve_captcha:".count))
            logMsg("handleAppMessage: captcha answer received (\(answer.count) chars)")

            if tunnelHandle >= 0 {
                answer.withCString { ptr in
                    wgSolveCaptcha(tunnelHandle, UnsafeMutablePointer(mutating: ptr))
                }
            }

            completionHandler?("ok".data(using: .utf8))

        } else if msg == "refresh_captcha_url" {
            logMsg("handleAppMessage: refresh_captcha_url")

            var freshURL = ""

            if tunnelHandle >= 0 {
                if let ptr = wgRefreshCaptchaURL(tunnelHandle) {
                    freshURL = String(cString: ptr)
                    free(UnsafeMutableRawPointer(mutating: ptr))
                    logMsg("refreshCaptchaURL: got fresh URL (\(freshURL.prefix(80))...)")
                }
            }

            completionHandler?(freshURL.data(using: .utf8))

        } else if msg.hasPrefix("debug_log:") {
            let debugMsg = String(msg.dropFirst("debug_log:".count))
            logMsg("[AppDebug] \(debugMsg)")
            completionHandler?(nil)

        } else {
            completionHandler?(nil)
        }
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        logMsg("sleep() — ignored")
        completionHandler()
    }

    override func wake() {
        logMsg("wake() — running fast-path health check")

        if tunnelHandle >= 0 {
            wgWakeHealthCheck(tunnelHandle)
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        logMsg("stopTunnel: entered reason=\(reason.rawValue)")
        stopExtensionWatchdog()
        stopPathMonitoring()

        if tunnelHandle >= 0 {
            logMsg("stopTunnel: calling wgTurnOff(\(tunnelHandle))")
            wgTurnOff(tunnelHandle)
            tunnelHandle = -1
            logMsg("stopTunnel: wgTurnOff returned")
        } else {
            logMsg("stopTunnel: no active tunnelHandle")
        }

        completionHandler()
    }

    private func startPathMonitoring() {
        let monitor = NWPathMonitor()

        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }

            let process = { [weak self] in
                guard let self = self else { return }

                let desc = self.describePath(path)

                if desc != self.lastPathDescription {
                    self.logMsg("[PathMonitor] \(desc)")
                    self.lastPathDescription = desc

                    if self.tunnelHandle >= 0 {
                        let label = desc
                        label.withCString { cstr in
                            wgLogPathSnapshot(self.tunnelHandle, cstr)
                        }

                        let essential = self.pathEssentialIdentity(path)

                        if essential == self.lastPathEssentialIdentity {
                            self.logMsg("[PathMonitor] flag-only change (\(essential)) — bridge call skipped")
                            return
                        }

                        self.lastPathEssentialIdentity = essential

                        let isOther = path.status == .satisfied
                            && !path.usesInterfaceType(.wifi)
                            && !path.usesInterfaceType(.cellular)
                            && !path.usesInterfaceType(.wiredEthernet)
                            && !path.usesInterfaceType(.loopback)
                            && path.usesInterfaceType(.other)

                        if isOther {
                            wgPathInTransition(self.tunnelHandle)
                        } else {
                            wgPathChanged(self.tunnelHandle)

                            if path.status == .satisfied {
                                self.scheduleStatsSnapshotAfterPathChange(reason: essential)
                            } else {
                                self.logMsg("[PathMonitor] recovery watch skipped for non-satisfied path: \(essential)")
                            }
                        }
                    }
                }
            }

            if path.usesInterfaceType(.wifi) {
                NEHotspotNetwork.fetchCurrent { [weak self] network in
                    self?.currentWiFiSSID = network?.ssid
                    process()
                }
            } else {
                self.currentWiFiSSID = nil
                process()
            }
        }

        monitor.start(queue: pathMonitorQueue)
        pathMonitor = monitor
        logMsg("[PathMonitor] started")
    }



    private func scheduleStatsSnapshotAfterPathChange(reason: String) {
        guard tunnelHandle >= 0 else { return }

        pendingPathStatsWorkItem?.cancel()
        pathChangeSequence += 1

        let handle = tunnelHandle
        let sequence = pathChangeSequence

        func readStatsJSON() -> String? {
            guard let ptr = wgGetStats(handle) else { return nil }
            let json = String(cString: ptr)
            free(UnsafeMutableRawPointer(mutating: ptr))
            return json
        }

        func extractRX(_ json: String?) -> Int64 {
            guard let json = json,
                  let data = json.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return -1
            }

            if let v = obj["rx_bytes"] as? Int64 { return v }
            if let v = obj["rx_bytes"] as? Int { return Int64(v) }
            if let v = obj["rx_bytes"] as? Double { return Int64(v) }
            return -1
        }

        func extractTX(_ json: String?) -> Int64 {
            guard let json = json,
                  let data = json.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return -1
            }

            if let v = obj["tx_bytes"] as? Int64 { return v }
            if let v = obj["tx_bytes"] as? Int { return Int64(v) }
            if let v = obj["tx_bytes"] as? Double { return Int64(v) }
            return -1
        }

        func extractRTT(_ json: String?) -> Double {
            guard let json = json,
                  let data = json.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return -1
            }

            if let v = obj["turn_rtt_ms"] as? Double { return v }
            if let v = obj["turn_rtt_ms"] as? Int { return Double(v) }
            if let v = obj["turn_rtt_ms"] as? Int64 { return Double(v) }
            return -1
        }

        let initialJSON = readStatsJSON()
        let initialRX = extractRX(initialJSON)
        let initialTX = extractTX(initialJSON)

        logMsg("[PathMonitor] recovery watch start (\(reason)): initial_rx=\(initialRX) stats=\(initialJSON ?? "nil")")

        let delays: [(String, TimeInterval)] = [
            ("2s", 2.0),
            ("5s", 5.0),
            ("10s", 10.0),
            ("20s", 20.0)
        ]

        for (label, delay) in delays {
            pathMonitorQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self else { return }
                guard self.tunnelHandle == handle, handle >= 0 else { return }
                guard self.pathChangeSequence == sequence else { return }

                let json = readStatsJSON()
                self.logMsg("[PathMonitor] stats \(label) after path change (\(reason)): \(json ?? "nil")")
            }
        }

        let recoveryItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            guard self.tunnelHandle == handle, handle >= 0 else { return }
            guard self.pathChangeSequence == sequence else { return }

            let json = readStatsJSON()
            let currentRX = extractRX(json)
            let currentTX = extractTX(json)
            let currentRTT = extractRTT(json)
            let activeConns = extractActiveConns(json)

            let rxStalled = initialRX >= 0 && currentRX <= initialRX
            let txStalled = initialTX >= 0 && currentTX <= initialTX
            let rttMissing = currentRTT <= 0

            if activeConns > 0 &&
               currentRTT > 0 &&
               (!rxStalled || !txStalled) {

                if self.reconnectAttempt > 0 {
                    self.logMsg("[PathMonitor] tunnel healthy again — reset reconnectAttempt")
                }

                self.reconnectAttempt = 0
            }

            self.logMsg("[PathMonitor] recovery decision 8s after path change (\(reason)): initial_rx=\(initialRX) current_rx=\(currentRX) initial_tx=\(initialTX) current_tx=\(currentTX) rtt=\(currentRTT) active_conns=\(activeConns) stats=\(json ?? "nil")")

            if activeConns == 0 || (rxStalled && txStalled && rttMissing) {
                self.logMsg("[PathMonitor] recovery decision: stalled/empty tunnel — forcing reconnect")
                safeForceReconnect(handle, reason: "path_or_watchdog")
            } else {
                self.logMsg("[PathMonitor] recovery decision: tunnel has signs of life — no reconnect")
            }
        }

        pendingPathStatsWorkItem = recoveryItem
        pathMonitorQueue.asyncAfter(deadline: .now() + 8.0, execute: recoveryItem)
    }


    private func extractActiveConns(_ json: String?) -> Int {
        guard let json = json,
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return -1
        }

        if let v = obj["active_conns"] as? Int { return v }
        if let v = obj["active_conns"] as? Int64 { return Int(v) }
        if let v = obj["active_conns"] as? Double { return Int(v) }
        return -1
    }

    private func stopPathMonitoring() {
        pathMonitor?.cancel()
        pathMonitor = nil
        lastPathDescription = nil
        lastPathEssentialIdentity = nil
    }

    private func pathEssentialIdentity(_ path: Network.NWPath) -> String {
        let status: String

        switch path.status {
        case .satisfied:
            status = "satisfied"
        case .unsatisfied:
            status = "unsatisfied"
        case .requiresConnection:
            status = "requiresConnection"
        @unknown default:
            status = "unknown"
        }

        var iface = "none"

        if path.usesInterfaceType(.wifi) {
            iface = "wifi"
        } else if path.usesInterfaceType(.cellular) {
            iface = "cellular"
        } else if path.usesInterfaceType(.wiredEthernet) {
            iface = "wired"
        } else if path.usesInterfaceType(.loopback) {
            iface = "loopback"
        } else if path.usesInterfaceType(.other) {
            iface = "other"
        }

        var components = [status, "iface=\(iface)"]

        if iface == "wifi", let ssid = currentWiFiSSID {
            components.append("ssid=\"\(ssid)\"")
        }

        if path.status == .unsatisfied {
            let reason: String

            switch path.unsatisfiedReason {
            case .notAvailable:
                reason = "n/a"
            case .cellularDenied:
                reason = "cellular-denied"
            case .wifiDenied:
                reason = "wifi-denied"
            case .localNetworkDenied:
                reason = "local-net-denied"
            case .vpnInactive:
                reason = "vpn-inactive"
            @unknown default:
                reason = "unknown"
            }

            components.append("reason:\(reason)")
        }

        return components.joined(separator: " ")
    }

    private func describePath(_ path: Network.NWPath) -> String {
        let status: String

        switch path.status {
        case .satisfied:
            status = "satisfied"
        case .unsatisfied:
            status = "unsatisfied"
        case .requiresConnection:
            status = "requiresConnection"
        @unknown default:
            status = "unknown"
        }

        var iface = "none"

        if path.usesInterfaceType(.wifi) {
            iface = "wifi"
        } else if path.usesInterfaceType(.cellular) {
            iface = "cellular"
        } else if path.usesInterfaceType(.wiredEthernet) {
            iface = "wired"
        } else if path.usesInterfaceType(.loopback) {
            iface = "loopback"
        } else if path.usesInterfaceType(.other) {
            iface = "other"
        }

        var attrs: [String] = []

        if path.isExpensive {
            attrs.append("expensive")
        }

        if path.isConstrained {
            attrs.append("constrained")
        }

        if path.supportsIPv4 {
            attrs.append("v4")
        }

        if path.supportsIPv6 {
            attrs.append("v6")
        }

        if path.supportsDNS {
            attrs.append("dns")
        }

        if iface == "wifi", let ssid = currentWiFiSSID {
            attrs.append("ssid=\"\(ssid)\"")
        }

        if path.status == .unsatisfied {
            let reason: String

            switch path.unsatisfiedReason {
            case .notAvailable:
                reason = "n/a"
            case .cellularDenied:
                reason = "cellular-denied"
            case .wifiDenied:
                reason = "wifi-denied"
            case .localNetworkDenied:
                reason = "local-net-denied"
            case .vpnInactive:
                reason = "vpn-inactive"
            @unknown default:
                reason = "unknown"
            }

            attrs.append("reason:\(reason)")
        }

        let attrStr = attrs.isEmpty ? "" : " [\(attrs.joined(separator: ","))]"
        return "\(status) iface=\(iface)\(attrStr)"
    }

    private func createTunnelSettings(
        address: String,
        dns: String,
        mtu: String,
        tunnelRemoteAddress: String,
        includeDefaultRoute: Bool = true
    ) -> NEPacketTunnelNetworkSettings {
        let parts = address.split(separator: "/")
        let ip = String(parts[0])
        let prefix = parts.count > 1 ? Int(parts[1]) ?? 24 : 24

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: tunnelRemoteAddress)

        let ipv4 = NEIPv4Settings(
            addresses: [ip],
            subnetMasks: [prefixToSubnet(prefix)]
        )

        ipv4.includedRoutes = includeDefaultRoute ? [NEIPv4Route.default()] : []
        ipv4.excludedRoutes = []
        settings.ipv4Settings = ipv4

        if !dns.isEmpty {
            let dnsAddresses = dns
                .split(separator: ",")
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            if !dnsAddresses.isEmpty {
                settings.dnsSettings = NEDNSSettings(servers: dnsAddresses)
            }
        }

        if let mtuInt = Int(mtu) {
            settings.mtu = NSNumber(value: mtuInt)
        }

        return settings
    }

    private func prefixToSubnet(_ prefix: Int) -> String {
        var mask: UInt32 = 0

        for i in 0..<prefix {
            mask |= (1 << (31 - i))
        }

        return "\(mask >> 24).\((mask >> 16) & 0xFF).\((mask >> 8) & 0xFF).\(mask & 0xFF)"
    }

    private func findTunFileDescriptor() -> Int32? {
        var found: [(fd: Int32, name: String)] = []

        for fd: Int32 in 0...1024 {
            var buf = [CChar](repeating: 0, count: Int(IFNAMSIZ))
            var len = socklen_t(buf.count)

            let rc = getsockopt(
                fd,
                2,
                2,
                &buf,
                &len
            )

            if rc == 0 {
                let name = String(cString: buf)

                if name.hasPrefix("utun") {
                    logMsg("findTunFileDescriptor: candidate fd=\(fd) name=\(name)")
                    found.append((fd: fd, name: name))
                }
            }
        }

        if found.isEmpty {
            logMsg("findTunFileDescriptor: no utun candidates found")
            return nil
        }

        let selected = found.last!
        logMsg("findTunFileDescriptor: selected fd=\(selected.fd) name=\(selected.name) from \(found.count) candidate(s)")

        return selected.fd
    }
}

enum VPNError: Error, LocalizedError {
    case noConfiguration
    case invalidConfiguration
    case noTunDevice
    case providerDeallocated
    case backendFailed(code: Int32)
    case bootstrapTimeout

    var errorDescription: String? {
        switch self {
        case .noConfiguration:
            return "No provider configuration found"
        case .invalidConfiguration:
            return "Invalid or missing configuration fields"
        case .noTunDevice:
            return "Could not find TUN file descriptor"
        case .providerDeallocated:
            return "PacketTunnelProvider was deallocated"
        case .backendFailed(let code):
            return "WireGuard backend failed with code \(code)"
        case .bootstrapTimeout:
            return "VK bootstrap did not complete within 120s"
        }
    }
}
