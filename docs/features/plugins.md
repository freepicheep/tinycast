# Plugins

Plugins are commands compiled to WebAssembly. A plugin is one `plugin.wasm` module: written in Swift
against the `TinycastKit` package, built with the Swift SDK for WebAssembly, and run by Tinycast in
JavaScriptCore's WebAssembly engine, metered and with no access to the Mac but what it asks Tinycast
for. Its views are shaped like SwiftUI's. A plugin command runs in the Extensions host, beside Raycast
extensions: the same screens, menu bar items, background refresh, preferences, arguments, hotkeys,
aliases and toasts.

- [Invariants](#invariants) · [Writing a plugin](#writing-a-plugin) · [The kit](#the-kit) ·
  [Permissions](#permissions) · [How it runs](#how-it-runs) · [The module's interface](#the-modules-interface) ·
  [Testing](#testing)

## Invariants

- **Off means off.** `pluginsEnabled` is opt-in. `PluginManager.setEnabled(false)` stops watching the
  folder, empties the installed set and takes every plugin out of the Extensions host
  (`ExtensionManager.setPlugins([])`), which ends its running commands. Enabling is also consent to run
  someone else's code, so it confirms first and never rides a settings backup.
- **A plugin is an engine of the Extensions host, not a second palette.** `PluginManager` hands the
  host one `InstalledExtension` per plugin, with `engine: .plugin` and the manifest translated by
  `PluginManifest.extensionManifest()`, plus a factory that makes a `WasmPluginRuntime` per launch.
  The host drives it through `ExtensionCommandRuntime`, as it drives the JavaScript runtime, so every
  lane (palette, background, menu bar) and every host API works for plugins without plugin code.
- **Plugins keep their own names.** A plugin's host name is `plugin.<name>`; a Raycast extension's
  name can't contain a dot, so the two never share storage, preferences or entry ids. A plugin's
  folder is never deleted by Tinycast: the launcher and Settings offer no uninstall for it.
- **Nothing runs unmetered.** `WasmMeter` rewrites every module before its first run: each function
  entry and loop header spends fuel, and an empty tank calls back into the host, which refuels it or,
  past the call's deadline (5 s), throws. Memory is capped at 512 MiB whatever the module declares. A
  module the meter can't read (an unknown instruction, imported memory, a second memory) is refused,
  never run as is. Only the metered copy is ever instantiated.
- **The imports are the whole world.** A module gets the `tinycast` imports and a WASI shim with no
  files, no environment, no clock but the time, and `stdout`/`stderr` kept for error reports;
  `path_open` answers `ENOTCAPABLE` and anything else unknown `ENOSYS`. Every host call goes through
  `PluginHostPolicy` first, which is the whole of what a permission grants: an API it doesn't list
  doesn't exist for plugins.
- **`open` reaches web addresses, `mailto:`, file paths and the app link schemes `urlSchemes` names.**
  `PluginOpenTarget` decides in the policy, before anything reaches the host. No manifest may name
  `file` or Tinycast's or Raycast's own schemes.
- **A launch is the plugin's whole world.** Each launch gets its own instance on its own queue.
  Plugins share no memory with each other or with an earlier launch; what outlives a launch is the
  host's `ExtensionStorage` under the plugin's host name.
- **A trap ends the instance.** A Swift crash, an exit, a missed deadline or an import that throws
  leaves the module's state unknowable, so `WasmPluginRuntime` drops the instance and fails the
  session with the reason and what the plugin printed.
- **The manifest is the module's answer to `tinycast_describe`**, run with no host APIs at all, so
  describing a plugin can't reach the app whatever it declares. `PluginManifest.decode` checks it
  (names, duplicates, schemes, preferences, intervals); the folder's name must be the manifest's.
- **`PluginKit/` is never compiled into the app.** It's a Swift package plugins depend on, built only
  by the Swift SDK for WebAssembly, and the app talks to it only through the interface below.

## Writing a plugin

A plugin is a Swift package with one executable target that depends on `TinycastKit`:

```swift
// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "WorldClock",
    dependencies: [.package(path: "../tinycast/PluginKit")],
    targets: [
        .executableTarget(
            name: "WorldClock",
            dependencies: [.product(name: "TinycastKit", package: "PluginKit")],
            swiftSettings: [.defaultIsolation(MainActor.self)])
    ]
)
```

Its `@main` type is the plugin: the manifest, and each command with its code.

```swift
import TinycastKit

@main
struct WorldClock: Plugin {
    let manifest = Manifest(
        name: "world-clock",
        title: "World Clock",
        description: "The time in the cities you care about.",
        icon: "globe",
        permissions: [.network],
        preferences: [.textfield("home", title: "Home City", default: "London")])

    var commands: [Command] {
        Command.view("clocks", title: "World Clock", subtitle: "Time zones", keywords: ["time"]) {
            Clocks()
        }
        Command.action("copy-utc", title: "Copy UTC Time") {
            Clipboard.copy(utcNow())
        }
        Command.menuBar("menu", title: "World Clock in the Menu Bar", interval: "1m") {
            ClockMenu()
        }
    }
}
```

`name` is lowercase letters, digits and hyphens. A `view` command opens a screen; an `action` command
does its work and closes the palette, and with an `interval` also runs in the background; a `menuBar`
command is a menu bar item, refreshed every `interval`. A command without a `subtitle` or `icon` shows
the plugin's. Commands take `arguments` (`.text`, `.password`: fields the launcher shows after the
title) and `preferences`; the manifest's `preferences` apply to all of them. Preferences are
`textfield`, `password`, `checkbox`, `dropdown`, `application`, `file` and `directory`, edited in
Settings, and a required one without a value is asked for before the command runs. `permissions` are
`.network`, `.clipboard` and `.selection`; `urlSchemes` lists the app links `open` may reach. Because
`commands` is a builder, a loop or an `if` declares commands too.

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
        .task { cities = (try? await City.load()) ?? [] }
    }
}
```

Without `.searchable`, Tinycast filters the rows by title, subtitle and `.keywords`. With
`.searchable(text: $query)`, the plugin gets each keystroke and filters its rows itself, usually with
`.task(id: query)`, which cancels and restarts its work as the query changes. Swift concurrency works
as usual: `Task.sleep` becomes a host timer, and `async let` and task groups run their children
between host calls.

Import `FoundationEssentials` rather than `Foundation`: it has `Date`, `URL`, `Data` and `JSONDecoder`
without ICU's data, which would make the module tens of megabytes larger. `URLSession` doesn't exist in
WebAssembly; `fetch` is the network.

Build it into the Plugins folder (`~/Library/Application Support/<bundle id>/Plugins`, Settings →
Plugins → Open Plugins Folder), in a folder named as the manifest:

```sh
./Scripts/build-plugin.sh Examples/Plugins/hacker-news \
    ~/Library/Application\ Support/com.abueammar.tinycast.dev/Plugins/hacker-news
