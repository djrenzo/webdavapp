import SwiftUI

struct LibraryControls: View {
    @Bindable var model: LibraryModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 14) {
            searchField
            Picker("Media type", selection: $model.filter) {
                ForEach(LibraryFilter.allCases) { filter in Text(filter.rawValue).tag(filter) }
            }
            .pickerStyle(.segmented)
            HStack(spacing: 8) {
                accountFilters
                sortMenu
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(CinemaTheme.secondary).accessibilityHidden(true)
            TextField("Search titles and folders", text: $model.search)
                .font(.body).focused($searchFocused)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
                .submitLabel(.search).onSubmit { searchFocused = false }
            if !model.search.isEmpty {
                Button {
                    model.search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(CinemaTheme.secondary).frame(width: 28, height: 36)
                }
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 50)
        .background(CinemaTheme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.05)) }
    }

    private var accountFilters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("All accounts", id: nil)
                ForEach(model.accounts) { account in chip(account.name, id: account.id) }
            }
        }
        .contentMargins(.trailing, 4)
    }

    private func chip(_ label: String, id: UUID?) -> some View {
        let selected = model.accountID == id
        return Button { model.accountID = id } label: {
            Text(label)
                .font(.footnote.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? CinemaTheme.background : CinemaTheme.secondary)
                .padding(.horizontal, 13)
                .frame(minHeight: 40)
                .background(selected ? CinemaTheme.blue : CinemaTheme.surface, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort library", selection: $model.sort) {
                ForEach(LibrarySort.allCases) { sort in Text(sort.rawValue).tag(sort) }
            }
        } label: {
            HStack(spacing: 6) {
                Text(model.sort.shortLabel)
                Image(systemName: "arrow.up.arrow.down").font(.caption2)
            }
            .font(.footnote)
            .foregroundStyle(CinemaTheme.secondary)
            .padding(.horizontal, 12)
            .frame(minHeight: 40)
            .background(CinemaTheme.surface, in: RoundedRectangle(cornerRadius: 12))
        }
        .accessibilityLabel("Sort: \(model.sort.rawValue)")
    }
}
