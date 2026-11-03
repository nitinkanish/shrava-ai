import SwiftUI
import ShravaCore

struct IOSSlackSettingsView: View {
    @State private var tokenDraft = ""
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
        return channels.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        Form {
            Section {
                SecureField(tokenPresent ? "•••••••• (replace to update)" : "xoxb-… Bot User OAuth Token", text: $tokenDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Save to Keychain") { saveToken() }
                    .buttonStyle(.glassProminent)
                    .tint(ShravaTheme.purple)
                    .disabled(tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if tokenPresent {
                    Button("Remove token", role: .destructive) {
                        SlackSecrets.deleteToken()
                        tokenPresent = false
                        tokenDraft = ""
                        authInfo = nil
                        channels = []
                    }
                }
                Text(tokenPresent ? "Token stored in Keychain" : "No token stored")
                    .font(.caption)
                    .foregroundStyle(tokenPresent ? .green : .secondary)
            } header: {
                Text("Bot token")
            } footer: {
                Text("Create an app from docs/slack-app-manifest.yml at api.slack.com/apps, install to your workspace, copy the Bot User OAuth Token. Invite the bot to private channels with /invite.")
            }

            Section("Connection") {
                Button {
                    Task { await testConnection() }
                } label: {
                    if testing { ProgressView() } else { Text("Connect / Test") }
                }
                .buttonStyle(.glass)
                .disabled(testing)
                if let authInfo {
                    Label("\(authInfo.team) · @\(authInfo.user)", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .font(.footnote)
                } else if let statusMessage {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(statusOK ? .green : ShravaTheme.coral)
                }
            }

            Section("Default channel") {
                TextField("Search channels", text: $channelQuery)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    Task { await loadChannels() }
                } label: {
                    if loadingChannels { ProgressView() } else { Text("Refresh channels") }
                }
                .buttonStyle(.glass)
                .disabled(!tokenPresent || loadingChannels)

                Picker("Default", selection: Binding(
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

            Section("Sending") {
                Toggle("Auto-send brief after Analyze", isOn: $settings.autoSendAfterAnalyze)
                Toggle("Include transcript (thread reply)", isOn: $settings.includeTranscript)
            }
            .onChange(of: settings.autoSendAfterAnalyze) { _, _ in SlackSettingsStore.save(settings) }
            .onChange(of: settings.includeTranscript) { _, _ in SlackSettingsStore.save(settings) }
        }
        .navigationTitle("Slack")
        .navigationBarTitleDisplayMode(.inline)
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
            statusOK = true
            statusMessage = "Token saved to Keychain."
            Task {
                await testConnection()
                await loadChannels()
            }
        } catch {
            statusOK = false
            statusMessage = error.localizedDescription
        }
    }

    private func testConnection(silent: Bool = false) async {
        testing = true
        defer { testing = false }
        do {
            let info = try await SlackClient.shared.testAuth()
            authInfo = info
            if !silent {
                statusOK = true
                statusMessage = "Connected to \(info.team)"
            }
        } catch {
            authInfo = nil
            statusOK = false
            statusMessage = error.localizedDescription
        }
    }

    private func loadChannels() async {
        loadingChannels = true
        defer { loadingChannels = false }
        do {
            channels = try await SlackClient.shared.listChannels()
        } catch {
            statusOK = false
            statusMessage = error.localizedDescription
        }
    }
}

struct IOSSendBriefToSlackSheet: View {
    let brief: MeetingBrief
    let entry: HistoryEntry
    let title: String
    @Environment(\.dismiss) private var dismiss

    @State private var channels: [SlackChannel] = []
    @State private var query = ""
    @State private var selectedID: String = SlackSettingsStore.load().defaultChannelID ?? ""
    @State private var includeTranscript = SlackSettingsStore.load().includeTranscript
    @State private var sending = false
    @State private var loading = true
    @State private var errorText: String?
    @State private var permalink: URL?

    private var filtered: [SlackChannel] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return channels }
        return channels.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let permalink {
                    VStack(spacing: 16) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(.green)
                        Text("Posted to Slack")
                            .font(.title3.weight(.semibold))
                        Link("Open in Slack", destination: permalink)
                            .buttonStyle(.glassProminent)
                            .tint(ShravaTheme.purple)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if !SlackSecrets.hasToken() {
                    ContentUnavailableView(
                        "Slack not connected",
                        systemImage: "number.square",
                        description: Text("Add a bot token in Settings → Slack.")
                    )
                } else {
                    Form {
                        Section {
                            TextField("Search channels", text: $query)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            if loading {
                                ProgressView("Loading…")
                            } else {
                                Picker("Channel", selection: $selectedID) {
                                    Text("Select…").tag("")
                                    ForEach(filtered) { ch in
                                        Text(ch.displayName).tag(ch.id)
                                    }
                                }
                            }
                            Toggle("Include transcript as thread", isOn: $includeTranscript)
                        }
                        if let errorText {
                            Section {
                                Text(errorText).foregroundStyle(ShravaTheme.coral).font(.footnote)
                            }
                        }
                        Section {
                            Button {
                                Task { await send() }
                            } label: {
                                if sending { ProgressView() }
                                else { Text("Send brief") }
                            }
                            .buttonStyle(.glassProminent)
                            .tint(ShravaTheme.purple)
                            .disabled(sending || selectedID.isEmpty || loading)
                        }
                    }
                }
            }
            .navigationTitle("Send to Slack")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .buttonStyle(.glass)
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            channels = try await SlackClient.shared.listChannels()
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
