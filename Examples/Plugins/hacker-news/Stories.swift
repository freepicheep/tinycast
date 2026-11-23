import Foundation
import Tinycast

struct Stories: View {
    @AppStorage("feed") private var feedName = Feed.frontPage.rawValue
    @State private var query = ""
    @State private var stories: [Story] = []
    @State private var isLoading = true
    @State private var failure: String? = nil

    private var feed: Feed { Feed(rawValue: feedName) ?? .frontPage }

    var body: some View {
        let now = Int(Date().timeIntervalSince1970)
        return List {
            ForEach(stories) { story in
                if let title = story.title {
                    Item(title, subtitle: story.site, systemImage: "arrowtriangle.up.fill")
                        .id(story.objectID)
                        .tint(.orange)
                        .badge("\(story.points ?? 0) points")
                        .badge("\(story.numComments ?? 0) comments")
                        .badge(story.age(now: now))
                        .keywords([story.author ?? "", story.site ?? ""])
                        .actions {
                            Link("Open Story", destination: story.storyURL)
                            Link("Open Comments", destination: story.discussionURL)
                            CopyButton("Copy Link", text: story.storyURL)
                                .keyboardShortcut("c", modifiers: [.command, .shift])
                            CopyButton("Copy Comments Link", text: story.discussionURL)
                            for other in Feed.allCases where other != feed {
                                Button("Show \(other.title)", systemImage: other.systemImage) {
                                    feedName = other.rawValue
                                }
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
        .searchBarAccessory(
            Dropdown("Feed", selection: $feedName) {
                for feed in Feed.allCases {
                    Choice(feed.title, value: feed.rawValue, systemImage: feed.systemImage)
                }
            })
        .loading(isLoading)
        .task(id: feedName + "\n" + query) { await load() }
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
            fail("Couldn't load stories")
            print("Hacker News: \(error)")
        }
        isLoading = false
    }

    private func fail(_ message: String) {
        stories = []
        failure = message
        isLoading = false
    }
}
