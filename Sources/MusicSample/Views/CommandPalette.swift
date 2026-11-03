import SwiftUI

/// The ⌘K palette, after anicat's: type to find a page, a playlist, a song you've
/// seen or an action; arrows move, Return runs, Escape or a click outside closes.
struct CommandPalette: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @Environment(Router.self) private var router

    private struct Command: Identifiable {
        let id: String
        let label: String
        let group: String
        let symbol: String
        let action: () -> Void
    }

    @State private var query = ""
    @State private var highlighted = 0
    /// Hover ignores a resting pointer for a moment after an arrow key, or the list
    /// scrolling under it would take the highlight back.
    @State private var keyboardMoveAt = Date.distantPast
    @FocusState private var focused: Bool

    private var fixed: [Command] {
        var list: [Command] = [
            Command(id: "home", label: "Home", group: "Go to", symbol: "house") { router.go(.home) },
            Command(id: "search", label: "Search", group: "Go to", symbol: "magnifyingglass") { router.openSearch() },
            Command(id: "liked", label: "Liked Songs", group: "Go to", symbol: "heart") { router.go(.liked) },
            Command(id: "library", label: "Library", group: "Go to", symbol: "books.vertical") { router.go(.library) },
            Command(id: "history", label: "History", group: "Go to", symbol: "clock.arrow.circlepath") { router.go(.history) },
        ]
        list += library.playlists.map { p in
            Command(id: "p" + p.id, label: p.title, group: "Playlists", symbol: "music.note.list") { router.go(.page(p.id)) }
        }
        list += library.savedAlbums.map { a in
            Command(id: "a" + a.id, label: a.title, group: "Albums", symbol: "square.stack") { router.go(.page(a.id)) }
        }
        list += [
            Command(id: "toggle", label: player.isPlaying ? "Pause" : "Play", group: "Actions", symbol: "playpause") { player.toggle() },
            Command(id: "next", label: "Next Song", group: "Actions", symbol: "forward") { player.next() },
            Command(id: "previous", label: "Previous Song", group: "Actions", symbol: "backward") { player.previous() },
            Command(id: "shuffle", label: player.shuffle ? "Turn Shuffle Off" : "Turn Shuffle On", group: "Actions", symbol: "shuffle") { withAnimation(.snappy(duration: 0.45)) { player.shuffle.toggle() } },
            Command(id: "repeat", label: "Change Repeat", group: "Actions", symbol: "repeat") { player.cycleRepeat() },
            Command(id: "nowplaying", label: "Now Playing", group: "Actions", symbol: "rectangle.on.rectangle") { router.showNowPlaying = true },
            Command(id: "lyrics", label: "Lyrics", group: "Actions", symbol: "quote.bubble") { router.togglePanel(.lyrics) },
            Command(id: "queue", label: "Up Next", group: "Actions", symbol: "list.bullet") { router.togglePanel(.queue) },
            Command(id: "refresh", label: "Refresh Library", group: "Actions", symbol: "arrow.clockwise") { Task { await library.refresh() } },
            Command(id: "settings", label: "Settings", group: "Actions", symbol: "gearshape") { router.go(.settings) },
            Command(id: "shortcuts", label: "Keyboard Shortcuts", group: "Actions", symbol: "keyboard") { router.showShortcuts = true },
        ]
        if let s = player.current {
            list.insert(Command(id: "like", label: library.isLiked(s.id) ? "Unlike \(s.title)" : "Like \(s.title)",
                                group: "Actions", symbol: "heart") { library.toggleLike(s.id) }, at: list.count - 3)
            list.insert(Command(id: "radio", label: "Start Radio from This Song",
                                group: "Actions", symbol: "dot.radiowaves.left.and.right") { player.playRadio(s) }, at: list.count - 3)
            list.insert(Command(id: "video", label: player.videoMode ? "Switch to Song" : "Switch to Music Video",
                                group: "Actions", symbol: "play.rectangle") { player.videoMode.toggle() }, at: list.count - 3)
        }
        return list
    }

    private var matches: [Command] {
        let q = Fuzzy.words(query)
        guard !q.isEmpty else { return fixed.filter { $0.group != "Albums" && $0.group != "Playlists" } }
        // Best match first; a song you've seen counts once, under its title.
        let songs = library.knownSongs
            .map { ($0, Fuzzy.score(q, in: "\($0.title) \($0.artist)")) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(8)
            .map { s, _ in
                Command(id: "s" + s.id, label: "\(s.title) — \(s.artist)", group: "Songs", symbol: "music.note") {
                    player.play(s, in: [s])
                }
            }
        let commands = fixed
            .map { ($0, Fuzzy.score(q, in: $0.label)) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
        return commands + songs
    }

    var body: some View {
        let list = matches
        ZStack(alignment: .top) {
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                .onTapGesture(perform: close)

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Go to a page, play a song, run an action", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16))
                        .focused($focused)
                        .onSubmit { run(list) }
                        .onChange(of: query) { highlighted = 0 }
                        .onKeyPress(.downArrow) { move(1, in: list) }
                        .onKeyPress(.upArrow) { move(-1, in: list) }
                        .onExitCommand(perform: close)
                    Text("esc").font(.caption.monospaced()).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                if !list.isEmpty {
                    Divider().opacity(0.5)
                    results(list)
                }
            }
            .frame(width: 560)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.12)))
            .shadow(color: .black.opacity(0.35), radius: 30, y: 12)
            .padding(.top, 110)
        }
        // Asked again a beat later: the field isn't in the window yet while the
        // palette is being inserted, and that first focus is dropped.
        .task {
            focused = true
            try? await Task.sleep(for: .milliseconds(80))
            focused = true
        }
    }

    private func results(_ list: [Command]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { index, command in
                        if index == 0 || list[index - 1].group != command.group {
                            Text(command.group)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 16)
                                .padding(.top, 10)
                                .padding(.bottom, 4)
                        }
                        HStack(spacing: 10) {
                            Image(systemName: command.symbol)
                                .frame(width: 18)
                                .foregroundStyle(.secondary)
                            Text(command.label).lineLimit(1)
                            Spacer()
                        }
                        .font(.system(size: 13.5))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(index == highlighted ? Color.primary.opacity(0.12) : .clear)
                        )
                        .padding(.horizontal, 6)
                        .contentShape(Rectangle())
                        .onTapGesture { highlighted = index; run(list) }
                        .stableHover { inside in
                            guard inside, Date().timeIntervalSince(keyboardMoveAt) > 0.4 else { return }
                            highlighted = index
                        }
                        .id(command.id)
                    }
                }
                .padding(.bottom, 8)
            }
            .frame(maxHeight: 380)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: highlighted) { _, index in
                // Only arrow keys scroll; hover-driven changes leave the list still.
                guard Date().timeIntervalSince(keyboardMoveAt) < 0.1, list.indices.contains(index) else { return }
                proxy.scrollTo(list[index].id)
            }
        }
    }

    private func move(_ step: Int, in list: [Command]) -> KeyPress.Result {
        guard !list.isEmpty else { return .ignored }
        keyboardMoveAt = Date()
        highlighted = min(max(highlighted + step, 0), list.count - 1)
        return .handled
    }

    private func run(_ list: [Command]) {
        guard list.indices.contains(highlighted) else { return }
        let command = list[highlighted]
        close()
        command.action()
    }

    private func close() {
        withAnimation(.snappy(duration: 0.2)) { router.showPalette = false }
    }
}
