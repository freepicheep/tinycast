# Plugins

Plugins are commands written in Swift. Tinycast runs them with [Stir](https://github.com/freepicheep/Stir),
an embedded interpreter for a type-checked subset of Swift. Nothing needs installing or building: a plugin
is a folder of `.swift` files that Tinycast compiles when a command launches. Its views are shaped like
SwiftUI's, and Tinycast draws them with its own palette rows and panes.

- [Invariants](#invariants) · [Writing a plugin](#writing-a-plugin) · [The kit](#the-kit) ·
  [Permissions](#permissions) · [How it runs](#how-it-runs) · [Testing](#testing)

## Invariants

- **Off means off.** `pluginsEnabled` is opt-in. `PluginManager.setEnabled(false)` ends the running
  command, stops watching the folder, empties the installed set and clears the launcher rows. Enabling
  is also consent to run someone else's code, so it confirms first and never rides a settings backup.
- **A session is the plugin's whole world.** Each launch gets its own `StirContext`: the kit, the
  plugin's module and the host APIs its manifest grants. Plugins share no globals, no storage and no
  state with each other or with an earlier launch, except the `PluginData/<name>.json` storage it owns.
- **Every entry into script code runs under `PluginSession.limits`** (`StirLimits.untrusted`: 1 s,
  100M instructions, 64 MB, depth 1000). Closures a script hands back, such as an action's body or a
  search binding, run under the limits the VM last set, so every call into a session goes through
  `PluginSession`. A runaway action fails the session, not the app.
- **A permission is an API, not a check.** Without `network`, `import Foundation` has no `URLSession`;
  without `clipboard`, there is no `import AppKit`. A plugin that uses an API it didn't ask for fails
  to compile, with an ordinary "cannot find" error.
- **Copy, paste and open never reach the script.** They are values (`PluginActionKind.copy(String)`),
  so Tinycast performs them itself after the script has returned.
- **`open` reaches web addresses, `mailto:`, file paths and the app link schemes `urlSchemes` names.**
  `PluginOpenTarget` decides, for a `Link` and for the script's own `open` call alike, before anything
  reaches `NSWorkspace`. No manifest may name `file` or Tinycast's or Raycast's own schemes.
- **`Model/PluginPage.swift` is the boundary.** The kit renders a screen into those `@StirExport`
  types and the palette draws only them; neither side sees the other's view types.
- **`Resources/PluginKit` is Stir source, never compiled into the app.** It ships as a folder
  resource (`project.yml`), and the Swift compiler never sees it.

## Writing a plugin

A plugin lives in `~/Library/Application Support/Tinycast/Plugins/<name>/` (Settings → Plugins →
Open Plugins Folder). It holds a `plugin.json` and a `main.swift`, plus any other `.swift` files.

```json
{
  "name": "world-clock",
  "title": "World Clock",
  "description": "The time in the cities you care about.",
  "icon": "globe",
  "permissions": [],
  "urlSchemes": [],
  "commands": [
    { "name": "clocks", "title": "World Clock", "subtitle": "Time zones", "keywords": ["time"] },
    { "name": "copy-utc", "title": "Copy UTC Time", "mode": "action" }
  ]
}
```

`name` is lowercase letters, digits and hyphens. A `view` command (the default) opens a screen; an
`action` command does its work and closes the palette. `main.swift` registers each command by name:

```swift
import Tinycast

Plugin.command("clocks") { Clocks() }
Plugin.action("copy-utc") { copyToClipboard(utcNow()) }
```

A view is written the way SwiftUI's are:

```swift
struct Clocks: View {
    @State private var query = ""
    @AppStorage("home") private var home = "London"

    var body: some View {
        List {
            Section("Cities") {
                ForEach(cities) { city in
                    Item(city.name, subtitle: city.time, systemImage: "clock")
                        .actions {
                            CopyButton(text: city.time)
                            Button("Make Home") { home = city.name }
                                .keyboardShortcut("h", modifiers: [.command, .shift])
                            NavigationLink("Details") { CityDetail(city: city) }
                        }
                }
            }
        }
        .navigationTitle("World Clock")
        .task { await load() }
    }
}
```

Without `.searchable`, Tinycast filters the rows by title, subtitle and `.keywords`. With
`.searchable(text: $query)`, the plugin gets each keystroke and filters its rows itself, usually
with `.task(id: query)`, which cancels and restarts its work as the query changes.

Two complete plugins are in [`Examples/Plugins`](../../Examples/Plugins). Copy either folder into the
Plugins folder to install it:

- **`hacker-news`** (port of Raycast's Hacker News): front page, newest, Ask HN and Show HN from HN's
  Algolia API, plus search as you type. Shows `network`, `@AppStorage`, `.task(id:)` and cancellation.
- **`cleanshot-x`** (port of Raycast's CleanShot X): every CleanShot X tool as a launcher command, plus
  a list of them whose ⌘K menu says what to do with the capture. Shows `urlSchemes` and action
  commands registered in a loop.

## The kit

The `Tinycast` module every plugin imports (`Resources/PluginKit`):

| Kind | API |
|---|---|
| Screens | `List`, `Detail(markdown:)`, `Section`, `Item`, `ForEach`, `Group`, `EmptyView`, `ContentUnavailableView` |
| List modifiers | `navigationTitle`, `searchable(text:prompt:)`, `loading`, `task`, `task(id:)` |
| Item modifiers | `id`, `badge`, `keywords`, `tint`, `actions { }`, `detail { }` |
| Detail modifiers | `navigationTitle`, `metadata { LabeledContent }`, `actions { }`, `loading`, `task`, `task(id:)` |
| Actions | `Button(_:systemImage:role:action:)`, `CopyButton`, `PasteButton`, `Link`, `NavigationLink`, `.keyboardShortcut` |
| State | `@State`, `@Binding`, `@AppStorage` (String, Int, Double, Bool) |
| Host | `showHUD`, `closeWindow`, `open`, `copyToClipboard`, `paste`, `dismiss`, `Plugin.commandName` |

↵ runs a row's first action, ⌘↵ its second, and ⌘K lists all of them. Escape pops a `NavigationLink`
before it leaves the command. A `task` starts the first time its screen renders and is cancelled when
the screen leaves the stack. Changing `@State` or `@AppStorage` re-renders.

## Permissions

| Permission | Grants |
|---|---|
| `network` | `URLSession.shared.data(from:)` / `data(for:)`, `URLRequest`, `HTTPURLResponse`: http and https only, 16 MB per response, through a private ephemeral session with no cookies, cache or credentials |
| `clipboard` | `import AppKit` with `NSPasteboard.general.string(forType: .string)` |

Writing to the clipboard (`CopyButton`, `copyToClipboard`) needs no permission.

## How it runs

`PluginManager` (owned by `AppCore`) scans the folder when plugins are on, watches it for added and
removed plugins, and publishes one `AppEntry` of kind `.pluginCommand` per command. Code is read fresh
on every launch, so editing a `.swift` file needs no reload; a changed `plugin.json` needs Settings →
Plugins → Reload.

Launching a command builds a `PluginSession`:

1. The host module `_TinycastHost` exports `PluginEnvironment` and the page types; Foundation (and
   AppKit) come from `PluginCapabilities`.
2. The kit loads as `Tinycast`, then the plugin's files load as its own module and `main.swift` runs.
3. `_tinycastOpen` / `_tinycastRun` start the command, and `_tinycastRender` returns a `PluginPage`.
   `PluginEnvironment.invalidate()` (state changed) schedules one coalesced render per turn.
4. `PluginCommandScreen` draws the page as a palette screen; actions come back through
   `PluginManager.perform`, and Escape through `PluginCoordinator.exitPluginScreen`.

The kit's compiled module is cached per process. The first launch costs about 200 ms (release), and
later launches about 10 ms. `PluginManager` warms that cache a moment after plugins are switched on.

Errors (compile diagnostics with file and line, a panic, a limit) replace the screen with the message
and the plugin's recent `print` output.

## Testing

`./Scripts/test-plugins.sh` builds `Tests/PluginHost`, a SwiftPM package that links the real Stir and
drives sessions from `Tests/PluginHost/Fixtures` and `Examples/Plugins` the way the palette does:
rendering, bindings, navigation, storage, action commands, compile errors, runaway loops, permission
gating and `open` rules. The Hacker News checks call the live API, and are skipped when it's unreachable. Its sources
are symlinks to `Features/Plugins`. The first run builds Stir and swift-syntax and takes a few minutes.
