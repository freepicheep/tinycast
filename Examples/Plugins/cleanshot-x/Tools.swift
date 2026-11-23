import Tinycast

/// One of CleanShot X's URL commands: `cleanshot://<command>`. See cleanshot.com/docs-api.
struct Tool {
    let command: String
    let title: String
    let subtitle: String
    let systemImage: String
    /// Takes `?action=`: what CleanShot does with the capture instead of its own default.
    var takesAfterCapture = false

    func url(after: AfterCapture? = nil) -> String {
        guard let after else { return "cleanshot://\(command)" }
        return "cleanshot://\(command)?action=\(after.rawValue)"
    }
}

enum AfterCapture: String, CaseIterable {
    case copy
    case save
    case annotate
    case upload
    case pin

    var title: String {
        switch self {
        case .copy: "Capture and Copy"
        case .save: "Capture and Save"
        case .annotate: "Capture and Annotate"
        case .upload: "Capture and Upload"
        case .pin: "Capture and Pin"
        }
    }
}

/// Settings tabs `cleanshot://open-settings?tab=` opens, in CleanShot's own order.
let settingsTabs = [
    ("general", "General"), ("wallpaper", "Wallpaper"), ("shortcuts", "Shortcuts"),
    ("quickaccess", "Quick Access"), ("recording", "Recording"), ("screenshots", "Screenshots"),
    ("annotate", "Annotate"), ("cloud", "Cloud"), ("advanced", "Advanced"), ("about", "About")
]

let captures = [
    Tool(command: "capture-area", title: "Capture Area", subtitle: "Select an area",
         systemImage: "rectangle.dashed", takesAfterCapture: true),
    Tool(command: "capture-fullscreen", title: "Capture Fullscreen", subtitle: "The whole screen",
         systemImage: "rectangle.inset.filled", takesAfterCapture: true),
    Tool(command: "capture-window", title: "Capture Window", subtitle: "One window",
         systemImage: "macwindow", takesAfterCapture: true),
    Tool(command: "capture-previous-area", title: "Capture Previous Area", subtitle: "The last area again",
         systemImage: "arrow.counterclockwise", takesAfterCapture: true),
    Tool(command: "self-timer", title: "Self-Timer", subtitle: "After a countdown",
         systemImage: "timer", takesAfterCapture: true),
    Tool(command: "all-in-one", title: "All-in-One", subtitle: "Capture, record or scroll",
         systemImage: "square.grid.2x2"),
    Tool(command: "scrolling-capture", title: "Scrolling Capture", subtitle: "A page as you scroll",
         systemImage: "arrow.up.and.down"),
    Tool(command: "capture-text", title: "Capture Text", subtitle: "Recognize text in an area",
         systemImage: "text.viewfinder")
]

let recording = [
    Tool(command: "record-screen", title: "Record Screen", subtitle: "A video or GIF",
         systemImage: "record.circle")
]

let editing = [
    Tool(command: "open-annotate", title: "Annotate", subtitle: "Open the editor",
         systemImage: "pencil.tip.crop.circle"),
    Tool(command: "open-from-clipboard", title: "Open from Clipboard", subtitle: "Annotate the copied image",
         systemImage: "doc.on.clipboard"),
    Tool(command: "pin", title: "Pin Screenshot", subtitle: "Float it above every window",
         systemImage: "pin"),
    Tool(command: "add-quick-access-overlay", title: "Add Quick Access Overlay", subtitle: "From a file",
         systemImage: "square.stack"),
    Tool(command: "restore-recently-closed", title: "Restore Recently Closed", subtitle: "The last overlay",
         systemImage: "arrow.uturn.backward"),
    Tool(command: "open-history", title: "Open History", subtitle: "Past captures",
         systemImage: "clock.arrow.circlepath")
]

let desktop = [
    Tool(command: "toggle-desktop-icons", title: "Toggle Desktop Icons", subtitle: "Hide or show them",
         systemImage: "eye"),
    Tool(command: "hide-desktop-icons", title: "Hide Desktop Icons", subtitle: "For a clean capture",
         systemImage: "eye.slash"),
    Tool(command: "show-desktop-icons", title: "Show Desktop Icons", subtitle: "Bring them back",
         systemImage: "eye")
]
