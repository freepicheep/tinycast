import Tinycast

Plugin.command("cleanshot") { CleanShot() }

// Each tool is also a launcher command of its own.
for tool in captures + recording + editing + desktop {
    let url = tool.url()
    Plugin.action(tool.command) { open(url) }
}
Plugin.action("open-settings") { open("cleanshot://open-settings") }
