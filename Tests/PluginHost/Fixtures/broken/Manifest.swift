import PluginDescription

let plugin = Plugin(
    name: "broken",
    title: "Broken",
    commands: [
        .view("one", title: "One"),
        .view("two", title: "Two"),
    ]
)