```

The script needs the Swift SDK for WebAssembly (`swift sdk install`) and the swift.org toolchain of the
same version in `~/Library/Developer/Toolchains`, since Xcode's compiler can't link WebAssembly. It
builds in release and, when Homebrew's `wasm-opt` (binaryen) is installed, shrinks the module, to
about 8 MB with Foundation's essentials. Tinycast notices the new module and lists its commands.

Two complete plugins are in [`Examples/Plugins`](../../Examples/Plugins):

- **`hacker-news`** (port of Raycast's Hacker News): front page, newest, Ask HN and Show HN from HN's
  Algolia API, chosen in the search bar's dropdown, plus search as you type, and the top story in the
  menu bar. Shows `network` and `fetch`, `@AppStorage`, `searchBarAccessory`, `.task(id:)` and
  cancellation, and a `MenuBarExtra` with ⌥ alternates.
- **`cleanshot-x`** (port of Raycast's CleanShot X): every CleanShot X tool as a launcher command,
  declared in one loop, plus a list of them whose ⌘K menu says what to do with the capture. Shows
  `urlSchemes`.

## The kit

`TinycastKit` (`PluginKit/`). Each view renders the Raycast component of the same role, so a plugin
looks and behaves like an extension:

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
| State | `@State`, `@Binding`, `@AppStorage` and `LocalStorage` (String, Int, Double, Bool), `Cache`, `@Preference`, `getPreferenceValues()` |
| Launch | `Launch.commandName`, `arguments`, `type`, `context`, `fallbackText`, `isDarkAppearance` |
| Host | `showToast` (a `Toast` to change or hide), `showHUD`, `confirmAlert`, `Clipboard`, `open`, `showInFinder`, `closeMainWindow`, `popToRoot`, `clearSearchBar`, `openPreferences`, `launchCommand`, `updateCommandMetadata`, `getApplications`, `getDefaultApplication`, `getFrontmostApplication`, `getSelectedText`, `getSelectedFinderItems`, `dismiss` |
| Network | `fetch(_:method:headers:body:)` → `Response` (`status`, `ok`, `headers`, `data`, `text`) |
| Sign-in | `OAuth.PKCEClient`: `authorizationRequest`, `authorize`, `setTokens`, `getTokens`, `removeTokens` |

↵ runs a row's first action, ⌘↵ its second, and ⌘K lists all of them. Escape pops a `NavigationLink`
before it leaves the command. A `task` starts the first time its screen renders and is cancelled when
the screen leaves the stack. Changing `@State` or `@AppStorage` renders again, once per call into the
module. A `Button`'s action is synchronous, as in SwiftUI; start awaited work with `Task { … }`. A form
field marked `storeValue` is saved when a `SubmitButton` runs and starts from that value next time. A
toast's action runs while its command does; an action command that wants one waits before returning.

`@AppStorage`, `LocalStorage` and `Cache` read synchronously from a copy of the plugin's storage that
arrives with the launch, and write through to the host, so a value set is read back at once.

## Permissions

| Permission | Grants |
|---|---|
| `network` | `fetch` (the host's own, as Raycast's `fetch`), WebSockets and name lookups; never a Unix socket |
| `clipboard` | `Clipboard.readText()` |
| `selection` | `getSelectedText()` and `getSelectedFinderItems()` |
| `urlSchemes` | `open` and `Link` reach those app link schemes, such as `cleanshot`; never `file`, `tinycast`, `tinycast-dev`, `raycast` or `com.raycast` |

Writing to the clipboard (`CopyButton`, `Clipboard.copy`) and pasting need no permission. A call the
manifest doesn't allow throws, with the permission it needs, and never reaches the host.

## How it runs

`PluginManager` (owned by `AppCore`) scans the folder when plugins are on and watches it for changed
modules. `PluginCatalog.scan` hashes each `plugin.wasm` (SHA-256) and, for a module it hasn't seen,
meters it, asks the metered copy to describe itself, and keeps both in
`Caches/Plugins/<meterVersion>-<sha256>.wasm` and `.json`. Metering an 8 MB module takes about 30 ms
and describing it about 100 ms; a scan of unchanged plugins only hashes. Entries no plugin uses are
removed, and failures aren't kept. Each scan hands the Extensions host the plugins as
`InstalledExtension`s with `engine: .plugin`, so the launcher lists their commands with the host's
icon, hotkey, alias and argument handling, and the menu bar and background lanes schedule them.

Launching a command makes a `WasmPluginRuntime`, which the host drives like the JavaScript runtime:

1. `WasmInstance` maps the metered module, compiles it in a `JSContext` of its own (about 50 ms for
   8 MB), links the imports, wires the refuel hook and runs the module's `_initialize`.
2. `tinycast_launch` hands the kit the command and its launch: arguments, preferences, the storage
   snapshot, caches, stored form values, launch type and context, appearance and Tinycast's scheme.
   The kit runs the plugin's `main`, which registers it, and starts the command.
3. The kit renders a screen into Raycast's `RenderTree` JSON itself (`{"$fn": id}` for handlers,
   `{"$date": …}` for dates), with node ids stable from one render to the next, and hands it to the
   `render` import. The host sends handler ids back through `tinycast_dispatch`, Escape through
   `tinycast_pop` and a toast's button through `tinycast_toast_action`.
4. Everything else a plugin asks of the app is a `call` import: `{api, method, args}`, the same names
   the JavaScript runtime sends. `PluginHostPolicy` checks it; the host's `ExtensionHostAPI` answers;
   the answer comes back through `tinycast_settle` on a later turn of the instance's queue, never
   inside the call that asked, and resumes the awaiting task.
5. The kit's executor runs every job before an export returns, so the module is idle between calls.
   A sleeping task asks for a host timer (`set_timer`), which calls `tinycast_timer`.

A plugin command's deep link is `tinycast://plugins/<name>/<command>` (`tinycast-dev://` in Debug),
with Raycast's `arguments`, `launchType` and `context` query items; Copy Deeplink gives that form.
`ExtensionDeepLink` reads it as the host name `plugin.<name>`, which also works in an `extensions/`
link. Raycast's schemes never reach a plugin. Hotkeys and deep links run a plugin's command whether
or not Raycast extensions are switched on.

