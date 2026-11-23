import Foundation
import Tinycast

struct Note: View {
    @State var subject = Plugin.arguments["subject"] ?? ""
    @State var body_ = ""
    @State var urgent = false
    @State var kind = "idea"
    @State var tags: [String] = []
    @State var due: Date? = nil
    @State var saved = ""

    var body: some View {
        Form {
            TextField("Subject", text: $subject, prompt: "What about?").storeValue()
            TextEditor("Body", text: $body_)
            Toggle("Urgent", isOn: $urgent)
            Picker("Kind", selection: $kind) {
                Choice("Idea", value: "idea")
                Choice("Task", value: "task")
            }
            TagPicker("Tags", selection: $tags) {
                Choice("Home", value: "home")
                Choice("Work", value: "work")
            }
            DatePicker("Due", selection: $due)
            Divider()
            Text(saved.isEmpty ? "Unsaved" : saved, title: "Status")
        }
        .navigationTitle(Plugin.launchContext["origin"] == nil ? "New Note" : "Note from hop")
        .actions {
            SubmitButton("Save") { saved = "Saved \(subject) \(kind) \(tags.joined(separator: ","))" }
        }
    }
}

struct Colors: View {
    @AppStorage("palette") var palette = "warm"

    var body: some View {
        Grid(columns: 4, aspectRatio: "3/2") {
            Section("Swatches") {
                Item("Red", color: .red)
                Item("Star", systemImage: "star")
                Item(palette == "warm" ? "Sun" : "Ice", emoji: palette == "warm" ? "☀️" : "🧊")
                    .actions { CopyButton(text: palette) }
            }
        }
        .searchBarAccessory(
            Dropdown("Palette", selection: $palette) {
                Choice("Warm", value: "warm")
                Choice("Cool", value: "cool")
            })
    }
}

struct Status: View {
    @State var count = 0

    var body: some View {
        MenuBarExtra("\(count)", systemImage: "number") {
            MenuItem("Add") { count += 1 }
                .keyboardShortcut("a")
            Divider()
            Section("More") {
                Menu("Reset") {
                    MenuItem("To zero") { count = 0 }
                }
            }
        }
    }
}
