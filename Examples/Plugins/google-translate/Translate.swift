import Foundation
import Selection
import Tinycast

/// What a screen remembers between renders without rendering again when it changes.
final class Memo {
    var previousText = ""
    var filledSelection = false
}

/// The Translate command: type, and the translation (there and back, or into each target) appears.
struct Translate: View {
    @AppStorage("selectedLanguageSet") private var selectedStored = ""
    @AppStorage("languageSets") private var savedStored = ""
    @State private var text = ""
    @State private var results: [Translation] = []
    @State private var isLoading = false
    @State private var showingDetail = false
    @State private var memo = Memo()

    /// The chosen set, or the preferences' source and primary language until one is chosen.
    private var selected: LanguageSet {
        if let set = LanguageSet(stored: selectedStored) { return set }
        let preferences = preferencesSet()
        return LanguageSet(from: preferences.from, to: [preferences.to[0]])
    }

    /// The preferences' pair, then the saved sets: what ⌘↑ and ⌘↓ step through.
    private var allSets: [LanguageSet] { [preferencesSet()] + decodeSets(savedStored) }

    var body: some View {
        let set = selected
        return List {
            if isLoading {
                ContentUnavailableView("Translating...", systemImage: "hourglass")
            } else {
                ForEach(results.indices) { index in
                    rows(results[index], index: index)
                }
            }
        }
        .searchable(text: $text, prompt: "Enter text to translate")
        .showingDetail(showingDetail)
        .searchBarAccessory(
            Dropdown("Language Set", selection: $selectedStored) {
                for choice in allSets {
                    Choice(choice.title, value: choice.stored)
                }
            })
        .actions { setActions }
        .task(id: text + "\n" + set.stored) { await load(set) }
    }

    @ViewBuilder
    private func rows(_ result: Translation, index: Int) -> some View {
        let pair = languageName(result.langFrom) + " -> " + languageName(result.langTo)
        Item(result.translatedText)
            .id("\(index)")
            .accessory(pair, tooltip: pair)
            .detail { Detail(markdown: result.translatedText) }
            .actions {
                ActionSection {
                    if pastesFirst() {
                        PasteButton("Paste Translation", text: result.translatedText)
                        CopyButton("Copy Translation", text: result.translatedText).keyboardShortcut("c", modifiers: [.command, .shift])
                    } else {
                        CopyButton("Copy Translation", text: result.translatedText).keyboardShortcut("c", modifiers: [.command, .shift])
                        PasteButton("Paste Translation", text: result.translatedText)
                    }
                    toggleDetail
                    Link(
                        "Open in Google Translate",
                        destination: googleTranslateURL(text, from: result.langFrom, to: result.langTo)
                    )
                    .keyboardShortcut("return", modifiers: [.option])
                }
                setActions
            }
        if let pronunciation = result.pronunciation {
            Item(pronunciation)
                .id("\(index)-pronunciation")
                .accessory(pair, tooltip: pair)
                .detail { Detail(markdown: pronunciation) }
                .actions {
                    ActionSection {
                        if pastesFirst() {
                            PasteButton("Paste", text: pronunciation)
                            CopyButton("Copy", text: pronunciation).keyboardShortcut("c", modifiers: [.command, .shift])
                        } else {
                            CopyButton("Copy", text: pronunciation).keyboardShortcut("c", modifiers: [.command, .shift])
                            PasteButton("Paste", text: pronunciation)
                        }
                        toggleDetail
                        Link(
                            "Open in Google Translate",
                            destination: googleTranslateURL(text, from: result.langFrom, to: result.langTo)
                        )
                        .keyboardShortcut("return", modifiers: [.option])
                    }
                    setActions
                }
        }
    }

    private var toggleDetail: Action {
        Button("Toggle Full Text", systemImage: "text.alignleft") { showingDetail.toggle() }
            .keyboardShortcut("f")
    }

    private var setActions: ActionSection {
        ActionSection("Language Set") {
            Button("Go to Previous Language Set", systemImage: "arrow.up") { step(-1) }
                .keyboardShortcut("arrowUp", modifiers: [.command, .option])
            Button("Go to Next Language Set", systemImage: "arrow.down") { step(1) }
                .keyboardShortcut("arrowDown", modifiers: [.command, .option])
            NavigationLink("Manage Language Sets…", systemImage: "pencil") { LanguageSetManager() }
                .keyboardShortcut("l")
        }
    }

    private func step(_ offset: Int) {
        let sets = allSets
        let index = sets.firstIndex(of: selected) ?? 0
        selectedStored = sets[(index + offset + sets.count) % sets.count].stored
    }

