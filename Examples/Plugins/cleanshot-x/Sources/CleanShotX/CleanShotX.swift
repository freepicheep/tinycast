import TinycastKit

@main
struct CleanShotX: Plugin {
    let manifest = Manifest(
        name: "cleanshot-x",
        title: "CleanShot X",
        description: "Capture, record, annotate and pin with CleanShot X.",
        icon: "camera.viewfinder",
        author: "Tinycast",
        urlSchemes: ["cleanshot"])

    var commands: [Command] {
        Command.view(
            "cleanshot", title: "CleanShot X", subtitle: "Every capture and tool", icon: "camera.viewfinder",
            keywords: ["screenshot", "capture", "record"]
        ) {
            CleanShot()
        }
        // Each tool is also a launcher command of its own, as in Raycast.
        for tool in captures + recording + editing + desktop {
            Command.action(tool.command, title: tool.title, icon: tool.systemImage, keywords: tool.keywords) {
                open(tool.url())
            }
        }
        Command.action(
            "open-settings", title: "Open CleanShot Settings", icon: "gearshape", keywords: ["preferences"]
        ) {
            open("cleanshot://open-settings")
        }
    }
}
