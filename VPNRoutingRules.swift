import Foundation

enum VPNRouteDecision: String {
    case direct
    case vpn
}

struct VPNRoutingRules {

    private static let directDomains: [String] = [

        // MARK: Wildberries
        "wildberries.ru",
        "wildberries.by",
        "wildberries.kz",
        "wb.ru",
        "wbstatic.net",
        "wbbasket.ru",
        "wbcontent.net",
        "wbcdn.net",
        "wbdl.ru",
        "wbapp.ru",
        "wbpay.ru",
        "a.wb.ru",
        "static.wbstatic.net",

        // MARK: Ozon
        "ozon.ru",
        "ozon.com",
        "ozon.by",
        "ozon.kz",
        "ozone.ru",
        "o3.ru",
        "ozonusercontent.com",
        "ozoncdn.com",
        "ozon-st.cdn.ngenix.net",
        "api.ozon.ru",
        "api.ozon.com",
        "www.ozon.ru",
        "id.ozon.ru",
        "passport.ozon.ru",
        "widget.ozon.ru",
        "seller.ozon.ru",
        "api-seller.ozon.ru",
        "performance.ozon.ru",
        "cdn1.ozone.ru",
        "cdn2.ozone.ru",
        "cdn.ozone.ru",
        "static.ozone.ru",

        // MARK: Marketplaces / Commerce
        "market.yandex.ru",
        "beru.ru",
        "megamarket.ru",
        "sbermegamarket.ru",
        "aliexpress.ru",
        "goods.ru",

        // MARK: Yandex
        "yandex.ru",
        "yandex.net",
        "yandex.com",
        "ya.ru",
        "yastatic.net",
        "yandexcloud.net",
        "appmetrica.yandex.ru",
        "startup.mobile.yandex.net",
        "kinopoisk.ru",
        "plus.yandex.ru",
        "taxi.yandex.ru",
        "lavka.yandex.ru",
        "eda.yandex.ru",
        "music.yandex.ru",

        // MARK: VK / Mail
        "vk.com",
        "vk.ru",
        "vkontakte.ru",
        "userapi.com",
        "mail.ru",
        "ok.ru",
        "dzen.ru",
        "rutube.ru",

        // MARK: Classifieds
        "avito.ru",
        "cian.ru",
        "hh.ru",

        // MARK: Payments / Government
        "sbp.nspk.ru",
        "nspk.ru",
        "mironline.ru",
        "gosuslugi.ru",
        "esia.gosuslugi.ru",
        "nalog.ru",
        "mos.ru",

        // MARK: Telecom
        "mts.ru",
        "megafon.ru",
        "beeline.ru",
        "t2.ru",
        "tele2.ru",
        "rostelecom.ru",

        // MARK: Delivery / Maps
        "sdek.ru",
        "pochta.ru",
        "dostavista.ru",
        "samokat.ru",
        "2gis.ru"
    ]

    private static let vpnDomains: [String] = [

        // MARK: Banks — строго через VPN
        "sberbank.ru",
        "sber.ru",
        "online.sberbank.ru",
        "tinkoff.ru",
        "tbank.ru",
        "alfabank.ru",
        "alfa.bank",
        "vtb.ru",
        "vtb.com",
        "gazprombank.ru",
        "gpb.ru",
        "raiffeisen.ru",
        "rshb.ru",
        "psbank.ru",
        "sovcombank.ru",
        "banki.ru",

        // MARK: Global services
        "openai.com",
        "chatgpt.com",
        "oaistatic.com",
        "oaiusercontent.com",

        "youtube.com",
        "googlevideo.com",
        "ytimg.com",
        "ggpht.com",

        "instagram.com",
        "cdninstagram.com",
        "facebook.com",
        "fbcdn.net",
        "whatsapp.com",

        "telegram.org",
        "t.me"
    ]

    static var allDirectDomains: [String] {
        directDomains
    }

    static var allVPNDomains: [String] {
        vpnDomains
    }

    static func decision(forHost host: String) -> VPNRouteDecision {
        let normalizedHost = normalizeHost(host)

        guard !normalizedHost.isEmpty else {
            return .vpn
        }

        if isLocalhost(normalizedHost) {
            return .direct
        }

        if isVPNDomain(normalizedHost) {
            return .vpn
        }

        if isDirectDomain(normalizedHost) {
            return .direct
        }

        return .vpn
    }

    private static func isDirectDomain(_ host: String) -> Bool {
        for domain in directDomains {
            let normalizedDomain = normalizeHost(domain)

            if host == normalizedDomain || host.hasSuffix(".\(normalizedDomain)") {
                return true
            }
        }

        return false
    }

    private static func isVPNDomain(_ host: String) -> Bool {
        for domain in vpnDomains {
            let normalizedDomain = normalizeHost(domain)

            if host == normalizedDomain || host.hasSuffix(".\(normalizedDomain)") {
                return true
            }
        }

        return false
    }

    static func decision(forIP ip: String) -> VPNRouteDecision {
        let normalizedIP = ip.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalizedIP.isEmpty else {
            return .vpn
        }

        if isLocalIPv4(normalizedIP) || isLocalIPv6(normalizedIP) {
            return .direct
        }

        return .vpn
    }

    static func decide(host: String?, ip: String?) -> VPNRouteDecision {
        if let host {
            return decision(forHost: host)
        }

        if let ip {
            return decision(forIP: ip)
        }

        return .vpn
    }

    private static func normalizeHost(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    private static func isLocalhost(_ host: String) -> Bool {
        host == "localhost" || host.hasSuffix(".local")
    }

    private static func isLocalIPv4(_ ip: String) -> Bool {
        ip.hasPrefix("10.") ||
        ip.hasPrefix("127.") ||
        ip.hasPrefix("192.168.") ||
        is172PrivateRange(ip) ||
        ip.hasPrefix("169.254.")
    }

    private static func is172PrivateRange(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".")
        guard parts.count == 4,
              parts[0] == "172",
              let second = Int(parts[1]) else {
            return false
        }

        return (16...31).contains(second)
    }

    private static func isLocalIPv6(_ ip: String) -> Bool {
        let lower = ip.lowercased()

        return lower == "::1" ||
        lower.hasPrefix("fe80:") ||
        lower.hasPrefix("fc") ||
        lower.hasPrefix("fd")
    }
}
