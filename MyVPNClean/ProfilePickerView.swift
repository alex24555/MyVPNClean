import SwiftUI

struct ProfilePickerView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = VPNProfileStore.shared

    @State private var profileToDelete: VPNProfile?
    @State private var showDeleteConfirmation = false

    var body: some View {
        NavigationStack {
            Group {
                if store.profiles.isEmpty {
                    emptyStateView
                } else {
                    ScrollView {
                        VStack(spacing: 12) {
                            ForEach(sortedProfiles) { profile in
                                profileCard(profile)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                    }
                    .background(Color(.systemGroupedBackground))
                }
            }
            .navigationTitle("Profiles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .alert("Delete Profile?", isPresented: $showDeleteConfirmation, presenting: profileToDelete) { profile in
                Button("Delete", role: .destructive) {
                    store.deleteProfile(id: profile.id)
                    profileToDelete = nil
                }

                Button("Cancel", role: .cancel) {
                    profileToDelete = nil
                }
            } message: { profile in
                Text("Profile \"\(profile.displayName)\" will be deleted.")
            }
        }
    }

    private var sortedProfiles: [VPNProfile] {
        store.profiles.sorted { first, second in
            if first.isSelected != second.isSelected {
                return first.isSelected
            }

            return first.updatedAt > second.updatedAt
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 44))
                .foregroundColor(.secondary)

            Text("No profiles yet")
                .font(.system(size: 20, weight: .semibold))

            Text("Add a profile in Settings first")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .background(Color(.systemGroupedBackground))
    }

    private func profileCard(_ profile: VPNProfile) -> some View {
        Button {
            store.selectProfile(id: profile.id)
            _ = VKTurnProfileApplier.apply(profile)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .top, spacing: 12) {
                    iconView(for: profile)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 7) {
                            Text(profile.displayName)
                                .font(.system(size: 17, weight: .bold))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            if profile.isSelected {
                                Text("ACTIVE")
                                    .font(.system(size: 9, weight: .black))
                                    .foregroundColor(.green)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 4)
                                    .background(Color.green.opacity(0.12))
                                    .cornerRadius(7)
                            }
                        }

                        Text(profile.subtitle)
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 8)

                    if profile.isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.green)
                    }
                }

                HStack(spacing: 8) {
                    protocolBadge(for: profile.kind)

                    if looksLikeSubscriptionProfile(profile) {
                        smallBadge("SUB")
                    }

                    Spacer()

                    Text(relativeDateText(from: profile.updatedAt))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                        .lineLimit(1)

                    Button {
                        profileToDelete = profile
                        showDeleteConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.red)
                            .frame(width: 32, height: 32)
                            .background(Color.red.opacity(0.10))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardBackground(for: profile))
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(cardBorderColor(for: profile), lineWidth: profile.isSelected ? 1.6 : 1)
            )
            .cornerRadius(20)
            .shadow(
                color: profile.isSelected ? Color.green.opacity(0.10) : Color.black.opacity(0.035),
                radius: profile.isSelected ? 10 : 6,
                x: 0,
                y: 4
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func iconView(for profile: VPNProfile) -> some View {
        ZStack {
            Circle()
                .fill(protocolColor(for: profile.kind).opacity(profile.isSelected ? 0.18 : 0.12))
                .frame(width: 42, height: 42)

            Image(systemName: profile.isSelected ? "shield.checkered" : "server.rack")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(protocolColor(for: profile.kind))
        }
    }

    private func protocolBadge(for kind: TunnelConfiguration.Kind) -> some View {
        Text(kind.rawValue.uppercased())
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(protocolColor(for: kind))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(protocolColor(for: kind).opacity(0.12))
            .cornerRadius(8)
    }

    private func smallBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Color(.secondarySystemGroupedBackground))
            .cornerRadius(8)
    }

    private func protocolColor(for kind: TunnelConfiguration.Kind) -> Color {
        switch kind {
        case .vless:
            return .blue

        case .wireguard:
            return .green

        case .json:
            return .orange

        case .base64:
            return .purple

        case .unknown:
            return .gray
        }
    }

    private func cardBackground(for profile: VPNProfile) -> Color {
        profile.isSelected ? Color.green.opacity(0.07) : Color(.systemBackground)
    }

    private func cardBorderColor(for profile: VPNProfile) -> Color {
        profile.isSelected ? Color.green.opacity(0.58) : Color.black.opacity(0.06)
    }

    private func looksLikeSubscriptionProfile(_ profile: VPNProfile) -> Bool {
        let name = profile.name.lowercased()
        return name.contains("•") ||
            name.contains("subscription") ||
            name.contains("alextelenkov") ||
            name.contains("alex")
    }

    private func relativeDateText(from date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return "Updated \(formatter.localizedString(for: date, relativeTo: Date()))"
    }
}

#Preview {
    ProfilePickerView()
}
