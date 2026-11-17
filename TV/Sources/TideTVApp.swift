import SwiftUI

@main
struct TideTVApp: App {
    @State private var link: MacLink
    @State private var player: TVPlayer
    @State private var idle = IdleWatch()

    init() {
        let link = MacLink()
        _link = State(initialValue: link)
        _player = State(initialValue: TVPlayer(link: link))
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                AuroraBackground(artwork: player.current?.artwork, live: player.videoColors)
                if link.state == .connected {
                    MainView()
                } else {
                    ConnectView()
                }
            }
            .environment(link)
            .environment(player)
            .environment(idle)
            .tint(Tide.blue)
            .preferredColorScheme(.dark)
            .onAppear {
                link.start()
                idle.start(player)
            }
            // Keeps an OLED screen from holding the same picture for hours.
            .fullScreenCover(isPresented: Binding(get: { idle.idle }, set: { if !$0 { idle.wake() } })) {
                IdleView().environment(link).environment(player).environment(idle)
            }
            .onChange(of: player.current?.id) { idle.touch() }
        }
    }
}

/// Picks the Mac to play through and takes its pairing code (once).
struct ConnectView: View {
    @Environment(MacLink.self) private var link
    @State private var chosen: MacLink.Found?
    @State private var code = ""

    var body: some View {
        VStack(spacing: 36) {
            if let logo = UIImage(named: "logo") {
                Image(uiImage: logo).resizable().frame(width: 200, height: 200)
                    .shadow(color: .black.opacity(0.4), radius: 30, y: 14)
            }
            Text("Tide").font(.system(size: 76, weight: .bold))
            switch link.state {
            case .connecting:
                ProgressView("Connecting...")
            case .failed(let message):
                Text(message).font(.system(size: 28)).foregroundStyle(.red.opacity(0.9))
            default:
                EmptyView()
            }
            if let chosen {
                Text("Enter the pairing code from Tide's Settings on \(chosen.name)")
                    .font(.system(size: 30)).foregroundStyle(.white.opacity(0.65))
                TextField("Pairing code", text: $code)
                    .keyboardType(.numberPad)
                    .frame(width: 520)
                HStack(spacing: 30) {
                    Button("Connect") { Task { await link.connect(chosen, code: code) } }
                        .buttonStyle(PillStyle(prominent: true))
                        .disabled(code.count < 6)
                    Button("Back") { self.chosen = nil }.buttonStyle(PillStyle())
                }
            } else if link.found.isEmpty {
                ProgressView()
                Text("Looking for Tide on your Mac. Open Settings in Tide and turn on Apple TV.")
                    .font(.system(size: 30)).foregroundStyle(.white.opacity(0.65))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 1000)
            } else {
                Text("Play through").font(.system(size: 30)).foregroundStyle(.white.opacity(0.65))
                ForEach(link.found) { mac in
                    Button {
                        chosen = mac
                        code = ""
                    } label: {
                        Label(mac.name, systemImage: "laptopcomputer")
                    }
                    .buttonStyle(PillStyle())
                }
            }
        }
        .padding(80)
    }
}

struct MainView: View {
    @Environment(TVPlayer.self) private var player
    @State private var tab = "home"

    var body: some View {
        TabView(selection: $tab) {
            if player.current != nil {
                Tab("Now Playing", systemImage: "waveform", value: "now") { NowPlayingView() }
            }
            Tab("Home", systemImage: "house", value: "home") { NavigationStack { HomeTab() } }
            Tab("Search", systemImage: "magnifyingglass", value: "search") { NavigationStack { SearchTab() } }
            Tab("Library", systemImage: "square.stack", value: "library") { NavigationStack { LibraryTab() } }
        }
        .onPlayPauseCommand { player.toggle() }
        // Starting a song shows it playing.
        .onChange(of: player.current?.id) { old, new in
            if old == nil, new != nil { tab = "now" }
        }
    }
}
