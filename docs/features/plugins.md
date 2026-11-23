# Plugins

Plugins are commands written in Swift. Tinycast runs them with [Scrift](https://github.com/freepicheep/Scrift),
an embedded interpreter for a type-checked subset of Swift. Nothing needs installing or building: a plugin
is a folder of `.swift` files that Tinycast compiles when a command launches. Its views are shaped like
SwiftUI's. A plugin command runs in the Extensions host, beside Raycast extensions: the same screens,
menu bar items, background refresh, preferences, arguments, hotkeys, aliases and toasts.

- [Invariants](#invariants) · [Writing a plugin](#writing-a-plugin) · [The kit](#the-kit) ·
  [Permissions](#permissions) · [How it runs](#how-it-runs) · [Listing plugins elsewhere](#listing-plugins-elsewhere) ·
  [Testing](#testing)

## Invariants

- **Off means off.** `pluginsEnabled` is opt-in. `PluginManager.setEnabled(false)` stops watching the
  folder, empties the installed set and takes every plugin out of the Extensions host
  (`ExtensionManager.setPlugins([])`), which ends its running commands. Enabling is also consent to run
  someone else's code, so it confirms first and never rides a settings backup.
- **A plugin is an engine of the Extensions host, not a second palette.** `PluginManager` hands the
  host one `InstalledExtension` per plugin, with `engine: .plugin` and the manifest translated by
  `PluginManifest.extensionManifest()`, plus a factory that makes a `ScriftPluginRuntime` per launch.
  The host drives it through `ExtensionCommandRuntime`, as it drives the JavaScript runtime, so every
  lane (palette, background, menu bar) and every host API works for plugins without plugin code.
- **Plugins keep their own names.** A plugin's host name is `plugin.<name>`; a Raycast extension's
  name can't contain a dot, so the two never share storage, preferences or entry ids. A plugin's
  folder is never deleted by Tinycast: the launcher and Settings offer no uninstall for it.
- **The manifest runs before the plugin's code, and on its own.** `Manifest.swift` is what the launcher
  lists and what decides the plugin's permissions, so it can't be part of the code those permissions
  shape. `PluginManifestReader` runs it in a context of its own, with Foundation's slice and
  `PluginDescription` and nothing else, under the same limits as a command.
- **`main.swift` registers exactly what the manifest declares.** `ScriftPluginRuntime.compile` checks
  every declared command has code of its kind (`Plugin.command`, `Plugin.action`, `Plugin.menuBar`)
  and that nothing else is registered, and fails the launch with every mismatch listed.
- **A launch is the plugin's whole world.** Each launch gets its own `ScriftContext`: the kit, the
  plugin's module and the host APIs its manifest grants. Plugins share no globals and no state with
  each other or with an earlier launch; what outlives a launch is the host's `ExtensionStorage` under
  the plugin's host name.
- **Every entry into script code runs under `ScriftPluginRuntime.limits`** (`ScriftLimits.untrusted`: 1 s,
  100M instructions, 64 MB, depth 1000), and every call into it is the runtime's: a render, a handler,
  a toast's action, a task's step. A runaway loop fails the command, not the app.
- **A permission is an API, not a check.** Without `network`, `import Foundation` has no `URLSession`;
  without `clipboard`, there is no `import AppKit`; without `selection`, there is no
  `import Selection`. A plugin that uses an API it didn't ask for fails to compile, with an ordinary
  "cannot find" error.
- **`open` reaches web addresses, `mailto:`, file paths and the app link schemes `.openURLs` names.**
  `PluginOpenTarget` decides in `PluginEnvironment`, before anything reaches the host. No manifest may
  name `file` or Tinycast's or Raycast's own schemes.
- **`Model/PluginNode.swift` is the boundary.** The kit renders a screen into `PluginNode` trees whose
  types and props are Raycast's components (`List.Item`, `Form.TextField`, `MenuBarExtra.Item`, …),
  with script closures as handler props. `PluginRenderer` turns them into the host's `RenderTree`,
  giving nodes ids that are stable from one render to the next and handlers ids the host sends back.
- **`Resources/PluginKit` and `Resources/PluginDescription` are Scrift source, never compiled into the
  app.** They ship as folder resources (`project.yml`), and the Swift compiler never sees them.

## Writing a plugin

A plugin lives in `~/Library/Application Support/Tinycast/Plugins/<name>/` (Settings → Plugins →
Open Plugins Folder). It holds a `Manifest.swift` and a `main.swift`, plus any other `.swift` files.

`Manifest.swift` declares the plugin, the way `Package.swift` declares a package:

```swift
import PluginDescription

let plugin = Plugin(
    name: "world-clock",
    title: "World Clock",
    description: "The time in the cities you care about.",
    icon: "globe",
    permissions: [.network],
    preferences: [
        .textField("home", title: "Home City", default: "London"),
    ],
    commands: [
        .view("clocks", title: "World Clock", subtitle: "Time zones", keywords: ["time"]),
        .view("convert", title: "Convert Time", arguments: [.text("time", placeholder: "3pm")]),
        .action("copy-utc", title: "Copy UTC Time"),
        .menuBar("menu", title: "World Clock in the Menu Bar", interval: "1m"),
    ]
)
```

`name` is lowercase letters, digits and hyphens. A `.view` command opens a screen; an `.action`
command does its work and closes the palette, and with an `interval` also runs in the background; a
`.menuBar` command is a menu bar item, refreshed every `interval`. A command without a `subtitle` or
`icon` shows the plugin's title or icon. Commands take `arguments` (fields the launcher shows after
the title) and `preferences`; the plugin's `preferences` apply to all of them. Preferences are
`textField`, `password`, `checkbox`, `dropdown`, `application`, `file` and `directory`, edited in
Settings, and a required one without a value is asked for before the command runs. `permissions` are
`.network`, `.clipboard`, `.selection` and `.openURLs(schemes:)`. A typo in any of these is a compile
error in `Manifest.swift`, with its line. The manifest runs alone: it can't
import `Tinycast` or the plugin's other files, and it has no network whatever it declares.

`main.swift` gives each command its code, by name:

```swift
import Tinycast

Plugin.command("clocks") { Clocks() }
Plugin.command("convert") { Convert(time: Plugin.arguments["time"] ?? "") }
Plugin.action("copy-utc") { Clipboard.copy(utcNow()) }
Plugin.menuBar("menu") { ClockMenu() }
```

A view is written the way SwiftUI's are:

```swift
struct Clocks: View {
    @Preference("home") private var home: String
    @AppStorage("pinned") private var pinned = ""

    var body: some View {
        List {
            Section("Cities") {
                ForEach(cities) { city in
                    Item(city.name, subtitle: city.time, systemImage: "clock")
                        .actions {
                            CopyButton(text: city.time)
                            Button("Pin") { pinned = city.name }
                                .keyboardShortcut("p", modifiers: [.command, .shift])
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
  Algolia API, chosen in the search bar's dropdown, plus search as you type, and the top story in the
  menu bar. Shows `network`, `@AppStorage`, `searchBarAccessory`, `.task(id:)` and cancellation, and a
  `MenuBarExtra` with ⌥ alternates.
- **`cleanshot-x`** (port of Raycast's CleanShot X): every CleanShot X tool as a launcher command, plus
  a list of them whose ⌘K menu says what to do with the capture. Shows `.openURLs` and action
  commands registered in a loop.

## The kit

The `Tinycast` module every plugin imports (`Resources/PluginKit`). Each view renders the Raycast
component of the same role, so a plugin looks and behaves like an extension:

| Kind | API |
|---|---|
| Screens | `List`, `Grid(columns:aspectRatio:fit:inset:)`, `Detail(markdown:)`, `Form`, `MenuBarExtra` |
| Rows | `Section`, `Item`, `ForEach`, `Group`, `EmptyView`, `ContentUnavailableView` |
| List and grid modifiers | `navigationTitle`, `searchable(text:prompt:)`, `searchable(prompt:)`, `loading`, `showingDetail`, `selection`, `searchBarAccessory(Dropdown)`, `actions { }`, `task`, `task(id:)` |
| Item modifiers | `id`, `badge`, `accessory(_:image:tooltip:)`, `accessory(date:)`, `tag`, `keywords`, `tint`, `content`, `actions { }`, `detail { Detail }` |
| Detail | `metadata { LabeledContent, MetadataLink, TagList { Tag }, Divider }`, `actions { }`, `loading`, `task` |
| Form fields | `TextField`, `SecureField`, `TextEditor`, `Toggle`, `Picker { Choice }`, `TagPicker`, `DatePicker`, `FilePicker`, `Text`, `Divider`; each takes `id`, `info`, `error`, `autoFocus`, `storeValue` |
| Menu bar | `MenuItem` (`keyboardShortcut`, `alternate`), `Menu`, `Section`, `Divider` |
| Actions | `Button`, `Link`, `NavigationLink`, `CopyButton`, `PasteButton`, `ShowInFinderButton`, `OpenWithButton`, `TrashButton`, `SubmitButton`, `ActionSection`, `ActionMenu`, `.keyboardShortcut(_:modifiers:)` |
| State | `@State`, `@Binding`, `@AppStorage` and `LocalStorage` (String, Int, Double, Bool), `Cache`, `@Preference` |
| Launch | `Plugin.commandName`, `arguments`, `launchType`, `launchContext`, `fallbackText`, `isDarkAppearance` |
| Host | `showToast` (a `Toast` to change or hide), `showHUD`, `confirmAlert`, `Clipboard`, `open`, `showInFinder`, `closeMainWindow`, `popToRoot`, `clearSearchBar`, `openPreferences`, `launchCommand`, `updateCommandMetadata`, `getApplications`, `getDefaultApplication`, `getFrontmostApplication`, `dismiss` |

↵ runs a row's first action, ⌘↵ its second, and ⌘K lists all of them. Escape pops a `NavigationLink`
before it leaves the command. A `task` starts the first time its screen renders and is cancelled when
the screen leaves the stack. Changing `@State` or `@AppStorage` renders again, once per script call.
A `Button`'s action is synchronous, as in SwiftUI; start awaited work with `Task { … }`. A form
field marked `storeValue` is saved when a `SubmitButton` runs and starts from that value next time.

## Permissions

| Permission | Grants |
|---|---|
| `network` | `URLSession.shared.data(from:)` / `data(for:)`, `URLRequest`, `HTTPURLResponse`: http and https only, 16 MB per response, through a private ephemeral session with no cookies, cache or credentials |
| `clipboard` | `import AppKit` with `NSPasteboard.general.string(forType: .string)` |
| `selection` | `import Selection`: `selectedText()` and `selectedFinderItems()` |
| `openURLs(schemes:)` | `open` and `Link` reach those app link schemes, such as `cleanshot`; never `file`, `tinycast`, `tinycast-dev`, `raycast` or `com.raycast` |

Writing to the clipboard (`CopyButton`, `Clipboard.copy`) and pasting need no permission.

## How it runs

`PluginManager` (owned by `AppCore`) scans the folder when plugins are on and watches it for added
and removed plugins. Each scan hands the Extensions host the plugins as `InstalledExtension`s with
`engine: .plugin`, so the launcher lists their commands with the host's icon, hotkey, alias and
argument handling, and the menu bar and background lanes schedule them. Code is read fresh on every
launch, so editing a `.swift` file needs no reload; a changed `Manifest.swift` needs Settings →
Plugins → Reload.

`PluginCatalog.scan` runs each `Manifest.swift` through `PluginManifestReader`: the description loads
as `PluginDescription`, the manifest as its own module, and its top-level code runs. `Plugin.init`
records itself, and the reader reads the one plugin back as JSON, which `PluginManifest.decode`
checks (names, duplicates, schemes, preferences, intervals). The result is kept in
`PluginManifests/<sha256>.json`, keyed by the manifest's and the description's text, so a manifest
runs once per edit, not once per scan. A run costs about 300 ms the first time in a process (Scrift
compiling Foundation's slice and the description) and about 10 ms after. A scan removes entries no
plugin used. Failures aren't kept.

Launching a command makes a `ScriftPluginRuntime`, which the host drives like the JavaScript runtime:

1. `PluginCapabilities.modules(for:)` gives the context its host modules: `_TinycastHost` (the node
   types, `PluginEnvironment`, `PluginLaunch`), Foundation with or without the network, and AppKit and
   `Selection` when granted.
2. The kit loads as `Tinycast`, then the plugin's files as their own module, and `main.swift` runs;
   `_tinycastRegistrations` is checked against the manifest.
3. `_tinycastBegin` hands the kit the session's `PluginEnvironment` and the launch (arguments,
   preferences, launch type and context). A view or menu bar command opens with `_tinycastOpen` and
   renders with `_tinycastRender`; an action runs `_tinycastRun` to its end, its tasks included.
4. `PluginRenderer` turns each `PluginNode` tree into a `RenderTree` the host draws as it draws an
   extension's. `PluginEnvironment.invalidate()` (state changed) coalesces into one render after the
   script call. The host sends handler ids back through `dispatch`, Escape through `popNavigation`,
   and a toast's button through `runToastAction`.
5. Everything else a plugin asks of the app goes through `PluginEnvironment` to the host's
   `ExtensionHostAPI`: the same toasts, HUDs, clipboard, windows, launches and storage a Raycast
   command reaches.

A plugin command's deep link is `tinycast://plugins/<name>/<command>` (`tinycast-dev://` in Debug),
with Raycast's `arguments`, `launchType` and `context` query items; Copy Deeplink gives that form.
`ExtensionDeepLink` reads it as the host name `plugin.<name>`, which also works in an `extensions/`
link. Raycast's schemes never reach a plugin. Hotkeys and deep links run a plugin's command whether
or not Raycast extensions are switched on.

`OAuth.PKCEClient` signs in with OAuth 2.0 and PKCE as Raycast's does. `authorizationRequest`
builds the URL natively (a `SecRandomCopyBytes` verifier, its S256 challenge, a state nonce), with
Tinycast's own redirect `tinycast://oauth?plugin=<name>` unless the plugin names a custom one.
`authorize` runs the host's browser sign-in, checks the returned state and gives back the code; the
provider's `error_description` becomes the thrown error. Tokens are kept per provider in the
plugin's storage (`setTokens`, `getTokens` with `isExpired`, `removeTokens`). The token exchange is
the plugin's own `URLSession` request, under the `network` permission. Sign-in is refused in a
background run.

Settings › Plugins opens each plugin to the same card as an extension's: show in launcher, launcher
icon, preferences, and per command its alias, hotkey, visibility, menu bar toggle and background
refresh. "Configure Plugin" in the launcher opens that card; "Show in Finder" replaces uninstall.

The kit's compiled module is cached per process. The first launch costs about 0.5 s (release), and
later launches under 10 ms. `PluginManager` warms that cache a moment after plugins are switched on.

Errors (compile diagnostics with file and line, a panic, a limit) replace the screen with the message
and the plugin's recent `print` output.

## Listing plugins elsewhere

A plugin index or website shouldn't need Scrift to show plugins and their commands. `tinycast-plugin
dump` prints a plugin's manifest as JSON, after checking the plugin as Tinycast would: the manifest
runs, and `main.swift` compiles with the permissions it declares and registers just the commands it
declares. It exits 1 with the problems otherwise.

```sh
./Scripts/plugin-dump.sh Examples/Plugins/hacker-news
```

```json
{
  "commands" : [
    { "keywords" : ["hn", "news"], "mode" : "view", "name" : "stories", "subtitle" : "Top stories", "title" : "Hacker News" }
  ],
  "icon" : "newspaper.fill",
  "name" : "hacker-news",
  "permissions" : ["network"],
  "title" : "Hacker News"
}
```

`tinycast-plugin run <folder> <command> [seconds]` launches one command against a host that prints
every call it receives, and prints the command's last screen as an outline of its nodes: a quick way
to see what a plugin renders without the app.

Keys are sorted, and empty lists and missing values are left out, so a manifest always prints the same
bytes. `urlSchemes` lists `.openURLs`' schemes. It's the same JSON as the app's cache: one shape,
written by `PluginManifest.json()` and read by `PluginManifest.decode`. The tool is a second product of
`Tests/PluginHost` and checks against this checkout's kit and description.

## Testing

`./Scripts/test-plugins.sh` builds `Tests/PluginHost`, a SwiftPM package that links the real Scrift and
drives `ScriftPluginRuntime` the way the Extensions host does (launch, render, dispatch, pop, stop),
against a host that records every call. Its checks cover manifests and their errors, the catalog's
cache, the translation into the host's manifest, registration checks, rendering into Raycast's
component shapes, bindings, navigation, storage, forms with stored values, grids and their dropdown,
menu bar commands, preferences, toasts and their actions, `launchCommand`, action commands, compile
errors, runaway loops, permission gating and `open` rules, using `Tests/PluginHost/Fixtures` and
`Examples/Plugins`. It then runs `tinycast-plugin dump` on every example. The Hacker News checks call
the live API, and are skipped when it's unreachable. Its sources are symlinks to `Features/Plugins`
and the Extensions model files the runtime uses. The first run builds Scrift and swift-syntax and takes
a few minutes.
