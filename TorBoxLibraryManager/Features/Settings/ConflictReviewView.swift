import SwiftUI

/// §8.1: overrides that differ between this device and Supabase. Local is kept unless you
/// choose remote here.
struct ConflictReviewView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var useRemote: Set<String> = []

    var body: some View {
        List {
            Section {
                Text("These folders have a different match in Supabase than on this device. The local version is kept unless you pick Supabase’s.")
                    .font(.footnote)
                    .foregroundStyle(CinemaTheme.secondary)
            }
            .listRowBackground(Color.clear)
            ForEach(model.snapshot.conflicts) { conflict in
                VStack(alignment: .leading, spacing: 8) {
                    Text(conflict.folderName).font(.subheadline.weight(.medium)).lineLimit(3)
                    Picker("Version", selection: Binding(
                        get: { useRemote.contains(conflict.folderName) },
                        set: { remote in
                            if remote { useRemote.insert(conflict.folderName) } else { useRemote.remove(conflict.folderName) }
                        }
                    )) {
                        Text("This device").tag(false)
                        Text("Supabase").tag(true)
                    }
                    .pickerStyle(.segmented)
                    differences(conflict)
                }
                .padding(.vertical, 4)
                .listRowBackground(CinemaTheme.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .background(CinemaTheme.background)
        .navigationTitle("Differing overrides")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Use all remote") {
                    useRemote = Set(model.snapshot.conflicts.map(\.folderName))
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Apply") {
                    let all = Set(model.snapshot.conflicts.map(\.folderName))
                    let remote = useRemote
                    Task {
                        await model.resolveConflicts(useRemote: remote, keepLocal: all.subtracting(remote))
                        dismiss()
                    }
                }
            }
        }
    }

    private func differences(_ conflict: OverrideConflict) -> some View {
        let keys = Set(conflict.local.keys).union(conflict.remote.keys).filter { conflict.local[$0] != conflict.remote[$0] }.sorted()
        return VStack(alignment: .leading, spacing: 3) {
            ForEach(keys.prefix(6), id: \.self) { key in
                Text("\(key): \(describe(conflict.local[key])) → \(describe(conflict.remote[key]))")
                    .font(.caption)
                    .foregroundStyle(CinemaTheme.secondary)
                    .lineLimit(2)
            }
        }
    }

    private func describe(_ value: JSONValue?) -> String {
        guard let value, !value.isNull else { return "—" }
        if case .array(let items) = value { return "\(items.count) items" }
        return String(value.pythonString.prefix(40))
    }
}
