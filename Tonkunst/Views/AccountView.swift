import SwiftUI

struct AccountView: View {
    private let iconColumnWidth: CGFloat = 52
    private let iconSpacing: CGFloat = 14

    private enum JellyfinProtocol: String, CaseIterable, Identifiable {
        case http = "HTTP"
        case https = "HTTPS"

        var id: Self { self }

        var defaultPort: String {
            switch self {
            case .http: "8096"
            case .https: "8920"
            }
        }
    }

    @EnvironmentObject private var store: MusicStore
    @Environment(\.dismiss) private var dismiss

    @State private var protocolSelection: JellyfinProtocol = .http
    @State private var serverURL = ""
    @State private var port = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isAddingNewAccount = false
    @State private var isShowingRefreshFeedback = false

    private var serverAddress: String {
        let host = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedPort = port.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedPort = selectedPort.isEmpty ? protocolSelection.defaultPort : selectedPort
        return "\(protocolSelection.rawValue.lowercased())://\(host):\(resolvedPort)"
    }

    var body: some View {
        NavigationStack {
            Form {
                if let profile = store.profile {
                    signedInSettings(profile)
                } else {
                    signedOutSettings
                }
            }
            .navigationTitle("Account & Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                        .tint(Color.primary)
                        .foregroundStyle(Color.primary)
                }
            }
        }
    }

    @ViewBuilder
    private var signedOutSettings: some View {
        if !store.savedProfiles.isEmpty && !isAddingNewAccount {
            Section {
                ForEach(store.savedProfiles) { profile in
                    Button {
                        store.useSavedAccount(profile)
                        dismiss()
                    } label: {
                        HStack(spacing: iconSpacing) {
                            ProfileAvatar(url: profile.avatarURL)
                                .frame(width: iconColumnWidth, height: iconColumnWidth)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(profile.displayName)
                                    .font(.headline)
                                Text(profile.baseURL)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button("Forget", role: .destructive) {
                            store.forgetSavedAccount(profile)
                        }
                    }
                }
            } header: {
                Text("Saved Accounts")
            } footer: {
                Text("Choose an account to reconnect with its saved server settings and secure sign-in.")
            }

            Section {
                Button("Add Another Account") { isAddingNewAccount = true }
            }
        } else {
            if !store.savedProfiles.isEmpty {
                Section {
                    Button("Choose Saved Account") { isAddingNewAccount = false }
                }
            }
            connectionSettings
        }
    }

    private var connectionSettings: some View {
        Group {
            Section {
                Picker("Protocol", selection: $protocolSelection) {
                    ForEach(JellyfinProtocol.allCases) { protocolOption in
                        Text(protocolOption.rawValue).tag(protocolOption)
                    }
                }
                .pickerStyle(.menu)

                TextField("URL", text: $serverURL, prompt: Text("192.168.1.252"))
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()

                TextField("Port", text: $port, prompt: Text(protocolSelection.defaultPort))
                    .keyboardType(.numberPad)
            } header: {
                Text("Jellyfin Server")
            } footer: {
                Text("Enter the server URL without its port. Leave Port blank to use the standard \(protocolSelection.rawValue) port (\(protocolSelection.defaultPort)).")
            }

            Section {
                TextField("Account", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                SecureField("Password", text: $password)
            } header: {
                Text("Jellyfin Account")
            }

            Section {
                Button {
                    Task {
                        await store.signIn(server: serverAddress, username: username, password: password)
                        if store.profile != nil { password = "" }
                    }
                } label: {
                    if store.isLoading {
                        ProgressView()
                    } else {
                        Text("Connect to Jellyfin")
                    }
                }
                .disabled(serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                          username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                          password.isEmpty ||
                          store.isLoading)
            }
        }
    }

    @ViewBuilder
    private func signedInSettings(_ profile: ServerProfile) -> some View {
        Section("Jellyfin Account") {
            HStack(spacing: iconSpacing) {
                ProfileAvatar(url: profile.avatarURL)
                    .frame(width: iconColumnWidth, height: iconColumnWidth)

                VStack(alignment: .leading) {
                    Text(profile.displayName)
                        .font(.headline)
                    Text(profile.baseURL)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                Button("Sign Out", role: .destructive) {
                    store.signOut()
                    password = ""
                    isAddingNewAccount = false
                }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.glass)
                .tint(.red)
                .fixedSize()
            }

            HStack(spacing: iconSpacing) {
                Image(systemName: store.connectionAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .frame(width: iconColumnWidth)
                Text(store.listenStatus)
            }
            .foregroundStyle(store.connectionAvailable ? .green : .orange)
            .accessibilityElement(children: .combine)
        }

        Section {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let cooldown = store.refreshCooldownRemaining(at: context.date)
                Button {
                    guard !store.isLoading, !isShowingRefreshFeedback,
                          store.refreshCooldownRemaining() == 0 else { return }
                    isShowingRefreshFeedback = true
                    let startedAt = Date()
                    Task {
                        await store.refresh(isUserInitiated: true)
                        // Give even a fast refresh one full, visible animation cycle.
                        let remaining = max(0, 2.5 - Date().timeIntervalSince(startedAt))
                        try? await Task.sleep(for: .seconds(remaining))
                        isShowingRefreshFeedback = false
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise")
                        if store.isLoading || isShowingRefreshFeedback {
                            Text("Refreshing Library…")
                        } else if cooldown > 0 {
                            Text("Refresh in \(cooldown)s")
                                .monospacedDigit()
                        } else {
                            Text("Refresh Library")
                        }
                    }
                    .foregroundStyle(Color.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.glass)
                .tint(Color.primary)
                .disabled(store.isLoading || isShowingRefreshFeedback || cooldown > 0 || !store.connectionEnabled)
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        } header: {
            Text("Library")
        } footer: {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    LibraryRefreshProgressBar(isRefreshing: store.isLoading || isShowingRefreshFeedback)

                    if let refreshedAt = store.lastLibraryRefresh {
                        Text("Last refreshed: \(refreshedAt.formatted(date: .abbreviated, time: .standard))")
                    } else {
                        Text("Last refreshed: Never")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)

                Text("Downloads appear in Files under On My iPhone → Tonkunst, arranged by artist and album. Remove individual downloads from the Offline tab.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct LibraryRefreshProgressBar: View {
    let isRefreshing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animationStartedAt = Date()

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.12))

                if isRefreshing {
                    TimelineView(.animation(paused: reduceMotion)) { context in
                        let segmentWidth = geometry.size.width * 0.3
                        let phase = max(0, context.date.timeIntervalSince(animationStartedAt))
                            .truncatingRemainder(dividingBy: 2.5) / 2.5

                        Capsule()
                            .fill(Color.accentColor)
                            .frame(width: segmentWidth)
                            .offset(x: reduceMotion
                                    ? (geometry.size.width - segmentWidth) / 2
                                    : geometry.size.width * phase)
                    }
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 6)
        .onChange(of: isRefreshing, initial: true) { _, refreshing in
            if refreshing { animationStartedAt = Date() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Library refresh progress")
        .accessibilityValue(isRefreshing ? "Refreshing" : "Idle")
    }
}
