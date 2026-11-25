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
        .menuBar("status", title: "Status", interval: .minutes(1)),
        .action("toast", title: "Toast"),
        .action("hop", title: "Hop"),
        .action("sign-in", title: "Sign In"),
    ]
)
