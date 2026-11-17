import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// What kind of track a song is, judged from its title, artist and album by Apple's
/// on-device model, so smart transitions don't beat-match a slowed edit or overlap a
/// piano cover. The audio analysis can't always tell: a steady piano left hand reads as
/// a beat, and a slowed edit's stretched drums throw the beat tracking off. Each song is
/// judged once and kept on disk. Regular without Apple Intelligence.
enum SongKinds {
    static func kind(of song: Song) async -> SongKind {
        let name = "kind-\(song.id)"
        if let cached = DiskCache.load(SongKind.self, name) { return cached }
        #if canImport(FoundationModels)
        if #available(macOS 26, *), let kind = await MoodPlanner.withDeadline(8, { await judged(song) }) {
            DiskCache.save(kind, name)
            return kind
        }
        #endif
        return .regular
    }

    #if canImport(FoundationModels)
    @available(macOS 26, *)
    private static func judged(_ song: Song) async -> SongKind? {
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        let session = LanguageModelSession(instructions: """
            You sort songs for a DJ by their title, artist and album. Answer "unplugged" for \
            a track without drums: piano, acoustic or guitar covers and arrangements, \
            orchestral, string or music box versions, a cappella, ambient. "Pf" and "Pf solo" \
            in a title mean piano. Answer "altered" only when the title says slowed, reverb, \
            nightcore, sped up or 8D. Answer "regular" for everything else, including \
            remixes, other versions, lofi and instrumentals with drums, and whenever you are \
            unsure.
            """)
        let ask = "Title: \(song.title)\nArtist: \(song.artist)\nAlbum: \(song.album)"
        let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: 20)
        guard let answer = try? await session.respond(to: ask, generating: SongKindAnswer.self, options: options).content else { return nil }
        return switch answer.kind {
        case .regular: .regular
        case .unplugged: .unplugged
        case .altered: .altered
        }
    }
    #endif
}

#if canImport(FoundationModels)
@available(macOS 26, *)
@Generable
struct SongKindAnswer {
    var kind: SongKindChoice
}

@available(macOS 26, *)
@Generable
enum SongKindChoice {
    case regular, unplugged, altered
}
#endif
