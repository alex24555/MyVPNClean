import SwiftUI
import UIKit

struct VPNDebugView: View {
    @StateObject private var log = VPNDebugLog.shared
    @State private var copyStatusMessage = ""

    var body: some View {
        NavigationStack {
            Group {
                if log.entries.isEmpty {
                    emptyState
                } else {
                    List {
                        summarySection
                        logsSection
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("VPN Logs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Copy") {
                        copyLogs()
                    }
                    .disabled(log.entries.isEmpty)

                    Button("Clear") {
                        log.clear()
                        copyStatusMessage = ""
                    }
                    .disabled(log.entries.isEmpty)
                }
            }
        }
    }

    private var summarySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    summaryBadge(
                        title: "Total",
                        value: "\(log.entries.count)",
                        color: .blue
                    )

                    summaryBadge(
                        title: "Errors",
                        value: "\(errorCount)",
                        color: .red
                    )

                    summaryBadge(
                        title: "Warnings",
                        value: "\(warningCount)",
                        color: .orange
                    )
                }

                if !copyStatusMessage.isEmpty {
                    Text(copyStatusMessage)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var logsSection: some View {
        Section("Recent Activity") {
            ForEach(log.entries) { entry in
                logRow(entry)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 40))
                .foregroundColor(.secondary)

            Text("No logs yet")
                .font(.system(size: 18, weight: .semibold))

            Text("VPN activity will appear here")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var errorCount: Int {
        log.entries.filter { $0.level == .error }.count
    }

    private var warningCount: Int {
        log.entries.filter { $0.level == .warning }.count
    }

    private func summaryBadge(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)

            Text(value)
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(color.opacity(0.08))
        .cornerRadius(10)
    }

    private func logRow(_ entry: VPNDebugLog.Entry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(log.formattedTimestamp(for: entry.timestamp))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)

                    Text(entry.category.rawValue.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Text(entry.level.rawValue.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(color(for: entry.level))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(color(for: entry.level).opacity(0.12))
                    .cornerRadius(7)
            }

            Text(entry.message)
                .font(.system(size: 13))
                .foregroundColor(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
    }

    private func copyLogs() {
        UIPasteboard.general.string = log.exportText()
        copyStatusMessage = "Logs copied to clipboard"
    }

    private func color(for level: VPNDebugLog.Level) -> Color {
        switch level {
        case .info:
            return .blue
        case .warning:
            return .orange
        case .error:
            return .red
        }
    }
}

#Preview {
    VPNDebugView()
}
