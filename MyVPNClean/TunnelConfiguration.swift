import Foundation

struct TunnelConfiguration {
    let rawConfig: String
    let normalizedConfig: String
    let kind: Kind
    let vless: ParsedVLESS?

    enum Kind: String, Codable {
        case vless
        case wireguard
        case json
        case base64
        case unknown
    }

    struct ParsedVLESS {
        let address: String
        let port: Int
        let uuid: String
        let security: String
        let transportType: String
        let sni: String
        let remark: String
        let fingerprint: String
        let publicKey: String
        let shortID: String
        let flow: String
    }

    static func build(from raw: String) -> TunnelConfiguration? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if hasVLESSPrefix(trimmed),
           let parsed = parseVLESS(trimmed) {
            let json = makeSingBoxJSON(from: parsed) ?? trimmed

            return TunnelConfiguration(
                rawConfig: trimmed,
                normalizedConfig: json,
                kind: .vless,
                vless: parsed
            )
        }

        if isWireGuardConfig(trimmed) {
            return TunnelConfiguration(
                rawConfig: trimmed,
                normalizedConfig: trimmed,
                kind: .wireguard,
                vless: nil
            )
        }

        if isJSON(trimmed) {
            if let parsed = parseXrayJSON(trimmed) {
                let json = makeSingBoxJSON(from: parsed) ?? trimmed

                return TunnelConfiguration(
                    rawConfig: trimmed,
                    normalizedConfig: json,
                    kind: .json,
                    vless: parsed
                )
            }

            return TunnelConfiguration(
                rawConfig: trimmed,
                normalizedConfig: trimmed,
                kind: .json,
                vless: nil
            )
        }

        if isClashYAML(trimmed),
           let parsed = parseClashYAML(trimmed) {
            let json = makeSingBoxJSON(from: parsed) ?? trimmed

            return TunnelConfiguration(
                rawConfig: trimmed,
                normalizedConfig: json,
                kind: .vless,
                vless: parsed
            )
        }

