import SwiftUI

struct SidebarView: View {
    @Environment(Library.self) private var library
    @Environment(Router.self) private var router

    var body: some View {
        let selection = Binding<Route?>(
            get: { router.current },
            set: { if let r = $0 { router.go(r) } }
        )

        List(selection: selection) {
            Label("Home", systemImage: "house").tag(Route.home)
            Label("Search", systemImage: "magnifyingglass").tag(Route.search)

            Section("Library") {
                DropRow(onDrop: { library.like($0) }) {
                    Label("Liked Songs", systemImage: "heart.fill")
                }
                .tag(Route.liked)
                Label("Saved Albums", systemImage: "square.stack").tag(Route.savedAlbums)
            }

            Section("Playlists") {
                ForEach(library.playlists) { p in
                    DropRow(onDrop: { library.add($0, to: p.id) }) {
                        Label {
                            Text(p.title)
                        } icon: {
                            Artwork(hue: p.hue, url: p.artwork, side: 18, radius: 4, symbol: nil)
                        }
                    }
                    .tag(Route.page(p.id))
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

/// Sidebar row that accepts dragged songs and lights up while they hover over it.
struct DropRow<Content: View>: View {
    let onDrop: ([String]) -> Void
    @ViewBuilder let content: Content
    @State private var targeted = false

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.accentColor.opacity(targeted ? 0.3 : 0))
                    .padding(.horizontal, -6)
                    .padding(.vertical, -3)
            )
            .dropDestination(for: String.self) { items, _ in
                let ids = SongDrag.ids(from: items)
                guard !ids.isEmpty else { return false }
                onDrop(ids)
                return true
            } isTargeted: { targeted = $0 }
    }
}