`OAuth.PKCEClient` signs in with OAuth 2.0 and PKCE as Raycast's does. `authorizationRequest` builds
the URL in the kit (a verifier from WASI's `random_get`, which is the system's `SecRandomCopyBytes`,
its S256 challenge, a state nonce), with Tinycast's own redirect `tinycast://oauth?plugin=<name>`
unless the plugin names a custom one. `authorize` runs the host's browser sign-in, checks the returned
state and gives back the code; the provider's `error_description` becomes the thrown error. Tokens are
kept per provider by the host (`setTokens`, `getTokens` with `isExpired`, `removeTokens`). The token
exchange is the plugin's own `fetch`, under the `network` permission.

Settings › Plugins opens each plugin to the same card as an extension's: show in launcher, launcher
icon, preferences, and per command its alias, hotkey, visibility, menu bar toggle and background
refresh. "Configure Plugin" in the launcher opens that card; "Show in Finder" replaces uninstall.

Errors (a Swift crash with its message, a missed deadline, a refused call) replace the screen with
the message and the plugin's recent output.

## The module's interface

What a module exports and imports, for a kit in another language. Strings cross as a pointer and a
byte length into the module's memory; the host writes its strings into memory from `tinycast_alloc`,
and the module frees them.

| Export | Called |
|---|---|
| `_initialize` | once, after instantiation (a WASI reactor) |
| `tinycast_alloc(size) → ptr` | to place a string the host passes |
| `tinycast_describe()` | to read the manifest, which comes back through `manifest` |
| `tinycast_launch(session, command, launch)` | to start a command; `launch` is JSON |
| `tinycast_dispatch(handler, payload, completes)` | for a handler id with its JSON arguments |
| `tinycast_pop() → i32` | for Escape; 1 when a screen was popped |
| `tinycast_settle(id, ok, answer)` | with a host call's answer, or its error when `ok` is 0 |
| `tinycast_timer(token)` | when a timer the module set fires |
| `tinycast_toast_action(token)` | when a toast's button is pressed |
| `tinycast_stop()` | when the command is closed |

