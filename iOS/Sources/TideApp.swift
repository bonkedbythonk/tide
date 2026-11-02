import AVFoundation
import SwiftUI

@main
struct TideApp: App {
    @State private var remote = Remote()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        URLCache.shared = URLCache(memoryCapacity: 8 << 20, diskCapacity: 100 << 20)
    }

    var body: some Scene {
        WindowGroup {
            NowPlayingScreen()
                .environment(remote)
                .onChange(of: scenePhase, initial: true) {
                    if scenePhase == .active { remote.start() }
                }
        }
    }
}
