import Tinycast

Plugin.command("translate") { Translate() }
Plugin.command("translate-form") { TranslateForm() }
Plugin.action("quick-translate") { try await quickTranslate() }
Plugin.command("quick-translate-view") { QuickTranslateResults() }
Plugin.action("instant-translate-copy") {
    await instantTranslate { translation in
        Clipboard.copy(translation)
        showHUD("✓ Copied To Clipboard")
    }
}
Plugin.action("instant-translate-paste") {
    await instantTranslate { translation in Clipboard.paste(translation) }
}
Plugin.action("instant-translate-view") {
    await instantTranslate { translation in await showExtendedHUD(translation) }
}
