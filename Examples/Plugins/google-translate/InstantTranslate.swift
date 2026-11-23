import Foundation
import Selection
import Tinycast

/// Selected text into the preferences' languages, handed to `done`; HUDs say what happened.
func instantTranslate(_ done: (String) async -> Void) async {
    let selection = (try? await selectedText()) ?? ""
    guard !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        showHUD("No text selected. Please select text to translate.")
        return
    }
    showHUD("Translating...")
    do {
        let result = try await simpleTranslate(selection, preferencesSet())
        guard !result.translatedText.isEmpty else {
            showHUD("Translation failed. Please try again.")
            return
        }
        await done(result.translatedText)
    } catch {
        print("Translation error: \(error)")
        showHUD("Translation failed. Please try again.")
    }
}

/// A HUD kept up long enough to read: 150 ms a character, two seconds to fifteen.
func showExtendedHUD(_ message: String) async {
    showHUD(message)
    let duration = min(max(2000, message.count * 150), 15_000)
    for _ in 0..<(duration / 1000) {
        try? await Task.sleep(for: .seconds(1))
        showHUD(message)
    }
}
