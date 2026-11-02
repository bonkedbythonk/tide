import SwiftUI

struct SidebarView: View {
    @Environment(Library.self) private var library
    @Environment(Router.self) private var router

    var body: some View {
        List {
            SidebarRow(route: .home) { Label("Home", systemImage: "house") }
            SidebarRow(route: .search) { Label("Search", systemImage: "magnifyingglass") }

            Section("Library") {
                SidebarRow(route: .liked, onDrop: { library.like($0) }) {
                    Label("Liked Songs", systemImage: "heart.fill")
                }
                SidebarRow(route: .savedAlbums) { Label("Saved Albums", systemImage: "square.stack") }
            }

            Section("Playlists") {
                ForEach(library.playlists) { p in
                    SidebarRow(route: .page(p.id), onDrop: { library.add($0, to: p.id) }) {
                        Label {
                            Text(p.title)
                        } icon: {
                            Artwork(hue: p.hue, url: p.artwork, side: 18, radius: 4, symbol: nil)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        // Clear of the window buttons, now that there's no title bar.
        .safeAreaPadding(.top, 30)
        .safeAreaInset(edge: .bottom) {
            if library.state == .ready {
                HStack {
                    Button {
                        Task { await library.refresh() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    Spacer()
                    Menu {
                        Button("Sign Out") { Task { await library.signOut() } }
                    } label: {
                        Image(systemName: "person.crop.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                .buttonStyle(.borderless)
                .padding(12)
            }
        }
    }
}

/// One sidebar entry with its own highlight instead of the system selection:
/// a soft white wash, like the playlist rows. Rows with `onDrop` take dragged
/// songs and light up while they hover over it.
struct SidebarRow<Content: View>: View {
    @Environment(Router.self) private var router
    let route: Route
    var onDrop: (([String]) -> Void)?
    @ViewBuilder let content: Content
    @State private var hovering = false
    @State private var targeted = false

    var body: some View {
        let selected = router.current == route && !router.showNowPlaying
        Button { router.go(route) } label: {
            content
                .fontWeight(selected ? .semibold : .regular)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(
                    targeted ? Color.primary.opacity(0.2)
                        : selected ? Color.primary.opacity(0.13)
                        : hovering ? Color.primary.opacity(0.06) : .clear
                )
            )
            .onHover { hovering = $0 }
            .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
            .listRowBackground(Color.clear)
            .dropDestination(for: String.self) { items, _ in
                let ids = SongDrag.ids(from: items)
                guard let onDrop, !ids.isEmpty else { return false }
                onDrop(ids)
                return true
            } isTargeted: { targeted = $0 && onDrop != nil }
    }
}
