import PluginDescription

let plugin = Plugin(
    name: "cleanshot-x",
    title: "CleanShot X",
    description: "Capture, record, annotate and pin with CleanShot X.",
    icon: "camera.viewfinder",
    author: "Tinycast",
    permissions: [.openURLs(schemes: ["cleanshot"])],
    commands: [
        .view(
            "cleanshot", title: "CleanShot X", subtitle: "Every capture and tool", icon: "camera.viewfinder",
            keywords: ["screenshot", "capture", "record"]),
        .action(
            "capture-area", title: "Capture Area", icon: "rectangle.dashed",
            keywords: ["screenshot", "region"]),
        .action(
            "capture-fullscreen", title: "Capture Fullscreen", icon: "rectangle.inset.filled",
            keywords: ["screenshot"]),
        .action("capture-window", title: "Capture Window", icon: "macwindow", keywords: ["screenshot"]),
        .action(
            "capture-previous-area", title: "Capture Previous Area", icon: "arrow.counterclockwise",
            keywords: ["screenshot", "again"]),
        .action("self-timer", title: "Self-Timer", icon: "timer", keywords: ["screenshot", "delay"]),
        .action(
            "all-in-one", title: "All-in-One", icon: "square.grid.2x2",
            keywords: ["screenshot", "record"]),
        .action(
            "scrolling-capture", title: "Scrolling Capture", icon: "arrow.up.and.down",
            keywords: ["screenshot", "long"]),
        .action(
            "record-screen", title: "Record Screen", icon: "record.circle",
            keywords: ["video", "gif", "recording"]),
        .action(
            "capture-text", title: "Capture Text", icon: "text.viewfinder",
            keywords: ["ocr", "text recognition"]),
        .action(
            "open-annotate", title: "Annotate", icon: "pencil.tip.crop.circle",
            keywords: ["edit", "markup"]),
        .action(
            "open-from-clipboard", title: "Open from Clipboard", icon: "doc.on.clipboard",
            keywords: ["paste", "image"]),
        .action("pin", title: "Pin Screenshot", icon: "pin", keywords: ["float"]),
        .action(
            "add-quick-access-overlay", title: "Add Quick Access Overlay", icon: "square.stack",
            keywords: ["overlay"]),
        .action(
            "restore-recently-closed", title: "Restore Recently Closed", icon: "arrow.uturn.backward",
            keywords: ["undo"]),
        .action("open-history", title: "Open History", icon: "clock.arrow.circlepath", keywords: ["recent"]),
        .action(
            "toggle-desktop-icons", title: "Toggle Desktop Icons", icon: "eye",
            keywords: ["clean desktop"]),
        .action(
            "hide-desktop-icons", title: "Hide Desktop Icons", icon: "eye.slash",
            keywords: ["clean desktop"]),
        .action("show-desktop-icons", title: "Show Desktop Icons", icon: "eye", keywords: ["desktop"]),
        .action(
            "open-settings", title: "Open CleanShot Settings", icon: "gearshape",
            keywords: ["preferences"]),
    ]
)
