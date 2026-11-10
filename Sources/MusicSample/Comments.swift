import SwiftUI

struct Comment: Identifiable {
    let id: String
    let author: String
    let text: String
    let likes: String
    let published: String
}

/// A song's comments from YouTube itself (YouTube Music has none), a page of about
/// 20 at a time. The plain website client, no sign-in needed.
enum YTComments {
    /// The first page when `token` is nil. `next` is nil at the end, or when comments are off.
    static func page(_ videoId: String, token: String?) async throws -> (comments: [Comment], next: String?) {
        var token = token
        if token == nil {
            let watch = try await call(["videoId": videoId])
            let section = YTParse.findAll("itemSectionRenderer", in: watch)
                .first { $0["sectionIdentifier"] as? String == "comment-item-section" }
            token = YTParse.dig((section?["contents"] as? [JSON])?.first, "continuationItemRenderer",
                                "continuationEndpoint", "continuationCommand", "token") as? String
        }
        guard let token else { return ([], nil) }
        let json = try await call(["continuation": token])
        let comments = YTParse.findAll("commentEntityPayload", in: json["frameworkUpdates"] ?? [:]).compactMap { c -> Comment? in
            guard let id = YTParse.dig(c, "properties", "commentId") as? String else { return nil }
            return Comment(id: id,
                           author: YTParse.dig(c, "author", "displayName") as? String ?? "",
                           text: YTParse.dig(c, "properties", "content", "content") as? String ?? "",
                           likes: YTParse.dig(c, "toolbar", "likeCountNotliked") as? String ?? "",
                           published: YTParse.dig(c, "properties", "publishedTime") as? String ?? "")
        }
        // The list's own "more" item is the last one; the ones inside threads are for replies.
        let action = ((json["onResponseReceivedEndpoints"] as? [JSON])?.last)?
            .first { $0.key != "clickTrackingParams" }?.value
        let next = YTParse.dig(((action as? JSON)?["continuationItems"] as? [JSON])?.last, "continuationItemRenderer",
                               "continuationEndpoint", "continuationCommand", "token") as? String
        return (comments, next)
    }

    private static func call(_ body: JSON) async throws -> JSON {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        f.timeZone = TimeZone(identifier: "UTC")
        var payload = body
        payload["context"] = ["client": ["clientName": "WEB", "hl": "en",
                                         "clientVersion": "2.\(f.string(from: .now.addingTimeInterval(-86_400))).01.00"]]
        var req = URLRequest(url: URL(string: "https://www.youtube.com/youtubei/v1/next?prettyPrint=false")!)
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(YTClient.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw YTError.http(status) }
        return try JSONSerialization.jsonObject(with: data) as? JSON ?? [:]
    }
}

/// The playing song's YouTube comments; more load as you near the end.
struct CommentsView: View {
    @Environment(Player.self) private var player
    @State private var comments: [Comment] = []
    @State private var next: String?
    @State private var loading = false
    @State private var failed = false
    @State private var done = false

    var body: some View {
        if let song = player.current {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(comments) { c in
                        row(c).onAppear { if c.id == comments.last?.id { Task { await load(song.id) } } }
                    }
                    if loading {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                    } else if done, comments.isEmpty {
                        Text("No comments").foregroundStyle(.secondary).frame(maxWidth: .infinity)
                    } else if failed {
                        Button("Couldn't load comments. Try again") { Task { await load(song.id) } }
                            .buttonStyle(.borderless).frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .scrollIndicators(.hidden)
            .task(id: song.id) {
                comments = []; next = nil; done = false; failed = false; loading = false
                await load(song.id)
            }
        } else {
            ContentUnavailableView("Nothing playing", systemImage: "music.note")
        }
    }

    private func row(_ c: Comment) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(c.author).fontWeight(.semibold)
                Text(c.published).foregroundStyle(.secondary)
            }
            .font(.caption)
            Text(linkingTimes(c.text))
                .textSelection(.enabled)
                .environment(\.openURL, OpenURLAction { url in
                    guard url.scheme == "seek", let t = Double(url.host ?? "") else { return .systemAction }
                    player.seek(t)
                    return .handled
                })
            if !c.likes.isEmpty {
                Label(c.likes, systemImage: "hand.thumbsup").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// "1:23" and "1:02:03" become links that jump the song there.
    private func linkingTimes(_ text: String) -> AttributedString {
        var out = AttributedString(text)
        for m in text.matches(of: #/\b(?:(\d{1,2}):)?(\d{1,2}):(\d{2})\b/#) {
            let seconds = (Int(m.1 ?? "0") ?? 0) * 3600 + (Int(m.2) ?? 0) * 60 + (Int(m.3) ?? 0)
            guard let range = Range(m.range, in: out) else { continue }
            out[range].link = URL(string: "seek://\(seconds)")
        }
        return out
    }

    private func load(_ videoId: String) async {
        guard !loading, !done else { return }
        loading = true
        failed = false
        defer { loading = false }
        do {
            let page = try await YTComments.page(videoId, token: next)
            guard player.current?.id == videoId else { return }
            comments += page.comments
            next = page.next
            done = page.next == nil
        } catch {
            failed = true
        }
    }
}
