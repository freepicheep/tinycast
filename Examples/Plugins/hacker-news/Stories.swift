import Foundation
import Tinycast

struct Stories: View {
    @AppStorage("feed") private var feed = Feed.frontPage
    @State private var query = ""
    @State private var stories: [Story] = []
    @State private var isLoading = true
    @State private var failure: String? = nil

    var body: some View {
        let now = Int(Date().timeIntervalSince1970)
        return List {
            ForEach(stories) { story in
                if let title = story.title {
                    Label(title, systemImage: "arrowtriangle.up.fill")
                        .foregroundStyle(.orange)
                        .subtitle(story.site ?? "")
                        .badge("\(story.points ?? 0) points")
                        .badge("\(story.numComments ?? 0) comments")
                        .badge(story.age(now: now))
                        .searchKeywords(story.author ?? "", story.site ?? "")
                        .contextMenu {
                            Link("Open Story", destination: story.storyURL)
                            Link("Open Comments", destination: story.discussionURL)
                            ShareLink("Copy Link", item: story.storyURL)
                                .keyboardShortcut("c", modifiers: [.command, .shift])
                            ShareLink("Copy Comments Link", item: story.discussionURL)
                            Divider()
                            ForEach(Feed.allCases.filter { $0 != feed }) { other in
                                Button("Show \(other.title)", systemImage: other.systemImage) { feed = other }
                                    .keyboardShortcut(other.shortcut)
                            }
                        }
                }
            }
            if !isLoading && stories.isEmpty {
                if let failure {
                    ContentUnavailableView(failure, systemImage: "wifi.exclamationmark")
                } else {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
        .navigationTitle(feed.title)
        .searchable(text: $query, prompt: "Search \(feed.title)")
        .toolbar {
            Picker("Feed", selection: $feed) {
                ForEach(Feed.allCases) { feed in
                    Label(feed.title, systemImage: feed.systemImage).tag(feed)
                }
            }
        }
        .loading(isLoading)
        .task(id: feed.rawValue + "\n" + query) { await load() }
    }

    private func load() async {
        isLoading = true
        // Typing restarts this task, so only a pause long enough to read reaches the network.
        if !query.isEmpty {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
        }
        do {
            let loaded = try await feed.stories(searching: query)
            guard !Task.isCancelled else { return }
            stories = loaded
            failure = nil
        } catch {
            guard !Task.isCancelled else { return }
            stories = []
            failure = "Couldn't load stories"
            print("Hacker News: \(error)")
        }
        isLoading = false
    }
}
