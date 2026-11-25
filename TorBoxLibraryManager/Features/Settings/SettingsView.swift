import SwiftUI
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
                    Task { await testToken() }
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
