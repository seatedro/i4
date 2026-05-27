import Common
import Foundation

@MainActor
final class TreeStore {
    static let shared = TreeStore()

    private var nextNodeId: UInt64 = 1
    private var nodeIdsByObjectId: [ObjectIdentifier: TreeNodeId] = [:]
    private(set) var current: TreeState = .empty

    private init() {}

    func refreshFromMutableTree(workspaces: [Workspace] = Workspace.all) {
        let signpostState = signposter.beginInterval(#function, "workspaces: \(workspaces.count)")
        defer { signposter.endInterval(#function, signpostState) }

        let export = TreeState.fromMutableTree(workspaces: workspaces, idForNode: id(for:))
        current = export.state
        nodeIdsByObjectId = nodeIdsByObjectId.filter { export.seenObjectIds.contains($0.key) }

        let violations = current.invariantViolations()
        check(
            violations.isEmpty,
            "Immutable tree shadow state invariant violations:\n\(violations.joined(separator: "\n"))",
        )
    }

    func allocateNodeId() -> TreeNodeId {
        let id = TreeNodeId(rawValue: nextNodeId)
        nextNodeId += 1
        return id
    }

    func commit(_ state: TreeState, materializeMutableTree: Bool = true) -> Bool {
        let violations = state.invariantViolations()
        check(
            violations.isEmpty,
            "Immutable tree committed with invariant violations:\n\(violations.joined(separator: "\n"))",
        )

        if materializeMutableTree {
            guard materialize(state) else { return false }
        }
        current = state
        nextNodeId = max(nextNodeId, (state.nodes.keys.map(\.rawValue).max() ?? 0) + 1)
        return true
    }

    func resetForTests() {
        nextNodeId = 1
        nodeIdsByObjectId = [:]
        current = .empty
    }

    private func id(for node: TreeNode) -> TreeNodeId {
        let objectId = ObjectIdentifier(node)
        if let existing = nodeIdsByObjectId[objectId] {
            return existing
        }
        let id = TreeNodeId(rawValue: nextNodeId)
        nextNodeId += 1
        nodeIdsByObjectId[objectId] = id
        return id
    }
}

extension TreeStore {
    private func materialize(_ state: TreeState) -> Bool {
        let existingNodesById = collectExistingNodesById()
        let windowsById = collectWindowsById()
        guard state.allWindowIds.allSatisfy({ windowsById[$0] != nil }) else {
            return false
        }

        detachMutableTree()

        var newNodeIdsByObjectId: [ObjectIdentifier: TreeNodeId] = [:]
        var materializedNodesById: [TreeNodeId: TreeNode] = [:]

        for workspaceId in state.workspaceIdsInOrder {
            guard case .workspace(let workspaceState) = state.nodes[workspaceId] else { return false }
            let workspace = Workspace.get(byName: workspaceState.name)
            remember(workspace, as: workspaceId, in: &newNodeIdsByObjectId, &materializedNodesById)
            for (index, childId) in workspaceState.childIds.enumerated() {
                guard materialize(
                    childId,
                    from: state,
                    parent: workspace,
                    index: index,
                    windowsById: windowsById,
                    existingNodesById: existingNodesById,
                    newNodeIdsByObjectId: &newNodeIdsByObjectId,
                    materializedNodesById: &materializedNodesById,
                ) else {
                    return false
                }
            }
        }

        for globalContainerId in state.globalContainerIdsInOrder {
            guard case .container(let containerState) = state.nodes[globalContainerId] else { return false }
            let container: NonLeafTreeNodeObject
            switch containerState.kind {
                case .macosMinimized:
                    container = macosMinimizedWindowsContainer
                case .macosPopup:
                    container = macosPopupWindowsContainer
                case .tiling, .macosFullscreen, .macosHiddenApps:
                    return false
            }
            remember(container, as: globalContainerId, in: &newNodeIdsByObjectId, &materializedNodesById)
            for (index, childId) in containerState.childIds.enumerated() {
                guard materialize(
                    childId,
                    from: state,
                    parent: container,
                    index: index,
                    windowsById: windowsById,
                    existingNodesById: existingNodesById,
                    newNodeIdsByObjectId: &newNodeIdsByObjectId,
                    materializedNodesById: &materializedNodesById,
                ) else {
                    return false
                }
            }
        }

        restoreMru(from: state, materializedNodesById: materializedNodesById)
        nodeIdsByObjectId = newNodeIdsByObjectId
        return true
    }

    private func materialize(
        _ nodeId: TreeNodeId,
        from state: TreeState,
        parent: NonLeafTreeNodeObject,
        index: Int,
        windowsById: [UInt32: Window],
        existingNodesById: [TreeNodeId: TreeNode],
        newNodeIdsByObjectId: inout [ObjectIdentifier: TreeNodeId],
        materializedNodesById: inout [TreeNodeId: TreeNode],
    ) -> Bool {
        guard let node = state.nodes[nodeId] else { return false }
        switch node {
            case .workspace:
                return false
            case .window(let windowState):
                guard let window = windowsById[windowState.windowId] else { return false }
                window.lastFloatingSize = windowState.lastFloatingSize
                window.isFullscreen = windowState.isFullscreen
                window.noOuterGapsInFullscreen = windowState.noOuterGapsInFullscreen
                window.layoutReason = LayoutReason(windowState.layoutReason)
                window.bind(to: parent, adaptiveWeight: windowState.adaptiveWeight, index: index)
                remember(window, as: windowState.id, in: &newNodeIdsByObjectId, &materializedNodesById)
                return true
            case .container(let containerState):
                guard let container = materializeContainer(
                    containerState,
                    parent: parent,
                    index: index,
                    existingNodesById: existingNodesById,
                ) else {
                    return false
                }
                remember(container, as: containerState.id, in: &newNodeIdsByObjectId, &materializedNodesById)
                for (childIndex, childId) in containerState.childIds.enumerated() {
                    guard materialize(
                        childId,
                        from: state,
                        parent: container,
                        index: childIndex,
                        windowsById: windowsById,
                        existingNodesById: existingNodesById,
                        newNodeIdsByObjectId: &newNodeIdsByObjectId,
                        materializedNodesById: &materializedNodesById,
                    ) else {
                        return false
                    }
                }
                return true
        }
    }

    private func materializeContainer(
        _ state: ContainerState,
        parent: NonLeafTreeNodeObject,
        index: Int,
        existingNodesById: [TreeNodeId: TreeNode],
    ) -> NonLeafTreeNodeObject? {
        switch state.kind {
            case .tiling:
                guard let orientation = state.orientation, let layout = state.layout else { return nil }
                if let existing = existingNodesById[state.id] as? TilingContainer {
                    existing.restoreTreeStateOrientation(orientation)
                    existing.layout = layout
                    existing.bind(to: parent, adaptiveWeight: state.adaptiveWeight, index: index)
                    return existing
                }
                return TilingContainer(
                    parent: parent,
                    adaptiveWeight: state.adaptiveWeight,
                    orientation,
                    layout,
                    index: index,
                )
            case .macosFullscreen:
                guard let workspace = parent as? Workspace else { return nil }
                if let existing = existingNodesById[state.id] as? MacosFullscreenWindowsContainer {
                    existing.bind(to: workspace, adaptiveWeight: state.adaptiveWeight, index: index)
                    return existing
                }
                let container = MacosFullscreenWindowsContainer(parent: workspace)
                container.bind(to: workspace, adaptiveWeight: state.adaptiveWeight, index: index)
                return container
            case .macosHiddenApps:
                guard let workspace = parent as? Workspace else { return nil }
                if let existing = existingNodesById[state.id] as? MacosHiddenAppsWindowsContainer {
                    existing.bind(to: workspace, adaptiveWeight: state.adaptiveWeight, index: index)
                    return existing
                }
                let container = MacosHiddenAppsWindowsContainer(parent: workspace)
                container.bind(to: workspace, adaptiveWeight: state.adaptiveWeight, index: index)
                return container
            case .macosMinimized, .macosPopup:
                return nil
        }
    }

    private func remember(
        _ node: TreeNode,
        as nodeId: TreeNodeId,
        in newNodeIdsByObjectId: inout [ObjectIdentifier: TreeNodeId],
        _ materializedNodesById: inout [TreeNodeId: TreeNode],
    ) {
        newNodeIdsByObjectId[ObjectIdentifier(node)] = nodeId
        materializedNodesById[nodeId] = node
    }

    private func collectExistingNodesById() -> [TreeNodeId: TreeNode] {
        var result: [TreeNodeId: TreeNode] = [:]
        for node in mutableTreeNodes() {
            if let nodeId = nodeIdsByObjectId[ObjectIdentifier(node)] {
                result[nodeId] = node
            }
        }
        return result
    }

    private func collectWindowsById() -> [UInt32: Window] {
        mutableTreeNodes()
            .compactMap { $0 as? Window }
            .grouped(by: \.windowId)
            .compactMapValues { $0.singleOrNil() }
    }

    private func mutableTreeNodes() -> [TreeNode] {
        var result: [TreeNode] = []
        func visit(_ node: TreeNode) {
            result.append(node)
            for child in node.children {
                visit(child)
            }
        }
        for workspace in Workspace.all {
            visit(workspace)
        }
        visit(macosMinimizedWindowsContainer)
        visit(macosPopupWindowsContainer)
        if !isUnitTest {
            for window in MacWindow.allWindows {
                if window.parent == nil {
                    result.append(window)
                }
            }
        }
        return result
    }

    private func detachMutableTree() {
        func detachChildren(of node: TreeNode) {
            for child in node.children {
                detachChildren(of: child)
                child.bind(to: NilTreeNode.instance, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)
            }
        }
        for workspace in Workspace.all {
            detachChildren(of: workspace)
        }
        detachChildren(of: macosMinimizedWindowsContainer)
        detachChildren(of: macosPopupWindowsContainer)
    }

    private func restoreMru(from state: TreeState, materializedNodesById: [TreeNodeId: TreeNode]) {
        let rootIds = state.workspaceIdsInOrder + state.globalContainerIdsInOrder
        for rootId in rootIds {
            restoreMru(from: state, nodeId: rootId, materializedNodesById: materializedNodesById)
        }
    }

    private func restoreMru(
        from state: TreeState,
        nodeId: TreeNodeId,
        materializedNodesById: [TreeNodeId: TreeNode],
    ) {
        guard let node = state.nodes[nodeId] else { return }
        for childId in node.childIds {
            restoreMru(from: state, nodeId: childId, materializedNodesById: materializedNodesById)
        }
        for childId in node.mruChildIds.reversed() {
            materializedNodesById[childId]?.markAsMostRecentChild()
        }
    }
}

extension TreeState {
    fileprivate var allWindowIds: [UInt32] {
        nodes.values.compactMap { node in
            if case .window(let window) = node {
                window.windowId
            } else {
                nil
            }
        }
    }
}

extension LayoutReason {
    fileprivate init(_ state: WindowLayoutReasonState) {
        self = switch state {
            case .standard: .standard
            case .macos(let prevParentKind): .macos(prevParentKind: prevParentKind)
        }
    }
}
