import Foundation

/// Turns the kit's typed nodes into the tree the Extensions renderer draws, and keeps the handlers
/// of the newest render, so a dispatch reaches the closure that render held.
@MainActor
struct PluginRenderer {
    typealias Handler = ([PluginValue]) throws -> Void

    private(set) var handlers: [String: Handler] = [:]
    private var usedIDs: Set<Int> = []

    /// One `__screen` per stack entry, as the JavaScript runtime renders them; only the top one is
    /// drawn, so the screens below it carry no content.
    mutating func tree(root: PluginNode?, depth: Int) -> RenderTree {
        handlers = [:]
        usedIDs = []
        var screens: [RenderNode] = []
        for level in 0..<max(depth - 1, 0) {
            screens.append(
                RenderNode(id: Self.screenID(level), type: "__screen", props: ["active": .bool(false)]))
        }
        let level = max(depth - 1, 0)
        let content = root.map { [convert($0, path: "screen\(level)")] } ?? []
        screens.append(
            RenderNode(
                id: Self.screenID(level), type: "__screen", props: ["active": .bool(true)],
                children: content))
        return RenderTree(screens: screens)
    }

    /// Screens sit below every hashed id, so neither can take the other's.
    private static func screenID(_ level: Int) -> Int { level + 1 }

    private mutating func convert(_ node: PluginNode, path: String) -> RenderNode {
        let id = uniqueID(for: path)
        var props: [String: RenderValue] = [:]
        for (name, value) in node.props {
            props[name] = convert(value, path: path + "." + name, nodeID: id)
        }
        var counts: [String: Int] = [:]
        var children: [RenderNode] = []
        for child in node.children {
            let index = counts[child.type, default: 0]
            counts[child.type] = index + 1
            let key = child.key.map { "k:" + $0 } ?? "\(child.type)#\(index)"
            children.append(convert(child, path: path + "/" + key))
        }
        return RenderNode(id: id, type: node.type, props: props, children: children)
    }

    private mutating func convert(_ value: PluginValue, path: String, nodeID: Int) -> RenderValue {
        switch value {
        case .string(let text): return .string(text)
        case .number(let number): return .number(number)
        case .bool(let flag): return .bool(flag)
        case .date(let seconds): return .date(Date(timeIntervalSince1970: seconds))
        case .null: return .null
        case .node(let node): return .node(convert(node, path: path))
        case .array(let values):
            return .array(
                values.enumerated().map { convert($1, path: path + "[\($0)]", nodeID: nodeID) })
        case .object(let fields):
            var converted: [String: RenderValue] = [:]
            for (name, field) in fields {
                converted[name] = convert(field, path: path + "." + name, nodeID: nodeID)
            }
            return .object(converted)
        case .handler(let handler):
            let id = "\(nodeID):\(path)"
            handlers[id] = handler
            return .handler(id)
        }
    }

    /// FNV-1a of the node's path, so a node keeps its id from one render to the next; a collision
    /// within one render steps to the next free id rather than share one.
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

    /// A handler's arguments as the palette sends them: a JSON array.
    static func arguments(fromJSON json: String) -> [PluginValue] {
        RenderValue.arguments(from: json).map(PluginValue.init)
    }
}

extension PluginValue {
    /// What a host answer or an argument becomes in a script; a node or handler never comes back.
    init(_ value: RenderValue) {
        switch value {
        case .string(let text): self = .string(text)
        case .number(let number): self = .number(number)
        case .bool(let flag): self = .bool(flag)
        case .date(let date): self = .date(date.timeIntervalSince1970)
        case .array(let values): self = .array(values.map(PluginValue.init))
        case .object(let fields): self = .object(fields.mapValues(PluginValue.init))
        case .handler, .node, .null: self = .null
        }
    }

    /// The other way, for values a script hands to a host API; a handler can't cross it.
    var renderValue: RenderValue {
        switch self {
        case .string(let text): .string(text)
        case .number(let number): .number(number)
        case .bool(let flag): .bool(flag)
        case .date(let seconds): .date(Date(timeIntervalSince1970: seconds))
        case .array(let values): .array(values.map(\.renderValue))
        case .object(let fields): .object(fields.mapValues(\.renderValue))
        case .node, .handler, .null: .null
        }
    }
}
