import PluginDescription

let plugin = Plugin(
    name: "kitchen",
    title: "Kitchen",
    preferences: [
        .textField("greeting", title: "Greeting", default: "Hello"),
        .checkbox("loud", title: "Volume", label: "Shout", default: false),
    ],
    commands: [
        .view("note", title: "New Note", arguments: [.text("subject", placeholder: "Subject")]),
        .view("colors", title: "Colors"),
        .menuBar("status", title: "Status", interval: "1m"),
        .action("toast", title: "Toast"),
        .action("hop", title: "Hop"),
    ]
)
