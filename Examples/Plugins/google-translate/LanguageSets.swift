import Tinycast

/// A source and one or more targets, stored as `from:to1,to2`.
struct LanguageSet: Equatable {
    let from: String
    let to: [String]

    init(from: String, to: [String]) {
        self.from = from
        self.to = to
    }

    init?(stored: String) {
        let parts = stored.split(separator: ":").map(String.init)
        guard parts.count == 2 else { return nil }
        let targets = parts[1].split(separator: ",").map(String.init)
        guard !parts[0].isEmpty, !targets.isEmpty else { return nil }
        from = parts[0]
        to = targets
    }

    var stored: String { from + ":" + to.joined(separator: ",") }

    /// `Auto-Detect -> English, German`.
    var title: String {
        languageName(from) + " -> " + to.map(languageName).joined(separator: ", ")
    }
}

func languageName(_ code: String) -> String {
    languages.first { $0.code == code }?.name ?? code
}

/// Sets saved in the manager, one per line.
func decodeSets(_ stored: String) -> [LanguageSet] {
    stored.split(separator: "\n").compactMap { LanguageSet(stored: String($0)) }
}

func encodeSets(_ sets: [LanguageSet]) -> String {
    sets.map(\.stored).joined(separator: "\n")
}

/// The pair from Settings: the source and the primary and secondary targets.
func preferencesSet() -> LanguageSet {
    let values = getPreferenceValues()
    func text(_ name: String, _ fallback: String) -> String {
        if case .string(let value) = values[name], !value.isEmpty { return value }
        return fallback
    }
    return LanguageSet(from: text("langFrom", autoDetect), to: [text("lang1", "en"), text("lang2", "en")])
}

func preference(_ name: String) -> Bool {
    if case .bool(let value) = getPreferenceValues()[name] { return value }
    return name == "autoInput"
}

/// True when `next` is `previous` with one character typed or deleted: typing waits for a pause.
func isSingleCharacterEdit(_ previous: String, _ next: String) -> Bool {
    let before = Array(previous)
    let after = Array(next)
    guard abs(before.count - after.count) == 1 else { return false }
    let shorter = before.count < after.count ? before : after
    let longer = before.count < after.count ? after : before
    var i = 0
    var j = 0
    var skipped = 0
    while i < shorter.count && j < longer.count {
        if shorter[i] == longer[j] {
            i += 1
            j += 1
        } else {
            skipped += 1
            if skipped > 1 { return false }
            j += 1
        }
    }
    return true
}

/// The pause between keystrokes before a translation starts.
let debounceMilliseconds = 250

/// True when the Default Action preference puts Paste before Copy.
func pastesFirst() -> Bool {
    if case .string(let action) = getPreferenceValues()["defaultAction"] { return action == "paste" }
    return false
}
