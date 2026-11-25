import Foundation
import Tinycast

/// The front page's top story in the menu bar, refreshed by the manifest's interval.
struct TopStory: View {
    @State private var stories: [Story] = []
    @State private var isLoading = true

    var body: some View {
        MenuBarExtra(stories.first.map { "▲ \($0.points ?? 0)" }, systemImage: "newspaper") {
            ForEach(stories.prefix(5)) { story in
                Link(story.title ?? "Untitled", destination: story.storyURL)
                    .subtitle(story.site ?? "")
                    .alternate { Link("Comments: \(story.title ?? "Untitled")", destination: story.discussionURL) }
            }
            Divider()
            Link("Open Hacker News", destination: "https://news.ycombinator.com")
        }
        .help("Hacker News")
        .loading(isLoading)
        .task {
            stories = (try? await Feed.frontPage.stories()) ?? []
            isLoading = false
        }
    }
}
