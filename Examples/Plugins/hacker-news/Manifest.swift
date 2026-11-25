import PluginDescription

let plugin = Plugin(
    name: "hacker-news",
    title: "Hacker News",
    description: "Front page, newest, Ask HN and Show HN stories, and search across Hacker News.",
    icon: "newspaper.fill",
    author: "Tinycast",
    permissions: [.network],
    commands: [
        .view(
            "stories", title: "Hacker News", subtitle: "Top stories",
            keywords: ["hn", "news", "ycombinator", "y combinator"]),
        .menuBar("top-story", title: "Top Story", subtitle: "In the menu bar", interval: .minutes(10)),
    ]
)
