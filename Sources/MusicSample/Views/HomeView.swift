import SwiftUI

struct HomeView: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @Environment(HomeConfig.self) private var home
    @State private var customizing = false

    var body: some View {
        let shelves = home.arrange(library.home)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 30) {
                HStack {
                    Text(greeting).font(.system(size: 30, weight: .bold))
                    Spacer()
                    Button { customizing = true } label: {
                        Label("Customize", systemImage: "slider.horizontal.3")
                    }
                    .buttonStyle(PillButtonStyle(prominent: false))
                    .help("Reorder or hide Home sections")
                }
                .padding(.horizontal, 24)


                ForEach(shelves) { shelf in
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(shelf: shelf) { customizing = true }
                        ShelfContent(shelf: shelf)
                    }
                }
                // Reaching the bottom asks YouTube for the next few sections.
                Color.clear
                    .frame(height: 1)
                    .onAppear { Task { await library.loadMoreHome(pages: 2) } }
            }
            .padding(.top, 50)
            .padding(.bottom, 20)
        }
        .sheet(isPresented: $customizing) { CustomizeHomeSheet() }
        .onChange(of: library.home.count, initial: true) { home.learn(library.home) }
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<12: "Good morning"
        case 12..<18: "Good afternoon"
        default: "Good evening"
        }
    }
}

struct ShelfContent: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @Environment(Router.self) private var router
    let shelf: HomeShelf

    var body: some View {
        if shelf.isSongList {
            SongGrid(songs: shelf.songs)
        } else {
            let videos = shelf.songs
            Shelf {
                ForEach(shelf.items) { item in
                    switch item {
                    case .song(let s, let video):
                        MediaCard(title: s.title, subtitle: s.artist, hue: s.hue, artwork: s.artwork,
                                  width: video ? 270 : 165, wide: video,
                                  symbol: video ? "play.rectangle.fill" : "music.note",
                                  open: {
                                      player.play(s, in: videos)
                                      if video { withAnimation(.spring(duration: 0.45, bounce: 0)) { router.showNowPlaying = true } }
                                  },
                                  play: { player.play(s, in: videos) },
                                  prefetch: { player.prefetch(s, video: player.prefersVideo) })
                    case .media(let m):
                        MediaItemCard(item: m)
                    }
                }
            }
        }
    }
}

struct MediaItemCard: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @Environment(Router.self) private var router
    let item: MediaItem

    var body: some View {
        MediaCard(title: item.title, subtitle: item.subtitle, hue: item.hue, artwork: item.artwork,
                  round: item.kind == .artist,
                  open: { router.go(.page(item.id)) },
                  play: item.kind == .artist ? nil : {
                      Task {
                          if let page = await library.page(item.id) { player.playAll(page.songs) }
                      }
                  })
    }
}

struct SectionHeader: View {
    @Environment(HomeConfig.self) private var home
    @Environment(Player.self) private var player
    let shelf: HomeShelf
    let customize: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(shelf.title).font(.title2.bold())
            Spacer()
            if !shelf.songs.isEmpty {
                Button { player.playAll(shelf.songs) } label: {
                    Label("Play all", systemImage: "play.fill")
                }
                .buttonStyle(PillButtonStyle(prominent: false))
            }
            Menu {
                Button("Hide This Section") { withAnimation { _ = home.hidden.insert(shelf.title) } }
                Button("Customize Home…", action: customize)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 24)
    }
}

struct CustomizeHomeSheet: View {
    @Environment(HomeConfig.self) private var home
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var home = home
        VStack(alignment: .leading, spacing: 14) {
            Text("Customize Home").font(.title2.bold())
            Text("Drag to reorder. Switch off what you never use.")
                .foregroundStyle(.secondary)
            List {
                ForEach(home.order, id: \.self) { title in
                    HStack {
                        Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                        Toggle(title, isOn: Binding(
                            get: { !home.hidden.contains(title) },
                            set: { on in
                                if on { home.hidden.remove(title) } else { home.hidden.insert(title) }
                            }
                        ))
                        .toggleStyle(.switch)
                    }
                    .padding(.vertical, 2)
                }
                .onMove { home.order.move(fromOffsets: $0, toOffset: $1) }
            }
            .frame(height: 380)
            HStack {
                Button("Reset") { home.reset() }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
