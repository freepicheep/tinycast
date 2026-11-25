# Plugins

Plugins are commands written in Swift. Tinycast runs them with [Scrift](https://github.com/freepicheep/Scrift),
an embedded interpreter for a type-checked subset of Swift. Nothing needs installing or building: a plugin
is a folder of `.swift` files that Tinycast compiles when a command launches. Its views are written
like SwiftUI's, and Tinycast draws what they describe with its own: lists, grids, details, forms and
menu bar items, plus background runs, preferences, arguments, hotkeys, aliases and toasts.

- [Invariants](#invariants) · [Writing a plugin](#writing-a-plugin) · [The kit](#the-kit) ·
  [Permissions](#permissions) · [How it runs](#how-it-runs) · [The view contract](#the-view-contract) ·
  [The plugin helper](#the-plugin-helper) ·
  [Listing plugins elsewhere](#listing-plugins-elsewhere) ·
  [Testing](#testing)

## Invariants

- **Off means off.** `pluginsEnabled` is opt-in. `PluginManager.setEnabled(false)` stops watching the
  folder, empties the installed set and calls `PluginHost.stopAll()`, which ends every running command,
  menu bar item and background run. Enabling is also consent to run someone else's code, so it confirms
  first and never rides a settings backup.
- **A plugin describes, Tinycast draws.** A script never touches a view. The kit turns a screen into a
  `PluginFrame` (`Model/PluginUI.swift`), plain values in a versioned contract, and the views in
  `Features/Plugins/UI` draw it. They share no code with any other renderer, and the contract carries
  no other product's names. See [The view contract](#the-view-contract).
- **`PluginHost` is the one owner of running plugins.** It holds the palette's session, each action
  run, each menu bar item and the background schedule, makes a runtime per launch through
  `PluginManager.makeRuntime` (`RemotePluginRuntime` in the helper, or `ScriftPluginRuntime` in the
  app) and answers each one's host calls through a `PluginHostBridge` that knows the lane it serves.
- **Plugins are named by their manifests.** A command's entry ID is `plugin:<name>/<command>`
  (`PluginCommandRef`), which hotkeys, aliases, favorites, visibility and ranking key by. A plugin's
  folder is never deleted by Tinycast: the launcher and Settings offer no uninstall for it. A command
  loses its references only when its folder goes or its manifest drops it; a manifest that stops
  compiling costs nothing.
- **Plugin code runs in the plugin helper, not the app.** `Contents/Helpers/PluginHelper` is a process
  of its own, so a plugin that crashes, leaks or hangs takes only that process, and its memory goes
  back when the helper exits. Manifests run there too. The app stays the only writer of plugin storage
  and the only caller of host APIs: the helper asks, the app answers. See
  [The plugin helper](#the-plugin-helper).
- **The manifest runs before the plugin's code, and on its own.** `Manifest.swift` is what the launcher
  lists and what decides the plugin's permissions, so it can't be part of the code those permissions
  shape. `PluginManifestReader` runs it in a context of its own, with Foundation's slice and
  `PluginDescription` and nothing else, under the same limits as a command.
- **`main.swift` registers exactly what the manifest declares.** `ScriftPluginRuntime.compile` checks
  every declared command has code of its kind (`Plugin.command`, `Plugin.action`, `Plugin.menuBar`)
  and that nothing else is registered, and fails the launch with every mismatch listed.
- **A launch is the plugin's whole world.** Each launch gets its own `ScriftContext`: the kit, the
  plugin's module and the host APIs its manifest grants. Plugins share no globals and no state with
  each other or with an earlier launch; what outlives a launch is the plugin's `PluginStore` data,
  under its name.
- **Every entry into script code runs under `ScriftPluginRuntime.limits`** (`ScriftLimits.untrusted`: 1 s,
  100M instructions, 64 MB, depth 1000), and every call into it is the runtime's: a render, a handler,
  a toast's action, a task's step. A runaway loop fails the command, not the app.
- **A permission is an API, not a check.** Without `network`, `import Foundation` has no `URLSession`;
  without `clipboard`, there is no `import AppKit`; without `selection`, there is no
  `import Selection`. A plugin that uses an API it didn't ask for fails to compile, with an ordinary
  "cannot find" error.
- **`open` reaches web addresses, `mailto:`, file paths and the app link schemes `.openURLs` names.**
  `PluginOpenTarget` decides in `PluginEnvironment`, and the host decides again before it opens
  anything. No manifest may name `file` or Tinycast's own schemes.
- **Host calls are typed.** Everything a plugin asks of the app is a `PluginHostCall` and its
  `PluginHostAnswer` (`Model/PluginHostCall.swift`), Codable both ways, so the pipe to the helper and
  the in-process runtime carry the same values.
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
        .menuBar("menu", title: "World Clock in the Menu Bar", interval: .minutes(1)),
    ]
)
```

`name` is lowercase letters, digits and hyphens. A `.view` command opens a screen; an `.action`
command does its work and closes the palette, and with an `interval` also runs in the background; a
`.menuBar` command is a menu bar item, refreshed every `interval`. A command without a `subtitle` or
`icon` shows the plugin's title or icon. Commands take `arguments` (fields the launcher shows after
the title) and `preferences`; the plugin's `preferences` apply to all of them. Preferences are
`textField`, `password`, `checkbox`, `dropdown`, `application`, `file` and `directory`, edited in
Settings; a command whose required preference has no value asks to open Settings at its plugin
instead of running. `permissions` are
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
    @State private var cities: [City] = []

    var body: some View {
        List {
            Section("Cities") {
                ForEach(cities) { city in
                    Label(city.name, systemImage: "clock")
                        .badge(city.time)
                        .contextMenu {
                            ShareLink("Copy Time", item: city.time)
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

A row is any view in a `List` or `Grid`: `Text`, `Label`, or a view of the plugin's own. Its
`.contextMenu` holds its actions. Without `.searchable(text:)`, Tinycast filters the rows by title,
subtitle and `.searchKeywords`. With `.searchable(text: $query)`, the plugin gets each keystroke and
filters its rows itself, usually with `.task(id: query)`, which cancels and restarts its work as the
query changes.

Three complete plugins are in [`Examples/Plugins`](../../Examples/Plugins). Copy a folder into the
Plugins folder to install it:

- **`hacker-news`**: front page, newest, Ask HN and Show HN from HN's Algolia API, chosen in a
  toolbar `Picker`, plus search as you type, and the top story in the menu bar. Shows `network`,
  `@AppStorage`, `.toolbar`, `.task(id:)` and cancellation, and a `MenuBarExtra` with ⌥ alternates.
- **`cleanshot-x`**: every CleanShot X tool as a launcher command, plus
  a list of them whose ⌘K menu says what to do with the capture. Shows `.openURLs` and action
  commands registered in a loop.
- **`google-translate`**: translate there and back or into a
  saved set of languages as you type, a form, Quick Translate into every target at once, and instant
  copy, paste and HUD actions on the selection. Shows `.selection`, `launchCommand` with a context,
  debounced `.task(id:)`, a `Form` whose bindings start tasks, and `@AppStorage` sets. Text to speech
  is left out: it needs a child process.

## The kit

The `Tinycast` module every plugin imports (`Resources/PluginKit`). Its names are SwiftUI's wherever
SwiftUI has the idea:

| Kind | API |
|---|---|
| Screens | `List`, `Grid(columns:aspectRatio:fit:inset:)`, `Detail(markdown:)`, `Form`, `MenuBarExtra` |
| Rows | `Text`, `Label`, `Section`, `ForEach`, `Group`, `EmptyView`, `ContentUnavailableView` (and `.search(text:)`) |
| Screen modifiers | `navigationTitle`, `searchable(text:prompt:)`, `searchable(prompt:)`, `toolbar { Button, Picker }`, `loading`, `showsDetail`, `List(selection:)`, `task`, `task(id:)`, `refreshable` |
| Row modifiers | `id`, `subtitle`, `badge` (text, count, `Tag`, `Image`, `Label`), `searchKeywords`, `foregroundStyle`, `tag`, `help`, `redacted(reason:)`, `contextMenu { }`, `detail { Detail }` |
| Detail | `metadata { LabeledContent, Link, TagList { Tag }, Divider }`, `toolbar`, `loading`, `task` |
| Form fields | `TextField`, `SecureField`, `TextEditor`, `Toggle`, `Picker`, `MultiPicker`, `DatePicker`, `FilePicker`, `Text`, `Divider`; `fieldError`, `defaultFocus`, `help` |
| Menu bar | `Button` (`keyboardShortcut`, `alternate`), `Menu`, `Section`, `Divider` |
| Actions | `Button` (with a `role`), `Link`, `NavigationLink`, `ShareLink`, `PasteButton`, `ShowInFinderButton`, `OpenWithButton`, `TrashButton`, `Menu`, `Section`, `.keyboardShortcut(_:modifiers:)` |
| Images | `Image(systemName:)`, `Image(_:)` (a file in the plugin), `url:`, `contentsOfFile:`, `fileIconFor:`, `emoji:`, `color:`, with `foregroundStyle` and `clipShape` |
| State | `@State`, `@Binding`, `@AppStorage` (any `Codable` value, stored as JSON), `@Preference`, `@Environment(\.dismiss)`, `@Environment(\.openURL)`, `@Environment(\.colorScheme)` |
| Launch | `Plugin.commandName`, `Plugin.arguments`, `Plugin.launchType`, `Plugin.launchContext`, `Plugin.fallbackText` |
| Host | `showToast` (a `Toast` to change or hide), `showHUD`, `confirmAlert`, `Clipboard`, `open`, `showInFinder`, `closeMainWindow`, `popToRoot`, `clearSearchBar`, `openPreferences`, `launchCommand`, `updateCommandMetadata`, `getApplications`, `getDefaultApplication`, `getFrontmostApplication` |

↵ runs a row's first action, ⌘↵ its second, and ⌘K lists all of them, then the toolbar's. A form's
↵ runs its toolbar's first button. Escape pops a `NavigationLink` before it leaves the command. A
`task` starts the first time its screen renders and is cancelled when the screen leaves the stack.
Changing `@State` or `@AppStorage` renders again, once per script call. A `Button`'s action is
synchronous, as in SwiftUI; start awaited work with `Task { … }`. A toolbar `Picker` sits beside the
search field and opens with ⌘P.

## Permissions

| Permission | Grants |
|---|---|
| `network` | `URLSession.shared.data(from:)` / `data(for:)`, `URLRequest`, `HTTPURLResponse`: http and https only, 16 MB per response, through a private ephemeral session with no cookies, cache or credentials |
| `clipboard` | `import AppKit` with `NSPasteboard.general.string(forType: .string)` |
| `selection` | `import Selection`: `selectedText()` and `selectedFinderItems()` |
| `openURLs(schemes:)` | `open` and `Link` reach those app link schemes, such as `cleanshot`; never `file`, `tinycast` or `tinycast-dev` |

Writing to the clipboard (`ShareLink`, `Clipboard.copy`) and pasting need no permission.

## How it runs

`PluginManager` (owned by `AppCore`) scans the folder when plugins are on and watches it with FSEvents.
Each scan tells `PluginHost`, which lists every command in the launcher as an `AppEntry` of kind
`.pluginCommand`, puts each menu bar command up as its own status item, and schedules the action
commands that run in the background. Code is read fresh on every launch.

Saving any file under a plugin's folder reloads it: the folder is rescanned (an unchanged manifest
is a cache lookup), and a palette command running from that plugin, failed or not, launches again
from the new code with the arguments and context it had (`PluginHost.relaunch(plugin:)`). Its menu
bar items launch again too.
An author sees an edit about a second after saving it, FSEvents' latency.

`PluginCatalog.scan` runs each `Manifest.swift` through `PluginManifestReader`: the description loads
as `PluginDescription`, the manifest as its own module, and its top-level code runs. `Plugin.init`
records itself, and the reader reads the one plugin back as JSON, which `PluginManifest.decode`
checks (names, duplicates, schemes, preferences, intervals). The result is kept in
`PluginManifests/<sha256>.json`, keyed by the manifest's and the description's text, so a manifest
runs once per edit, not once per scan. A run costs about 300 ms the first time in a process (Scrift
compiling Foundation's slice and the description) and about 10 ms after. A scan removes entries no
plugin used. Failures aren't kept.

Launching a command makes a runtime, which `PluginHost` drives through `PluginRuntime`:

1. `PluginCapabilities.modules(for:)` gives the context its host modules: `_TinycastHost` (the contract
   types, `PluginEnvironment`, `PluginLaunch`), Foundation with or without the network, and AppKit and
   `Selection` when granted.
2. The kit loads as `Tinycast`, then the plugin's files as their own module, and `main.swift` runs;
   `_tinycastRegistrations` is checked against the manifest.
3. `_tinycastBegin` hands the kit the session's `PluginEnvironment` and the launch (arguments,
   preferences, launch type and context). A view or menu bar command opens with `_tinycastOpen` and
   is read with `_tinycastFrame`; an action runs `_tinycastRun` to its end, its tasks included, and
   finishes once the host has answered the calls it fired (a copy or a HUD it ends with).
4. Each frame reaches `PluginRuntimeDelegate.didRender`. `PluginEnvironment.invalidate()` (state
   changed) coalesces into one frame after the script call. The host sends back `PluginEvent`s:
   `perform` (a handler, with the frame's generation; one from an older frame is dropped), `set` (a
   binding's new value), `search` and `back`, and a toast's button through `runToastAction`.
5. Everything else a plugin asks of the app is a `PluginHostCall`, which `PluginHostBridge` answers:
   toasts, HUDs, the clipboard, opening, windows, launches, applications, the selection and sign-in.
   A background or menu bar run is quiet: a toast it shows is dropped, and it can't paste, close
   the palette or ask to confirm. An action's effect (open, copy, paste, reveal, open with, trash) is
   performed by the host (`PluginEffects`) after it checks the plugin's grants, then its handler
   runs.

`PluginHost` keeps one lane per kind of run. The palette's command is one session, replaced by the
next. An action run has a lane of its own and is stopped after 120 s. A menu bar command keeps its
runtime while its item is up, and launches again every `interval` (no more often than every 10 s)
or when its plugin changes. A background action runs when it's due, no more often than every 60 s,
and its last run is stored, so a relaunch of Tinycast doesn't run it early.

A plugin command's deep link is `tinycast://plugins/<name>/<command>` (`tinycast-dev://` in Debug),
with `arguments` (a JSON object), `fallbackText`, `launchType=background` and `context` (a JSON
object) in its query; Copy Deeplink gives that form. `PluginDeepLink` reads it. Hotkeys and deep
links run a plugin's command only while plugins are on.

`OAuth.PKCEClient` signs in with OAuth 2.0 and PKCE. `authorizationRequest`
builds the URL natively (a `SecRandomCopyBytes` verifier, its S256 challenge, a state nonce), with
Tinycast's own redirect `tinycast://oauth?plugin=<name>` unless the plugin names a custom one.
`authorize` runs the host's browser sign-in, checks the returned state and gives back the code; the
provider's `error_description` becomes the thrown error. Tokens are kept per provider in the
plugin's storage (`setTokens`, `getTokens` with `isExpired`, `removeTokens`). The token exchange is
the plugin's own `URLSession` request, under the `network` permission. Sign-in is refused in a
background run.

Settings › Plugins opens each plugin to a card (`PluginSettingsCard`): its preferences, then per
command its alias, hotkey, launcher visibility, and its menu bar or run-in-the-background switch,
and Sign Out once it holds tokens. Settings runs in a process of its own, so the card reads
`MainAppStatus.plugins` and sends each edit as a `SettingsAction`; the main app owns `PluginStore`.
"Configure Plugin" in the launcher opens that card; "Show in Finder" replaces uninstall.

Compiled modules are cached in memory (`moduleCapacity`: 6 in the app, 12 in the helper, besides
those running) and on disk in `Caches/ScriftModules`, which the app and the helper share. The kit
compiles once per app update: about 0.5 s (release). A launch that finds it on disk decodes it, and
one that finds it in memory costs under 10 ms. When plugins are switched on, `PluginManager` asks the
helper, which the startup scan has just started, to warm the kit (`warm`), so the first launch
within the helper's lifetime is an in-memory hit.

Errors (compile diagnostics with file and line, a panic, a limit) replace the screen with the message
and the plugin's recent `print` output.

## The view contract

`Model/PluginUI.swift` is everything a plugin can show, as plain Codable values. A `PluginFrame` holds
the contract's `version`, a `generation` that numbers it, the navigation `depth`, and one
`PluginScreen`: `list`, `grid`, `detail`, `form`, `menuBar`, or `unsupported`. Every screen but the
menu bar has a `PluginChrome`: title, search field, toolbar pickers and actions, and a loading flag.
Rows, fields, actions and menu items carry ids that hold from one frame to the next, so a selection
survives a frame. A handler is an integer the kit hands out per frame; a binding (the search field,
a list's selection, a picker, a field) is named by its node's id, and the host writes it with `set`.

- **The contract is versioned.** `PluginProtocolVersion.current` is 1.0. A frame of a newer major
  version fails the command; a newer minor version's unknown cases decode as `unsupported` and draw
  as a placeholder, so an old Tinycast reads a new kit's frames.
- **A frame is whole.** The kit sends the full screen each time, never a diff. The largest example,
  65 KB for a Hacker News page of stories, encodes in about 2.5 ms. From its arrival in `PluginHost`
  to its first draw, a frame takes a median 7.6 ms (90th percentile 14 ms; 58 frames of the three
  examples in a Debug build); a 30- or 40-row list takes 23-37 ms, the most when it replaces the
  loading screen.
- **The host's views know only the contract.** `PluginCommandView`, `PluginFormView` and
  `PluginMenuBarItem` draw a frame; `PluginScreenLayout` walks it for the palette (the rows in order,
  filtering when the plugin has no search binding, the actions of a row). The golden files in
  `Tests/PluginHost/Fixtures/contract` fix the JSON of every case.

## The plugin helper

`PluginHelper` is a `tool` target embedded in `Contents/Helpers`, like `FileIndexHelper`. Its sources
are the plugin runtime's own (`project.yml` lists them; `Tests/PluginHost/Sources/plugin-helper` links
the same files). `PluginHelperClient` (the app's end, owned by `PluginManager`) starts it with
`ProcessLink.spawn` on the first scan or launch, passing the compile cache's folder. Frames are
`PipeFraming` JSON both ways (`PluginHelperWire.swift`), not XPC, as with the app's other helpers.

- **A launch carries everything.** `PluginHelperLaunch` has the manifest's JSON, the plugin's and the
  kit's folders, the `PluginLaunch` the host made, and a `PluginStorageSnapshot` of the
  plugin's storage. The helper keeps nothing between launches but its compile cache.
- **The helper runs a `ScriftPluginRuntime` per launch,** numbered by the app. Its delegate callbacks
  (frames, failures, finishing, logs) become events, and `RemotePluginRuntime` hands them to
  `PluginHost` as an in-process runtime would. Requests that wait (`event`, `stop`, `drain`,
  `toastAction`, `scan`) carry a reply number.
- **Host calls go back to the app.** The runtime's `PluginHostAPI` in the helper sends a `hostCall`
  and awaits the app's `hostAnswer`; the app runs it with its own `PluginHostBridge`. Clipboard,
  Accessibility, opening URLs, toasts and sign-in therefore keep the app's permissions and checks.
- **Storage is mirrored.** Getters must answer synchronously, so the helper's `PluginStorageMirror`
  answers from the launch's snapshot and sends every write back as a `PluginStorageWrite`, which the
  app applies to `PluginStore` in order. The app stays the only writer of the files.
- **Manifests are plugin code too.** `PluginManager`'s scan runs in the helper (`scan`), which runs
  `PluginCatalog.scan` and sends each manifest's JSON or its `PluginManifestError` back.
- **A crash ends sessions, not the app.** When the link closes, waiting requests get nothing and each
  running session fails with "its process ended"; the next scan or launch starts a new helper.
- **A watchdog catches a stuck main thread.** While a session runs, the app pings every 2 s and kills
  the helper if a ping goes unanswered for 10 s (generous, since a cold kit compile takes seconds).
  Scrift's limits stop runaway script code; the watchdog covers whatever they can't reach.
- **It gives memory back.** The helper exits after 90 s with nothing running, or as soon as nothing
  runs once its footprint has passed 768 MB. It reports its footprint (`footprint`) after each
  runtime ends. Switching plugins off sends `exitWhenIdle`.
- **It runs on the real main thread** (`RunLoop.main.run()`, not `dispatchMain()`), because Scrift
  checks that main-actor host types are called there.

A build without the helper, or one run with `TINYCAST_PLUGINS_IN_PROCESS=1`, runs plugins in the app
with `ScriftPluginRuntime`, as before.

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

`./Scripts/test-plugins.sh` builds `Tests/PluginHost`, a SwiftPM package that links the real Scrift, and
runs two suites. `PluginContractTests` encodes every case of the view contract against its golden
JSON in `Fixtures/contract` (`UPDATE_GOLDEN=1` rewrites them) and checks that a newer minor
version's frames decode as placeholders. `PluginHostTests` drives `ScriftPluginRuntime` the way
`PluginHost` does (launch, frames, `perform`, `set`, `search`, `back`, stop) against a host that
records every call. Its checks cover manifests and their errors, the catalog's cache, registration
checks, frames against snapshots in `Fixtures/frames` (`UPDATE_SNAPSHOTS=1`), bindings, navigation,
storage, forms, grids and their toolbar picker, menu bar commands, preferences, toasts and their
actions, `launchCommand`, action commands, compile errors, runaway loops, permission gating and
`open` rules, the palette's walk of a frame (`PluginScreenLayout`), entry IDs and deep links, and
which commands lose their references when a plugin changes, using `Tests/PluginHost/Fixtures` and
`Examples/Plugins`. It then runs `tinycast-plugin dump` on every example. The Hacker News and Google
Translate checks call the live APIs, and are skipped when they're unreachable. The plugin helper's
checks spawn the real `plugin-helper` binary and drive it through `PluginHelperClient` and
`RemotePluginRuntime`: frames, handlers, host calls, storage writes and reading them back,
navigation, a crash and the respawn after it, failed launches, runaway loops, the scan, and idle
exit. Its sources are symlinks to `Features/Plugins` and the few app files they use. The first run
builds Scrift and swift-syntax and takes a few minutes.

`./Scripts/bench-plugins.sh` measures a command: `plugin-bench`, in the same package, runs one
command with a fresh runtime per launch as the palette does, and reports time to first frame and to
content, each frame's size and encode time, CPU, memory during the launch and retained after it.
`plugin-bench helper` runs it in the plugin helper as the app does: the app's side is then the pipe,
and the helper's footprint is reported separately.
