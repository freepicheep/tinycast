import Foundation
import Selection
import Tinycast

/// Quick Translate: the selection, handed to Quick Translate Results.
func quickTranslate() async throws {
    var text = ""
    if preference("autoInput") {
        // No selection is a valid launch: the results open empty and editable.
        text = (try? await selectedText()) ?? ""
    }
    try await launchCommand(
        "quick-translate-view", context: ["text": .string(text), "requestId": .string(UUID().uuidString)])
}

/// Target languages for Quick Translate, by default the primary and secondary preferences.
func storedTargets(_ stored: String) -> [String] {
    let saved = stored.split(separator: ",").map(String.init)
    if !saved.isEmpty { return saved }
    let preferences = preferencesSet()
    return preferences.to.filter { $0 != autoDetect }
}

/// Quick Translate Results: the text in every target language at once, with the detail open.
struct QuickTranslateResults: View {
    @AppStorage("sourceLanguage") private var source = "auto"
    @AppStorage("targetLanguages") private var targetsStored = ""
    @State private var text = ""
    @State private var results: [Translation] = []
    @State private var isLoading = false
    @State private var showingDetail = true
    @State private var memo = Memo()

    var body: some View {
        let targets = storedTargets(targetsStored)
        return List {
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ForEach(results.indices) { index in
                    row(results[index])
                }
            }
        }
        .searchable(text: $text, prompt: "Enter text to translate")
        .loading(isLoading)
        .showingDetail(showingDetail)
        .searchBarAccessory(
            Dropdown("Language", selection: $source) {
                for language in languages {
                    Choice(language.name, value: language.code)
                }
            })
        .actions {
            NavigationLink("Translate to  ->  " + targets.map(languageName).joined(separator: " "), systemImage: "pencil") {
                TargetLanguages()
            }
            .keyboardShortcut("l")
        }
        .task(id: text + "\n" + source + "\n" + targetsStored) { await load(targets) }
    }

    private func row(_ result: Translation) -> Item {
        var markdown = result.translatedText + "\n\n\n"
        if let pronunciation = result.pronunciation {
            markdown += "```\n" + pronunciation + "\n```\n\n"
        }
        let from = languageName(result.langFrom)
        let to = languageName(result.langTo)
        return Item(result.translatedText)
            .id(result.langTo)
            .accessory(to, tooltip: from + " -> " + to)
            .detail {
                Detail(markdown: markdown)
                    .metadata {
                        TagList("Source Language") {
                            if source == autoDetect { Tag(languageName(autoDetect), color: Color(css: "#FECD57")) }
                            Tag(from, color: Color(css: "#A0D468"))
                        }
                        TagList("Target Language") {
                            Tag(to, color: Color(css: "#B3A5EF"))
                        }
                    }
            }
            .actions {
                ActionSection {
                    if pastesFirst() {
                        PasteButton("Paste Translation", text: result.translatedText)
                        CopyButton("Copy Translation", text: result.translatedText).keyboardShortcut("c", modifiers: [.command, .shift])
                    } else {
                        CopyButton("Copy Translation", text: result.translatedText).keyboardShortcut("c", modifiers: [.command, .shift])
                        PasteButton("Paste Translation", text: result.translatedText)
                    }
                    Button("Toggle Full Text", systemImage: "text.alignleft") { showingDetail.toggle() }
                        .keyboardShortcut("f")
                    Link(
                        "Open in Google Translate",
                        destination: googleTranslateURL(text, from: result.langFrom, to: result.langTo)
                    )
                    .keyboardShortcut("return", modifiers: [.option])
                }
            }
    }

    private func load(_ targets: [String]) async {
        if !memo.filledSelection {
            memo.filledSelection = true
            if case .string(let launched) = Plugin.launchContext["text"], !launched.isEmpty, text.isEmpty {
                text = launched
                return
            }
        }
        let value = text
        let previous = memo.previousText
        memo.previousText = value
        if isSingleCharacterEdit(previous, value) {
            try? await Task.sleep(for: .milliseconds(debounceMilliseconds))
            guard !Task.isCancelled else { return }
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            isLoading = false
            return
        }
        isLoading = true
        do {
            let translated = try await multiTranslate(
                trimmed, LanguageSet(from: source, to: targets),
                prioritizeCrossLanguage: preference("prioritizeCrossLanguage"))
            guard !Task.isCancelled else { return }
            results = translated
        } catch {
            guard !Task.isCancelled else { return }
            results = []
            await showToast(.failure, title: "Could not translate", message: "\(error)")
        }
        isLoading = false
    }
}

/// The target languages: the chosen ones, in order, then every other to add.
struct TargetLanguages: View {
    @AppStorage("targetLanguages") private var targetsStored = ""

    var body: some View {
        let targets = storedTargets(targetsStored)
        return List {
            Section("Selected Languages", subtitle: "\(targets.count)") {
                ForEach(targets.indices) { index in
                    selectedRow(targets, index)
                }
            }
            Section("Available Languages") {
                for language in languages where language.code != autoDetect && !targets.contains(language.code) {
                    Item(language.name, subtitle: language.code)
                        .id(language.code)
                        .actions {
                            Button("Add", systemImage: "plus") {
                                save(targets + [language.code])
                                clearSearchBar()
                            }
                            .keyboardShortcut("n")
                        }
                }
            }
        }
        .searchable(prompt: "Search languages")
    }

    private func selectedRow(_ targets: [String], _ index: Int) -> Item {
        let code = targets[index]
        let item = Item(languageName(code), subtitle: code).id("selected-" + code)
        // English alone stays: there is always one target.
        if targets.count == 1 && code == "en" { return item }
        return item.actions {
            Button("Remove", systemImage: "minus", role: .destructive) {
                var remaining = targets
                remaining.remove(at: index)
                save(remaining.isEmpty ? ["en"] : remaining)
                clearSearchBar()
            }
            .keyboardShortcut("x", modifiers: [.control])
            Button("Move Up", systemImage: "arrow.up") {
                guard index > 0 else { return }
                var moved = targets
                moved.swapAt(index, index - 1)
                save(moved)
            }
            .keyboardShortcut("arrowUp", modifiers: [.shift])
            Button("Move Down", systemImage: "arrow.down") {
                guard index < targets.count - 1 else { return }
                var moved = targets
                moved.swapAt(index, index + 1)
                save(moved)
            }
            .keyboardShortcut("arrowDown", modifiers: [.shift])
        }
    }

    private func save(_ targets: [String]) {
        targetsStored = targets.joined(separator: ",")
    }
}
