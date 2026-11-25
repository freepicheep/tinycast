import Tinycast

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
                Label("Settings", systemImage: "gearshape")
                    .foregroundStyle(.gray)
                    .subtitle("CleanShot X")
                    .contextMenu {
                        Link("Open Settings", destination: "cleanshot://open-settings")
                        ForEach(settingsTabs, id: \.0) { tab, title in
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
        Label(tool.title, systemImage: tool.systemImage)
            .foregroundStyle(.blue)
            .subtitle(tool.subtitle)
            .searchKeywords(tool.command)
            .contextMenu {
                Link(tool.takesAfterCapture ? "Capture" : "Open", destination: tool.url())
                if tool.takesAfterCapture {
                    ForEach(AfterCapture.allCases, id: \.self) { after in
                        Link(after.title, destination: tool.url(after: after))
                    }
                }
            }
    }
}
