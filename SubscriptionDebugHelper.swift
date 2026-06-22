import Foundation

enum SubscriptionDebugHelper {
    static func preview(_ text: String, limit: Int = 800) -> String {
        let cleaned = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return String(cleaned.prefix(limit))
    }
}
