import Foundation
import Tinycast

/// The front page's top story in the menu bar, refreshed by the manifest's interval.
struct TopStory: View {
    @State private var stories: [Story] = []
    @State private var isLoading = true

    var body: some View {
        MenuBarExtra(stories.first.map { "▲ \($0.points ?? 0)" }, systemImage: "newspaper", tooltip: "Hacker News") {
            ForEach(stories.prefix(5)) { story in
                MenuItem(story.title ?? "Untitled", subtitle: story.site) {
                    open(story.storyURL)
                }
                .alternate(MenuItem("Comments: \(story.title ?? "Untitled")") { open(story.discussionURL) })
            }
            Divider()
            MenuItem("Open Hacker News", systemImage: "safari") { open("https://news.ycombinator.com") }
        }
        .loading(isLoading)
        .task {
            stories = (try? await Feed.frontPage.stories()) ?? []
            isLoading = false
        }
    }
}
