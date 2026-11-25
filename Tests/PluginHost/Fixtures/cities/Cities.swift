import Tinycast

struct City: Identifiable {
    let name: String
    let country: String

    var id: String { name }
}

struct CityDetail: View {
    let city: City
    @State var visits = 0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Detail(markdown: "# \(city.name)\nVisited \(visits) times")
            .metadata {
                LabeledContent("Country", value: city.country)
            }
            .toolbar {
                Button("Visit") { visits += 1 }
                Button("Back") { dismiss() }
            }
    }
}

struct Cities: View {
    @State private var query = ""
    @State private var loaded: [City] = []
    @State private var loading = true
    @AppStorage("pinned") private var pinned = ""

    var matching: [City] {
        loaded.filter { query.isEmpty || $0.name.lowercased().contains(query.lowercased()) }
    }

    var body: some View {
        List {
            if !pinned.isEmpty {
                Section("Pinned") { Label(pinned, systemImage: "pin").foregroundStyle(.orange) }
            }
            Section("Cities") {
                ForEach(matching) { city in
                    Label(city.name, systemImage: "building.2")
                        .subtitle(city.country)
                        .badge(city.name.count)
                        .contextMenu {
                            CopyButton(text: city.name)
                            Button("Pin") { pinned = city.name }
                                .keyboardShortcut("p", modifiers: [.command, .shift])
                            NavigationLink("Show") { CityDetail(city: city) }
                            if city.country == "Japan" { Link("Map", destination: "https://maps.apple.com/?q=Tokyo") }
                        }
                }
            }
            if matching.isEmpty && !loading { ContentUnavailableView.search(text: query) }
        }
        .navigationTitle("Cities")
        .searchable(text: $query, prompt: "Filter cities")
        .loading(loading)
        .task {
            try? await Task.sleep(for: .milliseconds(20))
            loaded = [
                City(name: "Tokyo", country: "Japan"), City(name: "London", country: "UK"),
                City(name: "Lima", country: "Peru")
            ]
            loading = false
        }
    }
}
