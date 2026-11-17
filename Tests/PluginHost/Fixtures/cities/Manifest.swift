import PluginDescription

let plugin = Plugin(
    name: "fixture",
    title: "Fixture",
    commands: [
        .view("cities", title: "Cities"),
        .action("hello", title: "Hello"),
    ]
)
