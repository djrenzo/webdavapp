import BackgroundTasks
import SwiftUI

enum KeepAlive {
    static let taskID = "torbox.library.keepalive"

    /// Free Supabase projects pause after 7 idle days: ping `is_member` about once a day.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: nil) { task in
            schedule()
            let work = Task {
                if let config = AppSettings.load().supabaseConfig {
                    _ = try? await SupabaseClient(config: config).isMember()
                }
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 24 * 60 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}

@main struct TorBoxLibraryApp: App {
    init() {
        KeepAlive.register()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
                .tint(CinemaTheme.blue)
        }
    }
}

struct RootView: View {
    @State private var model: AppModel?
    @State private var startupError: String?

    var body: some View {
        Group {
            if let model {
                MainTabView(model: model)
            } else if let startupError {
                ContentUnavailableView {
                    Label("Can’t open your library", systemImage: "externaldrive.badge.exclamationmark")
                } description: {
                    Text(startupError)
                } actions: {
                    Button("Try again") { open() }
                }
            } else {
                ProgressView("Opening your library…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(CinemaTheme.background)
        .foregroundStyle(CinemaTheme.text)
        .onAppear { if model == nil { open() } }
    }

    private func open() {
        startupError = nil
        do {
            let store = try CatalogStore()
            let newModel = AppModel(store: store)
            model = newModel
            Task {
                await newModel.reload()
                await newModel.checkSupabase()
                KeepAlive.schedule()
                await newModel.syncTrakt()
                await newModel.loadAiredEpisodes()
            }
        } catch {
            startupError = error.localizedDescription
        }
    }
}

struct MainTabView: View {
    @Bindable var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            LibraryView(model: model)
                .tabItem { Label("Library", systemImage: "square.grid.3x3.fill") }
            UnidentifiedView(model: model)
                .tabItem { Label("Unidentified", systemImage: "questionmark.folder") }
                .badge(model.snapshot.unidentified.count)
            AccountsView(model: model)
                .tabItem { Label("Accounts", systemImage: "externaldrive.connected.to.line.below") }
            SettingsView(model: model)
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.alertMessage != nil }, set: { if !$0 { model.alertMessage = nil } }
        )) {
            Button("OK") { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "")
        }
        .alert("Delete folders from Supabase?", isPresented: Binding(
            get: { model.staleRequest != nil }, set: { _ in }
        )) {
            Button("Delete from Supabase", role: .destructive) { model.answerStale(true) }
            Button("Keep them", role: .cancel) { model.answerStale(false) }
        } message: {
            Text(staleMessage)
        }
        .sheet(item: $model.pushSummary) { summary in
            PushSummaryView(summary: summary)
        }
        .onChange(of: scenePhase) { _, phase in
            // Back from Infuse/VLC: pick up what was watched (throttled to every 2 minutes).
            if phase == .active { Task { await model.syncTrakt() } }
        }
    }

    private var staleMessage: String {
        guard let folders = model.staleRequest?.folders else { return "" }
        var lines = folders.prefix(10).map { String($0.prefix(70)) }
        if folders.count > 10 { lines.append("…") }
        return "\(folders.count) folders exist in Supabase but not on this device. Delete them from Supabase?\n\n" + lines.joined(separator: "\n")
    }
}
