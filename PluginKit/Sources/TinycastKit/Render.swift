// The command's screen stack, and the render tree Tinycast draws: one `__screen` per stack entry,
// each node with an id that lasts from one render to the next, each handler with an id the host
// sends back.

/// One screen on the command's stack. A class, so the views it made keep their state.
@MainActor
final class _Entry {
    let render: () -> [_Element]
    var task: Task<Void, Never>?
    var taskKey: String?
    /// The `storeValue` fields this screen has given their saved values already.
    var restoredFields: Set<String> = []

    init(_ render: @escaping () -> [_Element]) {
        self.render = render
    }
}

@MainActor var _stack: [_Entry] = []
/// The screen being rendered, so a form field can restore its stored value once.
@MainActor var _rendering: _Entry?

@MainActor func _push(_ entry: _Entry) {
    _stack.append(entry)
    _invalidate()
}

@MainActor func _pop() -> Bool {
    guard _stack.count > 1 else { return false }
    _stack.removeLast().task?.cancel()
    _invalidate()
    return true
}

/// The top of the stack's root component; starts the screen's `task` the first time, or again
/// when its id changes.
@MainActor func _activeRoot() -> PluginNode? {
    guard let entry = _stack.last else { return nil }
    _rendering = entry
    let elements = entry.render()
    _rendering = nil
    for element in elements {
        if case .screen(let node, let task) = element {
            _start(task, in: entry)
            return node
        }
    }
    // A `body` of bare rows, with no `List` around them, still shows as one.
    let rows = elements.compactMap { element -> PluginNode? in
        if case .node(let node) = element { return node }
        return nil
    }
    return _node("List", children: _retype(rows, container: "List"))
}

@MainActor func _start(_ task: _Task?, in entry: _Entry) {
    guard let task, entry.taskKey != task.key else { return }
    entry.task?.cancel()
    entry.taskKey = task.key
    let run = task.run
    entry.task = Task { @MainActor in await run() }
}

/// The JSON Raycast's reconciler would send for the same screens; only the top one has content.
@MainActor func _tree() -> String {
    var writer = _TreeWriter()
    let depth = max(_stack.count, 1)
    let root = _activeRoot()
    writer.output = "{\"children\":["
    for level in 0..<depth {
        if level > 0 { writer.output += "," }
        let active = level == depth - 1
        writer.output += "{\"type\":\"__screen\",\"id\":\(level + 1),\"props\":{\"active\":\(active)},\"children\":["
        if active, let root { writer.write(root, path: "screen\(level)") }
        writer.output += "]}"
    }
    writer.output += "]}"
    _handlers = writer.handlers
    return writer.output
}

struct _TreeWriter {
    var output = ""
    var handlers: [String: _Handler] = [:]
    private var usedIDs: Set<Int> = []

    mutating func write(_ node: PluginNode, path: String) {
        let id = uniqueID(for: path)
        output += "{\"type\":"
        _writeString(node.type, to: &output)
        output += ",\"id\":\(id),\"props\":{"
        for (index, name) in node.props.keys.sorted().enumerated() {
            if index > 0 { output += "," }
            _writeString(name, to: &output)
            output += ":"
            write(node.props[name]!, path: path + "." + name, nodeID: id)
        }
        output += "},\"children\":["
        var counts: [String: Int] = [:]
        for (index, child) in node.children.enumerated() {
            if index > 0 { output += "," }
            let ordinal = counts[child.type, default: 0]
            counts[child.type] = ordinal + 1
            let key = child.key.map { "k:" + $0 } ?? "\(child.type)#\(ordinal)"
            write(child, path: path + "/" + key)
        }
        output += "]}"
    }

    private mutating func write(_ value: PluginValue, path: String, nodeID: Int) {
        switch value {
        case .node(let node): write(node, path: path)
        case .handler(let handler):
            let id = "\(nodeID):\(path)"
            handlers[id] = handler
            output += "{\"$fn\":"
            _writeString(id, to: &output)
            output += "}"
        case .array(let values):
            output += "["
            for (index, value) in values.enumerated() {
                if index > 0 { output += "," }
                write(value, path: path + "[\(index)]", nodeID: nodeID)
            }
            output += "]"
        case .object(let fields):
            output += "{"
            for (index, name) in fields.keys.sorted().enumerated() {
                if index > 0 { output += "," }
                _writeString(name, to: &output)
                output += ":"
                write(fields[name]!, path: path + "." + name, nodeID: nodeID)
            }
            output += "}"
        default:
            _write(value, to: &output)
        }
    }

    /// FNV-1a of the node's path, so a node keeps its id from one render to the next; a collision
    /// within one render steps to the next free id rather than share one. Screens sit below.
    private mutating func uniqueID(for path: String) -> Int {
        var hash: UInt32 = 2_166_136_261
        for byte in path.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        var id = Int(hash & 0x3fff_ffff) + 1024
        while !usedIDs.insert(id).inserted { id += 1 }
        return id
    }
}
