import SwiftUI

struct AccountView: View {
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
                    connectionSettings
                }
            }
            .navigationTitle("Account & Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
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
            HStack(spacing: 14) {
                ProfileAvatar(url: profile.avatarURL)
                    .frame(width: 52, height: 52)

                VStack(alignment: .leading) {
                    Text(profile.displayName)
                        .font(.headline)
                    Text(profile.baseURL)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Label(
                store.listenStatus,
                systemImage: store.connectionAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
            )
            .foregroundStyle(store.connectionAvailable ? .green : .orange)
        }

        Section("Library") {
            Button {
                Task { await store.refresh() }
            } label: {
                Label("Refresh Library", systemImage: "arrow.clockwise")
            }

            Text("Downloads appear in Files under On My iPhone → Tonkunst, arranged by artist and album. Remove individual downloads from the Offline tab.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }

        Section {
            Button("Sign Out", role: .destructive) {
                store.signOut()
                dismiss()
            }
        }
    }
}
