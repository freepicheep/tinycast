import TinycastKit

@main
struct HackerNews: Plugin {
    let manifest = Manifest(
        name: "hacker-news",
        title: "Hacker News",
        description: "Front page, newest, Ask HN and Show HN stories, and search across Hacker News.",
        icon: "newspaper.fill",
        author: "Tinycast",
        permissions: [.network])

    var commands: [Command] {
        Command.view(
            "stories", title: "Hacker News", subtitle: "Top stories",
            keywords: ["hn", "news", "ycombinator", "y combinator"]
        ) {
            Stories()
        }
        Command.menuBar("top-story", title: "Top Story", subtitle: "In the menu bar", interval: "10m") {
            TopStory()
        }
    }
}
