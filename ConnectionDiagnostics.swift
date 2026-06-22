import Foundation

@MainActor
final class ConnectionDiagnostics: ObservableObject {

    enum Status: Equatable {
        case idle
        case checking
        case success
        case slow
        case failed(String)
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var latencyText: String = "—"
    @Published private(set) var externalIP: String = "—"
    @Published private(set) var lastCheckedText: String = "—"

    func check() async {
        status = .checking
        latencyText = "—"
        externalIP = "—"

        do {
            let latency = try await measureLatency()
            let ip = try await fetchExternalIP()

            latencyText = "\(latency) ms"
            externalIP = ip
            lastCheckedText = Self.timeFormatter.string(from: Date())

            // 🔥 логика slow / success
            if latency >= 1000 {
                status = .slow
            } else {
                status = .success
            }

        } catch {
            latencyText = "—"
            externalIP = "—"
            lastCheckedText = Self.timeFormatter.string(from: Date())
            status = .failed(error.localizedDescription)
        }
    }

    private func measureLatency() async throws -> Int {
        guard let url = URL(string: "https://cp.cloudflare.com/generate_204") else {
            throw DiagnosticsError.invalidURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let start = Date()
        let (_, response) = try await URLSession.shared.data(for: request)
        let elapsed = Date().timeIntervalSince(start)

        guard let http = response as? HTTPURLResponse,
              (200...204).contains(http.statusCode) else {
            throw DiagnosticsError.badResponse
        }

        return Int((elapsed * 1000).rounded())
    }

    private func fetchExternalIP() async throws -> String {
        guard let url = URL(string: "https://api.ipify.org") else {
            throw DiagnosticsError.invalidURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw DiagnosticsError.badResponse
        }

        guard let ip = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !ip.isEmpty else {
            throw DiagnosticsError.emptyIP
        }

        return ip
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

enum DiagnosticsError: LocalizedError {
    case invalidURL
    case badResponse
    case emptyIP

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid diagnostics URL"
        case .badResponse:
            return "Internet check failed"
        case .emptyIP:
            return "Unable to detect external IP"
        }
    }
}