| Import (`tinycast`) | Does |
|---|---|
| `render(session, json)` | shows the `RenderTree` |
| `navigation(session, depth)` | reports the stack's depth |
| `finished(session)` / `failed(session, message)` | ends the session |
| `call(id, json)` | a host call, answered later through `tinycast_settle` |
| `set_timer(token, ms)` / `clear_timer(token)` | a one-shot timer |
| `manifest(json)` | the manifest, from `tinycast_describe` |

`WasmMeter` adds the `tinycast_fuel` global and the one-slot `tinycast_refuel` table; a module must
not export those names itself.

## Testing

`./Scripts/run-tests.sh` runs `PluginTests`: the meter on modules built by hand (valid output, its
exports, refusals, the memory cap, a loop stopped by the refuel hook), `PluginHostPolicy`'s rules and
manifest decoding.

`./Scripts/test-plugins.sh` builds `Tests/PluginFixtures/kitchen` and every example with
`build-plugin.sh`, then drives them through the shipped `PluginCatalog` and `WasmPluginRuntime` the way
the Extensions host does (launch, render, dispatch, pop, stop), against a host that records every call
and answers like the real one. Its checks cover the catalog and its cache, rendering, state, actions,
navigation, storage, forms with stored values, toasts and their actions, timers and concurrent host
calls, preferences and arguments, OAuth with forged and refused redirects, menu bar commands, refused
calls, a crash and a hung command stopped at its deadline, and each example against a canned response.
It needs the Swift SDK for WebAssembly, so it isn't part of `run-tests.sh`.
