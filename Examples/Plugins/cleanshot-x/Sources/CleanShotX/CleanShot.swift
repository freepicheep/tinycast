import TinycastKit

struct CleanShot: View {
    var body: some View {
        List {
            Section("Capture") {
                ForEach(captures) { tool in ToolRow(tool: tool) }
            }
            Section("Record") {
                ForEach(recording) { tool in ToolRow(tool: tool) }
            }
            Section("Edit") {
                ForEach(editing) { tool in ToolRow(tool: tool) }
            }
            Section("Desktop") {
                ForEach(desktop) { tool in ToolRow(tool: tool) }
            }
            Section {
                Item("Settings", subtitle: "CleanShot X", systemImage: "gearshape")
                    .tint(.gray)
                    .actions {
                        Link("Open Settings", destination: "cleanshot://open-settings")
                        for (tab, title) in settingsTabs {
                            Link("Open \(title) Settings", destination: "cleanshot://open-settings?tab=\(tab)")
                        }
                    }
            }
        }
        .navigationTitle("CleanShot X")
    }
}

/// ↵ runs the tool as CleanShot is set up; ⌘K says what to do with the capture instead.
struct ToolRow: View {
    let tool: Tool

    var body: some View {
        Item(tool.title, subtitle: tool.subtitle, systemImage: tool.systemImage)
            .tint(.blue)
            .keywords([tool.command])
            .actions {
                Link(tool.takesAfterCapture ? "Capture" : "Open", destination: tool.url())
                if tool.takesAfterCapture {
                    for after in AfterCapture.allCases {
                        Link(after.title, destination: tool.url(after: after))
                    }
                }
            }
    }
}
