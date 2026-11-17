import Tinycast

struct City {
    let name: String
    let country: String
}

struct CityDetail: View {
    let city: City
    @State var visits = 0
    var body: some View {
        Detail(markdown: "# \(city.name)\nVisited \(visits) times")
            .metadata {
                LabeledContent("Country", value: city.country)
            }
            .actions {
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
                Section("Pinned") { Item(pinned, systemImage: "pin").tint(.orange) }
            }
            Section("Cities") {
                ForEach(matching) { city in
                    Item(city.name, subtitle: city.country, systemImage: "building.2")
                        .badge(city.name.count)
                        .actions {
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
