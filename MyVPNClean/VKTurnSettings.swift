import Foundation

struct VKTurnSettings {

    static var tunnelAddress: String {
        get {
            UserDefaults.standard.string(
                forKey: "vk_tunnelAddress"
            ) ?? "10.66.66.2/32"
        }
        set {
            UserDefaults.standard.set(
                newValue,
                forKey: "vk_tunnelAddress"
            )
        }
    }



    static var privateKey: String {
        get { UserDefaults.standard.string(forKey: "vk_privateKey") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "vk_privateKey") }
    }

    static var peerPublicKey: String {
        get { UserDefaults.standard.string(forKey: "vk_peerPublicKey") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "vk_peerPublicKey") }
    }

    static var peerAddress: String {
        get { UserDefaults.standard.string(forKey: "vk_peerAddress") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "vk_peerAddress") }
    }

    static var vkLink: String {
        get { UserDefaults.standard.string(forKey: "vk_link") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "vk_link") }
    }

    static var dnsServers: String {
        get { UserDefaults.standard.string(forKey: "vk_dns") ?? "1.1.1.1" }
        set { UserDefaults.standard.set(newValue, forKey: "vk_dns") }
    }

    static var numConnections: Int {
        get {
            let value =
            UserDefaults.standard.integer(
                forKey: "vk_numConnections"
            )

            return value == 0 ? 30 : value
        }

        set {
            UserDefaults.standard.set(
                newValue,
                forKey: "vk_numConnections"
            )
        }
    }
}
