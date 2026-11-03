import SwiftUI
import AppKit
import ShravaCore

// MARK: - Settings tab

struct SlackSettingsView: View {
    @State private var tokenDraft = ""
    @State private var showToken = false
    @State private var tokenPresent = SlackSecrets.hasToken()
    @State private var authInfo: SlackAuthInfo?
    @State private var statusMessage: String?
    @State private var statusOK = false
    @State private var testing = false
    @State private var settings = SlackSettingsStore.load()
    @State private var channels: [SlackChannel] = []
    @State private var loadingChannels = false
    @State private var channelQuery = ""

    private var filteredChannels: [SlackChannel] {
        let q = channelQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return channels }
        return channels.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.id.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        Form {
            Section("Bot token") {
                HStack {
                    Group {
                        if showToken {
                            TextField(tokenPresent ? "•••••••• (replace to update)" : "xoxb-… Bot User OAuth Token", text: $tokenDraft)
                        } else {
                            SecureField(tokenPresent ? "•••••••• (replace to update)" : "xoxb-… Bot User OAuth Token", text: $tokenDraft)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    Button { showToken.toggle() } label: {
                        Image(systemName: showToken ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                }
                HStack {
                    Button("Save to Keychain") { saveToken() }
                        .disabled(tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if tokenPresent {
                        Button("Remove token", role: .destructive) {
                            SlackSecrets.deleteToken()
                            tokenPresent = false
                            tokenDraft = ""
                            authInfo = nil
                            channels = []
                            statusMessage = "Token removed from Keychain."
                            statusOK = true
                        }
                    }
                    Spacer()
                    Label(tokenPresent ? "Token in Keychain" : "No token",
                          systemImage: tokenPresent ? "checkmark.seal.fill" : "key")
                        .foregroundStyle(tokenPresent ? .green : .secondary)
                        .font(.caption)
                }
                Text("Create an app from docs/slack-app-manifest.yml at api.slack.com/apps, install it, then paste the Bot User OAuth Token here. Never commit the token.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Connection") {
                HStack {
                    Button {
                        Task { await testConnection() }
                    } label: {
                        if testing { ProgressView().controlSize(.small) }
                        else { Text("Connect / Test") }
                    }
                    .disabled(testing || !tokenPresent && tokenDraft.isEmpty)

                    if let authInfo {
                        Text("\(authInfo.team) · @\(authInfo.user)")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else if let statusMessage {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(statusOK ? .green : .red)
                            .lineLimit(3)
                    }
                }
            }

            Section("Default channel") {
                HStack {
                    TextField("Search channels", text: $channelQuery)
                        .textFieldStyle(.roundedBorder)
                    Button("Refresh") { Task { await loadChannels() } }
                        .disabled(!tokenPresent || loadingChannels)
                }
                if loadingChannels {
                    ProgressView().controlSize(.small)
                } else if channels.isEmpty {
                    Text(tokenPresent ? "Tap Refresh after connecting." : "Connect with a bot token first.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("Default channel", selection: Binding(
                        get: { settings.defaultChannelID ?? "" },
                        set: { id in
                            settings.defaultChannelID = id.isEmpty ? nil : id
                            settings.defaultChannelName = channels.first(where: { $0.id == id })?.displayName
                            SlackSettingsStore.save(settings)
                        }
                    )) {
                        Text("None").tag("")
                        ForEach(filteredChannels) { ch in
                            Text(ch.displayName).tag(ch.id)
                        }
                    }
                }
                if let name = settings.defaultChannelName {
                    Text("Saved default: \(name)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Sending") {
                Toggle("Auto-send brief after Analyze", isOn: $settings.autoSendAfterAnalyze)
                Toggle("Include transcript (threaded reply)", isOn: $settings.includeTranscript)
                Text("Auto-send uses the default channel and stays off until you enable it. Transcripts are posted as threaded replies, chunked for Slack limits.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings.autoSendAfterAnalyze) { _, _ in SlackSettingsStore.save(settings) }
        .onChange(of: settings.includeTranscript) { _, _ in SlackSettingsStore.save(settings) }
        .onAppear {
            tokenPresent = SlackSecrets.hasToken()
            settings = SlackSettingsStore.load()
            if tokenPresent {
                Task {
                    await testConnection(silent: true)
                    await loadChannels()
                }
            }
        }
    }

    private func saveToken() {
        let trimmed = tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try SlackSecrets.saveToken(trimmed)
            tokenPresent = true
            tokenDraft = ""
            statusMessage = "Token saved to Keychain."
            statusOK = true
            Task {
                await testConnection()
                await loadChannels()
            }
        } catch {
            statusMessage = error.localizedDescription
            statusOK = false
        }
    }

    private func testConnection(silent: Bool = false) async {
        testing = true
        defer { testing = false }
        do {
            if !tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try SlackSecrets.saveToken(tokenDraft)
                tokenDraft = ""
                tokenPresent = true
            }
            let info = try await SlackClient.shared.testAuth()
            authInfo = info
            if !silent {
                statusMessage = "Connected to \(info.team) as @\(info.user)"
                statusOK = true
            }
        } catch {
            authInfo = nil
            statusMessage = error.localizedDescription
            statusOK = false
        }
    }

    private func loadChannels() async {
        loadingChannels = true
        defer { loadingChannels = false }
        do {
            channels = try await SlackClient.shared.listChannels()
        } catch {
            statusMessage = error.localizedDescription
            statusOK = false
        }
    }
}

// MARK: - Send sheet

struct SendBriefToSlackSheet: View {
    let brief: MeetingBrief
    let entry: HistoryEntry
    let title: String
    @Environment(\.dismiss) private var dismiss

    @State private var settings = SlackSettingsStore.load()
    @State private var channels: [SlackChannel] = []
    @State private var query = ""
    @State private var selectedID: String = SlackSettingsStore.load().defaultChannelID ?? ""
    @State private var includeTranscript = SlackSettingsStore.load().includeTranscript
    @State private var sending = false
    @State private var errorText: String?
    @State private var permalink: URL?
    @State private var loading = true

    private var filtered: [SlackChannel] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return channels }
        return channels.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Send to Slack", systemImage: "paperplane.fill")
                    .font(.title3.bold())
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            if !SlackSecrets.hasToken() {
                Text("Add a Slack bot token in Settings → Slack first.")
                    .foregroundStyle(.red)
            } else if let permalink {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Posted to Slack", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Link("Open in Slack", destination: permalink)
                    Button("Done") { dismiss() }
                }
            } else {
                TextField("Search channels", text: $query)
                    .textFieldStyle(.roundedBorder)
                if loading {
                    ProgressView("Loading channels…")
                } else {
                    List(filtered, selection: $selectedID) { ch in
                        Text(ch.displayName).tag(ch.id)
                    }
                    .frame(minHeight: 220)
                }
                Toggle("Include transcript as thread reply", isOn: $includeTranscript)
                if let errorText {
                    Text(errorText).font(.caption).foregroundStyle(.red)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }
                    Button {
                        Task { await send() }
                    } label: {
                        if sending { ProgressView().controlSize(.small) }
                        else { Text("Send brief") }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(sending || selectedID.isEmpty || loading)
                }
            }
        }
        .padding(20)
        .frame(width: 420, height: 460)
        .task { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            channels = try await SlackClient.shared.listChannels()
            if selectedID.isEmpty, let def = settings.defaultChannelID {
                selectedID = def
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func send() async {
        sending = true
        errorText = nil
        defer { sending = false }
        guard let channel = channels.first(where: { $0.id == selectedID }) else {
            errorText = "Pick a channel."
            return
        }
        // Remember last choice as default.
        var s = SlackSettingsStore.load()
        s.defaultChannelID = channel.id
        s.defaultChannelName = channel.displayName
        SlackSettingsStore.save(s)

        do {
            let result = try await SlackClient.shared.postMeetingBrief(
                brief: brief,
                channelID: channel.id,
                channelName: channel.name,
                isPrivate: channel.isPrivate,
                title: title,
                date: entry.timestamp,
                durationSeconds: entry.durationSeconds,
                transcript: entry.cleanedText,
                includeTranscript: includeTranscript
            )
            permalink = result.permalink
        } catch {
            errorText = error.localizedDescription
        }
    }
}
