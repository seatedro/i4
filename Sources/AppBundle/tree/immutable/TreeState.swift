import AppKit
import Common

struct TreeNodeId: Hashable, Sendable, CustomStringConvertible {
    let rawValue: UInt64

    var description: String { "#\(rawValue)" }
}

struct TreeNodeRef: Hashable, Sendable {
    let id: TreeNodeId
}

struct TreePath: Equatable, Sendable {
    let nodeIds: [TreeNodeId]

    var parent: TreeNodeRef? {
        guard nodeIds.count >= 2 else { return nil }
        return TreeNodeRef(id: nodeIds[nodeIds.count - 2])
    }
}

struct TreeCursor: Equatable, Sendable {
    let ref: TreeNodeRef
    let path: TreePath

    var parent: TreeNodeRef? { path.parent }
}

struct TreeState: Equatable, Sendable {
    var nodes: [TreeNodeId: TreeNodeState]
    var workspaceIdsInOrder: [TreeNodeId]
    var globalContainerIdsInOrder: [TreeNodeId]
    var focusedWorkspaceId: TreeNodeId?
    var focusedWindowNodeId: TreeNodeId?

    static let empty = TreeState(
        nodes: [:],
        workspaceIdsInOrder: [],
        globalContainerIdsInOrder: [],
        focusedWorkspaceId: nil,
        focusedWindowNodeId: nil,
    )
}

enum TreeNodeState: Equatable, Sendable {
    case workspace(WorkspaceState)
    case container(ContainerState)
    case window(WindowState)

    var childIds: [TreeNodeId] {
        switch self {
            case .workspace(let state): state.childIds
            case .container(let state): state.childIds
            case .window: []
        }
    }

    var mruChildIds: [TreeNodeId] {
        switch self {
            case .workspace(let state): state.mruChildIds
            case .container(let state): state.mruChildIds
            case .window: []
        }
    }
}

struct WorkspaceState: Equatable, Sendable {
    let id: TreeNodeId
    let name: String
    let isVisible: Bool
    let isFocused: Bool
    let assignedMonitorTopLeft: CGPoint?
    let forcedMonitorTopLeft: CGPoint?
    let childIds: [TreeNodeId]
    let mruChildIds: [TreeNodeId]
}

struct ContainerState: Equatable, Sendable {
    let id: TreeNodeId
    let kind: ContainerKind
    let orientation: Orientation?
    let layout: Layout?
    let adaptiveWeight: CGFloat
    let childIds: [TreeNodeId]
    let mruChildIds: [TreeNodeId]
}

struct WindowState: Equatable, Sendable {
    let id: TreeNodeId
    let windowId: UInt32
    let appPid: Int32
    let appBundleId: String?
    let adaptiveWeight: CGFloat
    let lastFloatingSize: CGSize?
    let isFullscreen: Bool
    let noOuterGapsInFullscreen: Bool
    let layoutReason: WindowLayoutReasonState
}

enum ContainerKind: String, Equatable, Sendable {
    case tiling
    case macosFullscreen
    case macosHiddenApps
    case macosMinimized
    case macosPopup
}

enum WindowLayoutReasonState: Equatable, Sendable {
    case standard
    case macos(prevParentKind: NonLeafTreeNodeKind)
}

enum TreeLayoutDescription: Equatable, Sendable {
    case workspace([TreeLayoutDescription])
    case hTiles([TreeLayoutDescription])
    case vTiles([TreeLayoutDescription])
    case hAccordion([TreeLayoutDescription])
    case vAccordion([TreeLayoutDescription])
    case window(UInt32)
    case macosPopupWindowsContainer([TreeLayoutDescription])
    case macosMinimized([TreeLayoutDescription])
    case macosHiddenApps([TreeLayoutDescription])
    case macosFullscreen([TreeLayoutDescription])
}

extension TreeState {
    var rootIdsInOrder: [TreeNodeId] { workspaceIdsInOrder + globalContainerIdsInOrder }

    func workspace(named name: String) -> WorkspaceState? {
        workspaceIdsInOrder.lazy
            .compactMap { nodes[$0] }
            .compactMap {
                if case .workspace(let workspace) = $0 { workspace } else { nil }
            }
            .first { $0.name == name }
    }

    func cursor(to target: TreeNodeId) -> TreeCursor? {
        for rootId in rootIdsInOrder {
            if let cursor = cursor(to: target, at: rootId, path: []) {
                return cursor
            }
        }
        return nil
    }