        return TunnelConfiguration(
            rawConfig: trimmed,
            normalizedConfig: trimmed,
            kind: .unknown,
            vless: nil
        )
    }

    static func wireGuardEndpoint(from raw: String) -> String {
        for line in raw.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed.lowercased().hasPrefix("endpoint") {
                let parts = trimmed.split(separator: "=", maxSplits: 1).map(String.init)

                if parts.count == 2 {
                    return parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }

        return ""
    }

    private static func isWireGuardConfig(_ raw: String) -> Bool {
        let lower = raw.lowercased()

        return lower.contains("[interface]") &&
            lower.contains("[peer]") &&
            lower.contains("privatekey") &&
            lower.contains("publickey") &&
            lower.contains("endpoint")
    }

    private static func parseVLESS(_ raw: String) -> ParsedVLESS? {
        guard let components = URLComponents(string: raw) else { return nil }

        let uuid = components.user ?? ""
        let address = components.host ?? ""
        let port = components.port ?? 0
        let items = components.queryItems ?? []

        func q(_ name: String) -> String {
            items.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })?.value ?? ""
        }

        guard !uuid.isEmpty, !address.isEmpty, port > 0 else {
            return nil
        }

        return ParsedVLESS(
            address: address,
            port: port,
            uuid: uuid,
            security: q("security"),
            transportType: q("type"),
            sni: q("sni"),
            remark: components.fragment ?? "",
            fingerprint: q("fp"),
            publicKey: q("pbk"),
            shortID: q("sid"),
            flow: q("flow")
        )
    }

    private static func parseXrayJSON(_ raw: String) -> ParsedVLESS? {
        let normalized = raw
            .replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "\\u0026", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = normalized.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let json = object as? [String: Any],
              let outbounds = json["outbounds"] as? [[String: Any]] else {
            return nil
        }

        for outbound in outbounds {
            let proto = stringValue(outbound["protocol"]).lowercased()
            guard proto == "vless" else { continue }

            guard let settings = outbound["settings"] as? [String: Any],
                  let vnext = settings["vnext"] as? [[String: Any]],
                  let firstServer = vnext.first else {
                continue
            }

            let address = stringValue(firstServer["address"])
            let port = intValue(firstServer["port"])

            guard let users = firstServer["users"] as? [[String: Any]],
                  let user = users.first else {
                continue
            }

            let uuid = stringValue(user["id"])
            let flow = stringValue(user["flow"])

            guard isUsableServer(address: address, port: port, uuid: uuid) else {
                continue
            }

            let stream = outbound["streamSettings"] as? [String: Any]
            let security = stringValue(stream?["security"])
            let network = stringValue(stream?["network"])

            let reality = stream?["realitySettings"] as? [String: Any]

            let sni = stringValue(reality?["serverName"])
            let fingerprint = stringValue(reality?["fingerprint"])
            let publicKey = stringValue(reality?["publicKey"])
            let shortID = stringValue(reality?["shortId"])

            return ParsedVLESS(
                address: address,
                port: port,
                uuid: uuid,
                security: security,
                transportType: network.isEmpty ? "tcp" : network,
                sni: sni,
                remark: stringValue(json["remarks"]),
                fingerprint: fingerprint.isEmpty ? "chrome" : fingerprint,
                publicKey: publicKey,
                shortID: shortID,
                flow: flow
            )
        }

        return nil
    }

    private static func parseClashYAML(_ raw: String) -> ParsedVLESS? {
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let lines = normalized.components(separatedBy: "\n")

        var inProxies = false
        var current: [String: String] = [:]
        var proxies: [[String: String]] = []

        func flushCurrent() {
            if !current.isEmpty {
                proxies.append(current)
                current = [:]
            }
        }

        for rawLine in lines {
            let line = rawLine.replacingOccurrences(of: "\t", with: "    ")
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            if !inProxies {
                if trimmed == "proxies:" {
                    inProxies = true
                }
                continue
            }

            if !line.hasPrefix(" ") && !line.hasPrefix("-") && trimmed.hasSuffix(":") && trimmed != "proxies:" {
                flushCurrent()
                break
            }

            if trimmed.hasPrefix("- ") {
                flushCurrent()

                let item = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)

                if item.hasPrefix("{"), item.hasSuffix("}") {
                    current.merge(parseInlineYAMLMap(item)) { _, new in new }
                } else if let pair = parseYAMLPair(item) {
                    current[pair.key] = pair.value
                }

                continue
            }

            if let pair = parseYAMLPair(trimmed) {
                current[pair.key] = pair.value
            }
        }

        flushCurrent()

        for proxy in proxies {
            let type = yamlValue(proxy, keys: ["type"]).lowercased()

            guard type == "vless" else {
                continue
            }

            let address = yamlValue(proxy, keys: ["server", "address"])
            let port = Int(yamlValue(proxy, keys: ["port"])) ?? 0
            let uuid = yamlValue(proxy, keys: ["uuid", "id"])

            guard isUsableServer(address: address, port: port, uuid: uuid) else {
                continue
            }

            let name = yamlValue(proxy, keys: ["name"])
            let network = yamlValue(proxy, keys: ["network", "type"])
            let flow = yamlValue(proxy, keys: ["flow"])
            let sni = yamlValue(proxy, keys: ["servername", "server-name", "sni"])
            let publicKey = yamlValue(proxy, keys: ["public-key", "publicKey", "pbk"])
            let shortID = yamlValue(proxy, keys: ["short-id", "shortId", "sid"])
            let fingerprint = yamlValue(proxy, keys: ["client-fingerprint", "fingerprint", "fp"])

            let hasReality = !publicKey.isEmpty || !shortID.isEmpty
            let tls = yamlValue(proxy, keys: ["tls"]).lowercased()

            let security: String
            if hasReality {
                security = "reality"
            } else if tls == "true" || tls == "1" || tls == "yes" {
                security = "tls"
            } else {
                security = "none"
            }

            return ParsedVLESS(
                address: address,
                port: port,
                uuid: uuid,
                security: security,
                transportType: network.isEmpty || network == "vless" ? "tcp" : network,
                sni: sni,
                remark: name,
                fingerprint: fingerprint.isEmpty ? "chrome" : fingerprint,
                publicKey: publicKey,
                shortID: shortID,
                flow: flow
            )
        }

        return nil
    }

    private static func makeSingBoxJSON(from v: ParsedVLESS) -> String? {
        var outbound: [String: Any] = [
            "type": "vless",
            "tag": "proxy",
            "server": v.address,
            "server_port": v.port,
            "uuid": v.uuid,
            "packet_encoding": "xudp"
        ]

        let flow = v.flow.trimmingCharacters(in: .whitespacesAndNewlines)
        if !flow.isEmpty {
            outbound["flow"] = flow
        }

        let security = v.security.lowercased()

        if security == "reality" {
            outbound["tls"] = [
                "enabled": true,
                "server_name": v.sni,
                "reality": [
                    "enabled": true,
                    "public_key": v.publicKey,
                    "short_id": v.shortID
                ],
                "utls": [
                    "enabled": true,
                    "fingerprint": v.fingerprint.isEmpty ? "chrome" : v.fingerprint
                ]
            ]
        } else if security == "tls" {
            outbound["tls"] = [
                "enabled": true,
                "server_name": v.sni
            ]
        }

        let vpnDomains = VPNRoutingRules.allVPNDomains
        let directDomains = VPNRoutingRules.allDirectDomains

        var routeRules: [[String: Any]] = []

        if !vpnDomains.isEmpty {
            routeRules.append([
                "domain_suffix": vpnDomains,
                "outbound": "proxy"
            ])
        }

        if !directDomains.isEmpty {
            routeRules.append([
                "domain_suffix": directDomains,
                "outbound": "direct"
            ])
        }

        let config: [String: Any] = [
            "log": [
                "level": "debug"
            ],
            "experimental": [
                "cache_file": [
                    "enabled": false
                ]
            ],
            "inbounds": [
                [
                    "type": "tun",
                    "tag": "tun-in",
                    "interface_name": "utun",
                    "address": [
                        "172.19.0.1/30",
                        "fdfe:dcba:9876::1/126"
                    ],
                    "mtu": 1500,
                    "auto_route": true,
                    "strict_route": false,
                    "stack": "system"
                ]
            ],
            "outbounds": [
                outbound,
                [
                    "type": "direct",
                    "tag": "direct"
                ],
                [
                    "type": "block",
                    "tag": "block"
                ]
            ],
            "route": [
                "final": "proxy",
                "auto_detect_interface": true,
                "rules": routeRules
            ]
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted]),
              let str = String(data: data, encoding: .utf8) else {
            return nil
        }

        return str
    }

    private static func parseYAMLPair(_ value: String) -> (key: String, value: String)? {
        guard let colonIndex = value.firstIndex(of: ":") else {
            return nil
        }

        let key = String(value[..<colonIndex])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let rawValue = String(value[value.index(after: colonIndex)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !key.isEmpty else {
            return nil
        }

        return (key, cleanYAMLValue(rawValue))
    }

    private static func parseInlineYAMLMap(_ value: String) -> [String: String] {
        var result: [String: String] = [:]

        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.hasPrefix("{") {
            trimmed.removeFirst()
        }

        if trimmed.hasSuffix("}") {
            trimmed.removeLast()
        }

        let parts = splitInlineYAML(trimmed)

        for part in parts {
            if let pair = parseYAMLPair(part) {
                result[pair.key] = pair.value
            }
        }

        return result
    }

    private static func splitInlineYAML(_ value: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var isInsideSingleQuote = false
        var isInsideDoubleQuote = false

        for char in value {
            if char == "'" && !isInsideDoubleQuote {
                isInsideSingleQuote.toggle()
            } else if char == "\"" && !isInsideSingleQuote {
                isInsideDoubleQuote.toggle()
            }

            if char == "," && !isInsideSingleQuote && !isInsideDoubleQuote {
                parts.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
            } else {
                current.append(char)
            }
        }

        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            parts.append(tail)
        }

        return parts
    }

    private static func cleanYAMLValue(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)

        if let commentIndex = result.firstIndex(of: "#") {
            result = String(result[..<commentIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        while (result.hasPrefix("\"") && result.hasSuffix("\"")) ||
                (result.hasPrefix("'") && result.hasSuffix("'")) {
            result.removeFirst()
            result.removeLast()
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return result
    }

    private static func yamlValue(_ dictionary: [String: String], keys: [String]) -> String {
        for key in keys {
            if let value = dictionary[key],
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            let lowerKey = key.lowercased()
            if let match = dictionary.first(where: { $0.key.lowercased() == lowerKey })?.value,
               !match.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return match.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return ""
    }

    private static func stringValue(_ value: Any?) -> String {
        if let string = value as? String {
            return string.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let number = value as? NSNumber {
            return number.stringValue
        }

        return ""
    }

    private static func intValue(_ value: Any?) -> Int {
        if let int = value as? Int {
            return int
        }

        if let double = value as? Double {
            return Int(double)
        }

        if let number = value as? NSNumber {
            return number.intValue
        }

        if let string = value as? String {
            return Int(string.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }

        return 0
    }

    private static func isUsableServer(address: String, port: Int, uuid: String) -> Bool {
        let cleanAddress = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cleanUUID = uuid.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        guard !cleanAddress.isEmpty,
              !cleanUUID.isEmpty,
              port > 0 else {
            return false
        }

        if cleanAddress == "0.0.0.0" ||
            cleanAddress == "127.0.0.1" ||
            cleanAddress == "localhost" {
            return false
        }

        if cleanUUID == "00000000-0000-0000-0000-000000000000" {
            return false
        }

        return true
    }

    private static func hasVLESSPrefix(_ value: String) -> Bool {
        value.lowercased().hasPrefix("vless://")
    }

    private static func isJSON(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{")
    }

    private static func isClashYAML(_ value: String) -> Bool {
        let lower = value.lowercased()

        return lower.contains("proxies:") ||
        lower.contains("mixed-port:") ||
        lower.contains("proxy-groups:") ||
        lower.contains("rules:")
    }
}
