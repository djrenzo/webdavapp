import SwiftUI

/// §9.6: any number of TorBox WebDAV accounts.
struct AccountsView: View {
    let model: AppModel
    @State private var editing: Account?
    @State private var pendingDelete: Account?

    var body: some View {
        NavigationStack {
            List {
                if model.snapshot.accounts.isEmpty {
                    ContentUnavailableView {
                        Label("No accounts yet", systemImage: "externaldrive.badge.plus")
                    } description: {
                        Text("Add your TorBox WebDAV login to list your library.")
                    } actions: {
                        Button("Add account") { editing = newAccount() }
                            .buttonStyle(.borderedProminent)
                    }
                    .listRowBackground(Color.clear)
                }
                ForEach(model.snapshot.accounts) { account in
                    Button { editing = account } label: { row(account) }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("Delete", role: .destructive) { pendingDelete = account }
                        }
                        .swipeActions(edge: .leading) {
                            Button(account.isEnabled ? "Turn off" : "Turn on") {
                                Task { await model.setAccountEnabled(account, !account.isEnabled) }
                            }
                            .tint(account.isEnabled ? CinemaTheme.secondary : CinemaTheme.blue)
                        }
                        .listRowBackground(CinemaTheme.surface)
                }
            }
            .scrollContentBackground(.hidden)
            .background(CinemaTheme.background)
            .navigationTitle("Accounts")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { editing = newAccount() } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add account")
                }
            }
            .sheet(item: $editing) { account in
                AccountEditorView(model: model, account: account, isNew: !model.snapshot.accounts.contains { $0.id == account.id })
            }
            .alert("Delete \(pendingDelete?.name ?? "account")?", isPresented: Binding(
                get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
            )) {
                Button("Delete", role: .destructive) {
                    if let account = pendingDelete { Task { await model.deleteAccount(account) } }
                    pendingDelete = nil
                }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            } message: {
                Text("Its listing is removed from this device. On the next push, the account and its files are also removed from Supabase — including for Kodi if it shares this account.")
            }
        }
    }

    private func newAccount() -> Account {
        Account(name: "TorBox", baseURL: WebDAV.defaultBaseURL, username: "")
    }

    private func row(_ account: Account) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: account.isEnabled ? "externaldrive.fill.badge.checkmark" : "externaldrive")
                .font(.title3)
                .foregroundStyle(account.isEnabled ? CinemaTheme.blue : CinemaTheme.secondary)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(account.name).font(.headline)
                    if !account.lastListingComplete || account.lastError != nil {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(CinemaTheme.amber)
                            .accessibilityLabel("Last listing was incomplete")
                    }
                    if !account.isEnabled {
                        Text("Off").font(.caption).foregroundStyle(CinemaTheme.secondary)
                    }
                }
                Text("\(account.username) · \(account.host)").font(.caption).foregroundStyle(CinemaTheme.secondary)
                Text(status(account)).font(.caption).foregroundStyle(CinemaTheme.secondary)
                if let error = account.lastError {
                    Text(error).font(.caption).foregroundStyle(CinemaTheme.amber).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func status(_ account: Account) -> String {
        var parts = ["\(account.fileCount) files"]
        if let date = account.lastListedAt {
            parts.append("listed \(date.formatted(.relative(presentation: .named)))")
        } else {
            parts.append("not listed yet")
        }
        if let id = account.remoteID { parts.append("id \(id)") }
        return parts.joined(separator: " · ")
    }
}

struct AccountEditorView: View {
    let model: AppModel
    let isNew: Bool
    @State private var account: Account
    @State private var password = ""
    @State private var testResult: String?
    @State private var testOK = false
    @State private var isTesting = false
    @State private var isSaving = false
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel, account: Account, isNew: Bool) {
        self.model = model
        self.isNew = isNew
        _account = State(initialValue: account)
    }

    private var hasPassword: Bool { !password.isEmpty || Secrets.webdavPassword(account: account.id) != nil }
    private var canSave: Bool {
        !account.name.trimmingCharacters(in: .whitespaces).isEmpty && URL(string: account.baseURL)?.scheme != nil
            && !account.username.isEmpty && hasPassword
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    TextField("Name", text: $account.name)
                    TextField("WebDAV URL", text: $account.baseURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Username or email", text: $account.username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField(isNew ? "Password" : "Password (unchanged)", text: $password)
                        .textContentType(.password)
                    Toggle("Enabled", isOn: $account.isEnabled)
                }
                .listRowBackground(CinemaTheme.surface)

                Section {
                    Button {
                        Task { await test() }
                    } label: {
                        HStack {
                            Text("Test connection")
                            if isTesting { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(isTesting || account.username.isEmpty || !hasPassword)
                    if let testResult {
                        Label(testResult, systemImage: testOK ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(testOK ? CinemaTheme.blue : CinemaTheme.amber)
                            .font(.footnote)
                    }
                } footer: {
                    Text("TorBox: use https://webdav.torbox.app with your TorBox email and password.")
                }
                .listRowBackground(CinemaTheme.surface)

                if let id = account.remoteID {
                    Section("Supabase") {
                        LabeledContent("Account id", value: String(id))
                    }
                    .listRowBackground(CinemaTheme.surface)
                }
            }
            .scrollContentBackground(.hidden)
            .background(CinemaTheme.background)
            .navigationTitle(isNew ? "Add account" : "Edit account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(!canSave || isSaving)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func credentials() -> WebDAVCredentials? {
        let pass = password.isEmpty ? (Secrets.webdavPassword(account: account.id) ?? "") : password
        guard !pass.isEmpty else { return nil }
        return WebDAVCredentials(baseURL: WebDAV.normalizedBaseURL(account.baseURL), username: account.username, password: pass)
    }

    private func test() async {
        guard let credentials = credentials() else { return }
        isTesting = true
        defer { isTesting = false }
        do {
            let folders = try await WebDAV.rootFolders(credentials)
            testOK = true
            testResult = "Connected · \(folders.count) folders"
        } catch {
            testOK = false
            testResult = error.localizedDescription
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        await model.saveAccount(account, password: password.isEmpty ? nil : password)
        dismiss()
    }
}
