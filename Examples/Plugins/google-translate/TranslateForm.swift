import Foundation
import Selection
import Tinycast

/// The Translate Form command: text, source and target, and the translation below as you type.
struct TranslateForm: View {
    @AppStorage("selectedLanguageSet") private var selectedStored = ""
    @State private var text = ""
    @State private var result: Translation? = nil
    @State private var isLoading = false
    @State private var memo = Memo()
    /// Bumped by each edit; a translation still running for an older one is dropped.
    @State private var generation = 0

    private var selected: LanguageSet {
        if let set = LanguageSet(stored: selectedStored) { return set }
        let preferences = preferencesSet()
        return LanguageSet(from: preferences.from, to: [preferences.to[0]])
    }

    var body: some View {
        let set = selected
        let langTo = set.to.first ?? "en"
        let detected = set.from == autoDetect ? result?.langFrom : nil
        return Form {
            TextEditor("Text", text: textBinding)
                .id("text")
                .autoFocus()
            Picker("From", selection: fromBinding(detected)) {
                if let detected {
                    Choice(languageName(detected) + " (Auto-detect)", value: detected)
                }
                for language in languages {
                    Choice(language.name, value: language.code)
                }
            }
            .id("language_from")
            Picker("To", selection: toBinding) {
                for language in languages where language.code != autoDetect {
                    Choice(language.name, value: language.code)
                }
            }
            .id("language_to")
            TextEditor("Translation", text: .constant(result?.translatedText ?? ""), prompt: "Translation")
                .id("result")
            Text(result?.pronunciation ?? "", title: "Pronunciation")
        }
        .loading(isLoading)
        .actions {
            ActionSection("Generals") {
                if pastesFirst() {
                    PasteButton("Paste Translated", text: (result?.translatedText ?? ""))
                    CopyButton("Copy Translated", text: (result?.translatedText ?? "")).keyboardShortcut("c", modifiers: [.command, .shift])
                } else {
                    CopyButton("Copy Translated", text: (result?.translatedText ?? "")).keyboardShortcut("c", modifiers: [.command, .shift])
                    PasteButton("Paste Translated", text: (result?.translatedText ?? ""))
                }
                CopyButton("Copy Text", text: text).keyboardShortcut(".", modifiers: [.command, .shift])
                CopyButton("Copy Pronunciation", text: result?.pronunciation ?? "")
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Link("Open in Google Translate", destination: googleTranslateURL(text, from: set.from, to: langTo))
                    .keyboardShortcut("return", modifiers: [.option])
                NavigationLink("Manage Language Sets…", systemImage: "pencil") { LanguageSetManager() }
                    .keyboardShortcut("l")
            }
            ActionSection("Settings") {
                Button(languageName(detected ?? set.from) + " <-> " + languageName(langTo)) {
                    selectedStored = LanguageSet(from: langTo, to: [detected ?? set.from]).stored
                    translate()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            }
        }
        .task { await fillFromSelection() }
    }

    private var textBinding: Binding<String> {
        Binding(
            get: { text },
            set: { value in
                if value.count > 5000 {
                    text = String(value.prefix(5000))
                    Task {
                        await showToast(
                            .failure, title: "Limit", message: "Max length (5000 chars) for a single translation exceeded")
                    }
                } else {
                    text = value
                }
                translate()
            })
    }

    private func fromBinding(_ detected: String?) -> Binding<String> {
        Binding(
            get: { detected ?? selected.from },
            set: { value in
                selectedStored = LanguageSet(from: value, to: selected.to).stored
                translate()
            })
    }

    private var toBinding: Binding<String> {
        Binding(
            get: { selected.to.first ?? "en" },
            set: { value in
                selectedStored = LanguageSet(from: selected.from, to: [value]).stored
                translate()
            })
    }

    private func fillFromSelection() async {
        guard text.isEmpty, preference("autoInput"), let selection = try? await selectedText(), !selection.isEmpty
        else { return }
        text = selection
        translate()
    }

    /// Starts a translation of the current text, after a pause when the edit was one keystroke.
    private func translate() {
        generation += 1
        let mine = generation
        let value = text
        let previous = memo.previousText
        memo.previousText = value
        let set = selected
        Task {
            if isSingleCharacterEdit(previous, value) {
                try? await Task.sleep(for: .milliseconds(debounceMilliseconds))
            }
            guard mine == generation else { return }
            isLoading = true
            do {
                let translated = try await simpleTranslate(value, LanguageSet(from: set.from, to: [set.to.first ?? "en"]))
                guard mine == generation else { return }
                result = translated
            } catch {
                guard mine == generation else { return }
                await showToast(.failure, title: "Could not translate", message: "\(error)")
            }
            isLoading = false
        }
    }
}