    private func load(_ set: LanguageSet) async {
        // The first run fills the field from the selection, which starts this task again.
        if !memo.filledSelection {
            memo.filledSelection = true
            if text.isEmpty, preference("autoInput"), let selection = try? await selectedText(), !selection.isEmpty {
                text = selection
                return
            }
        }
        let value = text
        let previous = memo.previousText
        memo.previousText = value
        // Typing waits for a pause; a paste, a cleared field or a new set translates at once.
        if isSingleCharacterEdit(previous, value) {
            try? await Task.sleep(for: .milliseconds(debounceMilliseconds))
            guard !Task.isCancelled else { return }
        }
        guard !value.isEmpty else {
            results = []
            isLoading = false
            return
        }
        isLoading = true
        do {
            let translated =
                set.to.count == 1
                ? try await doubleWayTranslate(value, set)
                : try await multiTranslate(
                    value, set, prioritizeCrossLanguage: preference("prioritizeCrossLanguage"))
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

/// The saved language sets: choose one, save the current one, add or delete.
struct LanguageSetManager: View {
    @AppStorage("selectedLanguageSet") private var selectedStored = ""
    @AppStorage("languageSets") private var savedStored = ""

    var body: some View {
        let saved = decodeSets(savedStored)
        let preferences = preferencesSet()
        let selected = LanguageSet(stored: selectedStored) ?? LanguageSet(from: preferences.from, to: [preferences.to[0]])
        return List {
            Item("Add new language set...", systemImage: "plus")
                .actions {
                    NavigationLink("Add New Language Set…", systemImage: "plus") {
                        AddLanguageSet { set in
                            savedStored = encodeSets(saved + [set])
                            dismiss()
                            Task { await showToast(.success, title: "Language set was saved!", message: set.title) }
                        }
                    }
                    .keyboardShortcut("n")
                }
            if !saved.contains(selected), selected != preferences {
                Item("Save current set", subtitle: selected.title, systemImage: "square.and.arrow.down")
                    .actions {
                        Button("Save Current Set") { savedStored = encodeSets(saved + [selected]) }
                    }
            }
            row(preferences, selected: selected == preferences, onDelete: nil)
            ForEach(saved.indices) { index in
                row(saved[index], selected: selected == saved[index]) {
                    var remaining = saved
                    remaining.remove(at: index)
                    savedStored = encodeSets(remaining)
                    Task { await showToast(.success, title: "Language set was deleted!", message: saved[index].title) }
                }
            }
        }
        .actions {
            Button("Remove All", systemImage: "trash", role: .destructive) { savedStored = "" }
                .keyboardShortcut("x", modifiers: [.control, .shift])
        }
    }

    private func row(_ set: LanguageSet, selected: Bool, onDelete: (() -> Void)?) -> Item {
        var item = Item(languageName(set.from) + "   ->", subtitle: " " + set.to.map(languageName).joined(separator: ", "))
            .id(set.stored)
            .keywords([set.from] + set.to + set.to.map(languageName) + [languageName(set.from)])
        if selected { item = item.content(Image(systemName: "checkmark").tint(.green)) }
        return item.actions {
            Button("Select", systemImage: "checkmark") {
                selectedStored = set.stored
                dismiss()
            }
            if let onDelete {
                Button("Delete", systemImage: "trash", role: .destructive) { onDelete() }
            }
        }
    }
}

/// A source and as many targets as wanted: a new empty target picker appears after the last.
struct AddLanguageSet: View {
    let onAdd: (LanguageSet) -> Void
    @State private var from = "auto"
    @State private var targets: [String] = ["en"]

    var body: some View {
        Form {
            Picker("Source Language", selection: $from) {
                for language in languages {
                    Choice(language.name, value: language.code)
                }
            }
            .id("langFrom")
            ForEach(targets.indices) { index in
                Picker("Target Language \(index + 1)", selection: target(index)) {
                    if targets[index].isEmpty { Choice("", value: "") }
                    for language in languages where language.code != autoDetect {
                        Choice(language.name, value: language.code)
                    }
                }
                .id("langTo.\(index)")
            }
            if targets.last.map({ !$0.isEmpty }) ?? true {
                Picker("Target Language \(targets.count + 1)", selection: target(targets.count)) {
                    Choice("", value: "")
                    for language in languages where language.code != autoDetect {
                        Choice(language.name, value: language.code)
                    }
                }
                .id("langTo.\(targets.count)")
            }
        }
        .actions {
            SubmitButton("Add Language Set") {
                let chosen = targets.filter { !$0.isEmpty }
                guard !chosen.isEmpty else {
                    Task {
                        await showToast(
                            .failure, title: "No target languages",
                            message: "Please select at least one target language")
                    }
                    return
                }
                onAdd(LanguageSet(from: from, to: chosen))
            }
        }
    }

    /// The target at `index`; picking in the trailing empty picker adds a target.
    private func target(_ index: Int) -> Binding<String> {
        Binding(
            get: { index < targets.count ? targets[index] : "" },
            set: { value in
                if index < targets.count {
                    targets[index] = value
                } else {
                    targets.append(value)
                }
            })
    }
}
