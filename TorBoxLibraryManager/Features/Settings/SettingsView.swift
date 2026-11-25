import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// §9.7.
struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var tmdbToken = Secrets.tmdbToken() ?? ""
    @State private var tmdbStatus: String?
    @State private var tmdbOK = false
    @State private var supabaseURL = ""
    @State private var supabaseKey = ""
    @State private var supabaseEmail = ""
    @State private var supabasePassword = ""
    @State private var exportURL: URL?
    @State private var showImporter = false
    @State private var confirmClear = false
    @State private var loaded = false
    @State private var subtitleKey = Secrets.openSubtitlesKey() ?? ""
    @State private var subtitleStatus: String?
    @State private var subtitleOK = false
    @State private var showLanguages = false
    @State private var subtitleLanguages: Set<String> = []
    @State private var traktID = ""
    @State private var traktSecret = ""
    @State private var showTraktConnect = false

    var body: some View {
        NavigationStack {
            Form {
                if model.isRefreshing {
                    Section { RefreshStatusView(model: model) }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }
                tmdbSection
                supabaseSection
                subtitlesSection
                traktSection
                if !model.snapshot.conflicts.isEmpty {
                    Section {
                        NavigationLink("Review \(model.snapshot.conflicts.count) differing overrides") {
                            ConflictReviewView(model: model)
                        }
                        .foregroundStyle(CinemaTheme.amber)
                    }
                    .listRowBackground(CinemaTheme.surface)
                }
                identificationSection
                dataSection
                Section("Diagnostics") {
                    NavigationLink("Log") { DiagnosticsView() }
                    LabeledContent("Overrides", value: "\(model.snapshot.overrideCount)")
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")
                }
                .listRowBackground(CinemaTheme.surface)
            }
            .scrollContentBackground(.hidden)
            .background(CinemaTheme.background)
            .navigationTitle("Settings")
            .onAppear(perform: load)
            .sheet(isPresented: $showLanguages, onDismiss: { model.subtitleLanguages = subtitleLanguages.sorted() }) {
                LanguagePicker(selection: $subtitleLanguages)
            }
            .sheet(isPresented: $showTraktConnect) { TraktConnectView(model: model) }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
                if case .success(let url) = result { Task { await model.importOverrides(from: url) } }
            }
            .confirmationDialog("Clear local cache?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear listings and posters", role: .destructive) { Task { await model.clearCache() } }
            } message: {
                Text("Accounts and overrides are kept. The next refresh lists your accounts again.")
            }
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        supabaseURL = model.settings.supabaseURL
        supabaseKey = model.settings.supabaseKey
        supabaseEmail = model.settings.supabaseEmail
        subtitleLanguages = Set(model.subtitleLanguages)
        traktID = model.traktClientID
        traktSecret = Secrets.traktSecret() ?? ""
    }

    // MARK: Subtitles

    private var subtitlesSection: some View {
        Section {
            SecureField("OpenSubtitles API key", text: $subtitleKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            HStack {
                Button("Save & test") {
                    let key = subtitleKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    Secrets.setOpenSubtitlesKey(key.isEmpty ? nil : key)
                    Task { await testSubtitleKey(key) }
                }
                Spacer()
                if let subtitleStatus {
                    Text(subtitleStatus).font(.caption).foregroundStyle(subtitleOK ? CinemaTheme.blue : CinemaTheme.amber)
                }
            }
            Button { showLanguages = true } label: {
                LabeledContent("Languages", value: subtitleLanguages.sorted().map(SubtitleLanguages.name).joined(separator: ", "))
            }
            .foregroundStyle(CinemaTheme.text)
        } header: {
            Text("Subtitles")
        } footer: {
            Text("opensubtitles.com → Profile → API consumers → New consumer. Without a key, searches use the free OpenSubtitles mirror only. Subtitles are saved with permanent links, so Kodi can use them too.")
        }
        .listRowBackground(CinemaTheme.surface)
    }

    private func testSubtitleKey(_ key: String) async {
        guard !key.isEmpty else {
            subtitleOK = true
            subtitleStatus = "Key removed"
            return
        }
        do {
            try await OpenSubtitlesClient(apiKey: key).test()
            subtitleOK = true
            subtitleStatus = "Key works"
        } catch {
            subtitleOK = false
            subtitleStatus = error.localizedDescription
        }
    }

    // MARK: Trakt

    private var traktSection: some View {
        Section {
            if model.isTraktConnected {
                LabeledContent("Connected", value: model.trakt.username ?? "Trakt")
                if let synced = model.trakt.syncedAt {
                    LabeledContent("Last sync", value: synced.formatted(.relative(presentation: .named)))
                }
                LabeledContent("Watched", value: "\(model.trakt.movies.count) movies · \(model.trakt.shows.count) shows")
                if let error = model.traktError {
                    Label(error, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(CinemaTheme.amber)
                }
                Button {
                    Task { await model.syncTrakt(force: true) }
                } label: {
                    HStack {
                        Text("Sync now")
                        if model.isSyncingTrakt { Spacer(); ProgressView() }
                    }
                }
                .disabled(model.isSyncingTrakt)
                Button("Disconnect", role: .destructive) { Task { await model.disconnectTrakt() } }
            } else {
                TextField("Client ID", text: $traktID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Client Secret", text: $traktSecret)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Connect Trakt") {
                    model.traktClientID = traktID
                    Secrets.setTraktSecret(traktSecret.trimmingCharacters(in: .whitespacesAndNewlines))
                    showTraktConnect = true
                }
                .disabled(traktID.trimmingCharacters(in: .whitespaces).isEmpty || traktSecret.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Trakt")
        } footer: {
            Text(model.isTraktConnected
                 ? "Watched movies and episodes, Continue watching and Keep going come from Trakt. Connect Infuse to Trakt too, so what you play there is tracked."
                 : "Create an app at trakt.tv/oauth/applications with redirect URI urn:ietf:wg:oauth:2.0:oob, then paste its Client ID and Secret here.")
        }
        .listRowBackground(CinemaTheme.surface)
    }

    // MARK: TMDB

    private var tmdbSection: some View {
        Section {
            SecureField("Read access token (v4)", text: $tmdbToken)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit(saveToken)
            HStack {
                Button("Save & test") {
                    saveToken()
                    Task {
                        await testToken()
                        if tmdbOK { await model.loadAiredEpisodes() }
                    }
                }
                .disabled(tmdbToken.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
                if let tmdbStatus {
                    Text(tmdbStatus).font(.caption).foregroundStyle(tmdbOK ? CinemaTheme.blue : CinemaTheme.amber)
                }
            }
        } header: {
            Text("TMDB")
        } footer: {
            Text("themoviedb.org → Settings → API → API Read Access Token. Needed to identify folders and fix matches.")
        }
        .listRowBackground(CinemaTheme.surface)
    }

    private func saveToken() {
        Secrets.setTMDBToken(tmdbToken.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func testToken() async {
        do {
            try await TMDBClient(token: tmdbToken.trimmingCharacters(in: .whitespacesAndNewlines)).test()
            tmdbOK = true
            tmdbStatus = "Token works"
        } catch {
            tmdbOK = false
            tmdbStatus = error.localizedDescription
        }
    }

    // MARK: Supabase

    private var supabaseSection: some View {
        Section {
            TextField("Project URL", text: $supabaseURL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Publishable (anon) key", text: $supabaseKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Email", text: $supabaseEmail)
                .keyboardType(.emailAddress)
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField(Secrets.supabasePassword() == nil ? "Password" : "Password (saved)", text: $supabasePassword)
                .textContentType(.password)
            Button("Save & sign in") {
                model.saveSupabase(
                    AppSettings(supabaseURL: supabaseURL, supabaseKey: supabaseKey, supabaseEmail: supabaseEmail),
                    password: supabasePassword.isEmpty ? nil : supabasePassword
                )
                supabasePassword = ""
            }
            .disabled(supabaseURL.isEmpty || supabaseKey.isEmpty || supabaseEmail.isEmpty)

            VStack(alignment: .leading, spacing: 4) {
                Text(statusLine).font(.footnote)
                if let warning = model.keepAliveWarning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(CinemaTheme.amber)
                }
            }

            Button("Fetch now") { model.fetchNow() }
                .disabled(model.isRefreshing || model.settings.supabaseConfig == nil)
            Menu("Push now") {
                ForEach(PushMode.allCases) { mode in
                    Button(mode.rawValue) { model.pushNow(mode) }
                }
            }
            .disabled(model.isRefreshing || model.role != .admin)
            Button("Sign out", role: .destructive) { model.signOut() }
                .disabled(model.settings.supabaseConfig == nil)
        } header: {
            Text("Supabase")
        } footer: {
            Text("The shared catalog the Kodi addon also uses. Push uploads this device’s overrides and file lists; it always fetches first. Admins only.")
        }
        .listRowBackground(CinemaTheme.surface)
    }

    private var statusLine: String {
        var parts: [String]
        switch model.role {
        case .admin, .reader:
            parts = ["Signed in as \(model.settings.supabaseEmail)", model.role == .admin ? "admin" : "reader"]
        default:
            parts = [model.role.rawValue]
        }
        if let date = model.snapshot.state.lastPushAt {
            parts.append("last push \(date.formatted(.relative(presentation: .named)))")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Identification & data

    private var identificationSection: some View {
        Section {
            Button("Re-identify automatic matches") { model.reidentifyAutomatic() }
                .disabled(model.isRefreshing)
        } header: {
            Text("Identification")
        } footer: {
            Text("Searches TMDB again for every automatic match. Manual matches are never changed.")
        }
        .listRowBackground(CinemaTheme.surface)
    }

    private var dataSection: some View {
        Section {
            if let exportURL {
                ShareLink(item: exportURL) {
                    Label("Share overrides.json", systemImage: "square.and.arrow.up")
                }
            } else {
                Button("Export overrides.json") {
                    Task { exportURL = await model.exportOverrides() }
                }
            }
            Button("Import overrides.json") { showImporter = true }
            Button("Clear local cache", role: .destructive) { confirmClear = true }
        } header: {
            Text("Data")
        } footer: {
            Text("The export is the Kodi addon’s overrides.json format. Import merges like Fetch: new folders are added, differing ones keep the local version until you review them.")
        }
        .listRowBackground(CinemaTheme.surface)
    }
}

struct DiagnosticsView: View {
    @State private var lines = AppLog.lines()

    var body: some View {
        List {
            if lines.isEmpty {
                Text("No log lines yet.").foregroundStyle(CinemaTheme.secondary)
            }
            ForEach(Array(lines.enumerated().reversed()), id: \.offset) { pair in
                Text(pair.element).font(.caption.monospaced()).textSelection(.enabled)
            }
            .listRowBackground(CinemaTheme.surface)
        }
        .scrollContentBackground(.hidden)
        .background(CinemaTheme.background)
        .navigationTitle("Log")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: lines.joined(separator: "\n"))
            }
        }
        .refreshable { lines = AppLog.lines() }
    }
}

struct PushSummaryView: View {
    let summary: PushSummary
    @Environment(\.dismiss) private var dismiss

    private let keys = ["tmdb_fetched", "titles", "seasons", "episodes", "overrides", "subtitles", "overrides_deleted",
                        "files", "files_deleted", "titles_pruned", "unidentified_folders"]

    var body: some View {
        NavigationStack {
            List {
                Section("Pushed to Supabase") {
                    ForEach(keys, id: \.self) { key in
                        LabeledContent(key.replacingOccurrences(of: "_", with: " ").capitalized, value: summary.stats[key]?.pythonString ?? "0")
                    }
                }
                .listRowBackground(CinemaTheme.surface)
                let incomplete = (summary.stats["incomplete_accounts"]?.arrayValue ?? []).compactMap(\.stringValue)
                if !incomplete.isEmpty {
                    Section("Incomplete accounts") {
                        Text("Couldn’t list every folder of \(incomplete.joined(separator: ", ")). Their old files were kept in Supabase.")
                            .foregroundStyle(CinemaTheme.amber)
                    }
                    .listRowBackground(CinemaTheme.surface)
                }
                if !summary.warnings.isEmpty {
                    Section("Warnings") {
                        ForEach(summary.warnings, id: \.self) { Text($0).font(.footnote) }
                    }
                    .listRowBackground(CinemaTheme.surface)
                }
            }
            .scrollContentBackground(.hidden)
            .background(CinemaTheme.background)
            .navigationTitle("Push complete")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }
}

/// Trakt device sign-in: show the code, open trakt.tv/activate, wait for approval.
struct TraktConnectView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var code: TraktDeviceCode?
    @State private var error: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                if let code {
                    Text("Enter this code on trakt.tv").font(.headline)
                    Text(code.userCode)
                        .font(.system(size: 40, weight: .bold, design: .monospaced))
                        .textSelection(.enabled)
                    Button("Copy code & open Trakt") {
                        UIPasteboard.general.string = code.userCode
                        if let url = URL(string: code.verificationURL) { openURL(url) }
                    }
                    .buttonStyle(.borderedProminent)
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Waiting for approval…").font(.footnote).foregroundStyle(CinemaTheme.secondary)
                    }
                } else if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(CinemaTheme.amber)
                    Button("Try again") { start() }.buttonStyle(.bordered)
                } else {
                    ProgressView("Asking Trakt for a code…")
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(CinemaTheme.background)
            .navigationTitle("Connect Trakt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear(perform: start)
            .onDisappear { task?.cancel() }
        }
        .preferredColorScheme(.dark)
    }

    private func start() {
        task?.cancel()
        code = nil
        error = nil
        task = Task {
            guard let client = TraktClient.configured() else {
                error = TraktError.notConfigured.localizedDescription
                return
            }
            do {
                let deviceCode = try await client.deviceCode()
                code = deviceCode
                _ = try await client.waitForToken(deviceCode)
                await model.traktDidConnect()
                dismiss()
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
                code = nil
            }
        }
    }
}