    func layoutDescription(for id: TreeNodeId) -> TreeLayoutDescription? {
        guard let node = nodes[id] else { return nil }
        let children = node.childIds.compactMap { layoutDescription(for: $0) }
        return switch node {
            case .workspace: .workspace(children)
            case .window(let window): .window(window.windowId)
            case .container(let container):
                switch container.kind {
                    case .tiling:
                        switch (container.layout, container.orientation) {
                            case (.accordion, .h): .hAccordion(children)
                            case (.accordion, .v): .vAccordion(children)
                            case (.tiles, .h): .hTiles(children)
                            case (.tiles, .v): .vTiles(children)
                            default: nil
                        }
                    case .macosFullscreen: .macosFullscreen(children)
                    case .macosHiddenApps: .macosHiddenApps(children)
                    case .macosMinimized: .macosMinimized(children)
                    case .macosPopup: .macosPopupWindowsContainer(children)
                }
        }
    }

    func invariantViolations() -> [String] {
        var result: [String] = []
        var visited: Set<TreeNodeId> = []
        var visiting: Set<TreeNodeId> = []
        var windowIds: Set<UInt32> = []

        for workspaceId in workspaceIdsInOrder {
            guard case .workspace = nodes[workspaceId] else {
                result.append("workspace root \(workspaceId) is not a workspace node")
                continue
            }
        }
        for globalId in globalContainerIdsInOrder {
            guard case .container = nodes[globalId] else {
                result.append("global root \(globalId) is not a container node")
                continue
            }
        }

        func visit(_ id: TreeNodeId, _ path: [TreeNodeId]) {
            guard let node = nodes[id] else {
                result.append("missing node \(id) referenced from \(path.last.map(String.init(describing:)) ?? "root")")
                return
            }
            if visiting.contains(id) {
                result.append("cycle detected at \(id)")
                return
            }
            if visited.contains(id) {
                result.append("node \(id) is reachable from multiple parents")
                return
            }
            visiting.insert(id)
            defer {
                visiting.remove(id)
                visited.insert(id)
            }

            let childSet = Set(node.childIds)
            if childSet.count != node.childIds.count {
                result.append("node \(id) contains duplicate child ids")
            }
            for mruChildId in node.mruChildIds where !childSet.contains(mruChildId) {
                result.append("node \(id) contains MRU child \(mruChildId) that is not a child")
            }
            if case .window(let window) = node, !windowIds.insert(window.windowId).inserted {
                result.append("window id \(window.windowId) appears more than once")
            }
            if case .workspace(let workspace) = node {
                let rootContainers = workspace.childIds.compactMap { childId -> ContainerState? in
                    guard case .container(let container) = nodes[childId], container.kind == .tiling else { return nil }
                    return container
                }
                if rootContainers.count > 1 {
                    result.append("workspace \(workspace.name) has more than one root tiling container")
                }
            }
            for childId in node.childIds {
                visit(childId, path + [id])
            }
        }

        for rootId in rootIdsInOrder {
            visit(rootId, [])
        }
        for nodeId in nodes.keys where !visited.contains(nodeId) {
            result.append("node \(nodeId) is unreachable")
        }
        if let focusedWorkspaceId, !workspaceIdsInOrder.contains(focusedWorkspaceId) {
            result.append("focused workspace \(focusedWorkspaceId) is not a workspace root")
        }
        if let focusedWindowNodeId {
            guard case .window = nodes[focusedWindowNodeId] else {
                result.append("focused window \(focusedWindowNodeId) is not a window node")
                return result
            }
            if !visited.contains(focusedWindowNodeId) {
                result.append("focused window \(focusedWindowNodeId) is unreachable")
            }
        }
        return result
    }

    private func cursor(to target: TreeNodeId, at current: TreeNodeId, path: [TreeNodeId]) -> TreeCursor? {
        guard let node = nodes[current] else { return nil }
        let path = path + [current]
        if current == target {
            return TreeCursor(ref: TreeNodeRef(id: current), path: TreePath(nodeIds: path))
        }
        for childId in node.childIds {
            if let cursor = cursor(to: target, at: childId, path: path) {
                return cursor
            }
        }
        return nil
    }
}

extension TreeLayoutDescription {
    @MainActor
    static func fromMutableNode(_ node: TreeNode) -> TreeLayoutDescription {
        let children = node.children.map(TreeLayoutDescription.fromMutableNode)
        return switch node.nodeCases {
            case .window(let window): .window(window.windowId)
            case .workspace: .workspace(children)
            case .macosMinimizedWindowsContainer: .macosMinimized(children)
            case .macosFullscreenWindowsContainer: .macosFullscreen(children)
            case .macosHiddenAppsWindowsContainer: .macosHiddenApps(children)
            case .macosPopupWindowsContainer: .macosPopupWindowsContainer(children)
            case .tilingContainer(let container):
                switch container.layout {
                    case .tiles:
                        container.orientation == .h ? .hTiles(children) : .vTiles(children)
                    case .accordion:
                        container.orientation == .h ? .hAccordion(children) : .vAccordion(children)
                }
        }
    }
}
