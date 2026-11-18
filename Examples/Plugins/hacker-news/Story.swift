import Foundation
import Tinycast

/// One hit from HN's Algolia API; a field HN leaves out of a hit arrives as nil.
struct Story: Decodable {
    let objectID: String
    let title: String?
    let url: String?
    let author: String?
    let points: Int?
    let numComments: Int?
    let createdAtI: Int

    var discussionURL: String { "https://news.ycombinator.com/item?id=\(objectID)" }

    /// Where ↵ goes: the linked page, or the thread for an Ask HN that links nowhere.
    var storyURL: String { url ?? discussionURL }

    /// `github.com` from `https://www.github.com/a/b`, the way HN prints it beside a title.
    var site: String? {
        guard var rest = url else { return nil }
        for prefix in ["https://", "http://"] where rest.hasPrefix(prefix) {
            rest = String(rest.dropFirst(prefix.count))
        }
        if rest.hasPrefix("www.") { rest = String(rest.dropFirst(4)) }
        let host = rest.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        return host.isEmpty ? nil : String(host)
    }

    /// `5m`, `3h`, `2d`: how long ago, as HN's own lists say it.
    func age(now: Int) -> String {
        let seconds = max(now - createdAtI, 0)
        if seconds < 3600 { return "\(max(seconds / 60, 1))m" }
        if seconds < 86_400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86_400)d"
    }
}

struct SearchResponse: Decodable {
    let hits: [Story]
}

enum FeedError: Error {
    case status(Int)
}

enum Feed: String, CaseIterable {
    case frontPage = "front-page"
    case newest
    case ask
    case show

    var title: String {
        switch self {
        case .frontPage: "Front Page"
        case .newest: "Newest"
        case .ask: "Ask HN"
        case .show: "Show HN"
        }
    }

    var systemImage: String {
        switch self {
        case .frontPage: "flame"
        case .newest: "clock"
        case .ask: "questionmark.bubble"
        case .show: "eye"
        }
    }

    var shortcut: KeyEquivalent {
        switch self {
        case .frontPage: "1"
        case .newest: "2"
        case .ask: "3"
        case .show: "4"
        }
    }

    private var tag: String {
        switch self {
        case .frontPage: "front_page"
        case .newest: "story"
        case .ask: "ask_hn"
        case .show: "show_hn"
        }
    }

    /// A search ranks by relevance across all of HN's stories of the feed's kind; a feed by its order.
    func url(searching query: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "hn.algolia.com"
        let ranked = !query.isEmpty || self == .frontPage
        components.path = ranked ? "/api/v1/search" : "/api/v1/search_by_date"
        var items = [
            URLQueryItem(name: "tags", value: query.isEmpty ? tag : (self == .frontPage ? "story" : tag)),
            URLQueryItem(name: "hitsPerPage", value: "40")
        ]
        if !query.isEmpty { items.append(URLQueryItem(name: "query", value: query)) }
        components.queryItems = items
        return components.url
    }

    /// The feed's stories, or those matching `query`.
    func stories(searching query: String = "") async throws -> [Story] {
        guard let url = url(searching: query) else { return [] }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard response.statusCode == 200 else { throw FeedError.status(response.statusCode) }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(SearchResponse.self, from: data).hits
    }
}
