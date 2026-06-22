import Foundation

enum PacketTunnelTransportMode: String, Codable {
    case singbox
    case vkturn

    static let `default`: PacketTunnelTransportMode = .vkturn
}
