import Foundation
import Tinycast

enum Kind: String, CaseIterable, Codable, Identifiable {
    case idea
    case task

    var id: String { rawValue }
}

struct Note: View {
    @AppStorage("subject") var subject = Plugin.arguments["subject"] ?? ""
    @State var text = ""
    @State var urgent = false
    @State var kind = Kind.idea
    @State var tags: Set<String> = []
    @State var due = Date(timeIntervalSince1970: 0)
    @State var saved = ""

    var body: some View {
        Form {
            TextField("Subject", text: $subject, prompt: "What about?")
            TextEditor("Body", text: $text)
            Toggle("Urgent", isOn: $urgent)
            Picker("Kind", selection: $kind) {
                ForEach(Kind.allCases) { kind in Text(kind.rawValue.capitalized).tag(kind) }
            }
            MultiPicker("Tags", selection: $tags) {
                Text("Home").tag("home")
                Text("Work").tag("work")
            }
            DatePicker("Due", selection: $due)
            Divider()
            LabeledContent("Status", value: saved.isEmpty ? "Unsaved" : saved)
        }
        .navigationTitle(Plugin.launchContext["origin"] == nil ? "New Note" : "Note from hop")
        .toolbar {
            Button("Save") { saved = "Saved \(subject) \(kind.rawValue) \(tags.sorted().joined(separator: ","))" }
        }
    }
}

enum Palette: String, Codable, CaseIterable {
    case warm
    case cool
}

struct Colors: View {
    @AppStorage("palette") var palette = Palette.warm

    var body: some View {
        Grid(columns: 4, aspectRatio: 1.5) {
            Section("Swatches") {
                Label("Red", image: Image(color: .red))
                Label("Star", systemImage: "star")
                Label(palette == .warm ? "Sun" : "Ice", image: Image(emoji: palette == .warm ? "☀️" : "🧊"))
                    .contextMenu { CopyButton(text: palette.rawValue) }
            }
        }
        .toolbar {
            Picker("Palette", selection: $palette) {
                Text("Warm").tag(Palette.warm)
                Text("Cool").tag(Palette.cool)
            }
        }
    }
}

struct Status: View {
    @State var count = 0

    var body: some View {
        MenuBarExtra("\(count)", systemImage: "number") {
            Button("Add") { count += 1 }
                .keyboardShortcut("a")
            Divider()
            Section("More") {
                Menu("Reset") {
                    Button("To zero") { count = 0 }
                }
            }
        }
    }
}
