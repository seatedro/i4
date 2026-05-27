import Common

struct TreeDirectionalSibling: Equatable, Sendable {
    let parent: ContainerState
    let ownIndex: Int
}

extension TreeState {
    func windowNode(withWindowId windowId: UInt32) -> WindowState? {
        nodes.values.lazy.compactMap { node -> WindowState? in
            guard case .window(let window) = node, window.windowId == windowId else { return nil }
            return window
        }.first
    }

    func leafWindowsRecursive(from rootId: TreeNodeId) -> [WindowState] {
        guard let node = nodes[rootId] else { return [] }
        if case .window(let window) = node {
            return [window]
        }
        return node.childIds.flatMap { leafWindowsRecursive(from: $0) }
    }

    func rootTilingContainer(for workspaceId: TreeNodeId) -> ContainerState? {
        guard case .workspace(let workspace) = nodes[workspaceId] else { return nil }
        return workspace.childIds.lazy.compactMap { childId -> ContainerState? in
            guard case .container(let container) = nodes[childId], container.kind == .tiling else {
                return nil
            }
            return container
        }.first
    }

    func mostRecentWindowRecursive(from rootId: TreeNodeId) -> WindowState? {
        guard let node = nodes[rootId] else { return nil }
        if case .window(let window) = node {
            return window
        }
        return mostRecentChildId(of: rootId).flatMap { mostRecentWindowRecursive(from: $0) }
    }

    func findLeafWindow(from rootId: TreeNodeId, snappedTo direction: CardinalDirection) -> WindowState? {
        guard let node = nodes[rootId] else { return nil }
        switch node {
            case .workspace(let workspace):
                return rootTilingContainer(for: workspace.id)
                    .flatMap { findLeafWindow(from: $0.id, snappedTo: direction) }
            case .window(let window):
                return window
            case .container(let container):
                switch container.kind {
                    case .tiling:
                        guard let orientation = container.orientation else { return nil }
                        if direction.orientation == orientation {
                            return (direction.isPositive ? container.childIds.last : container.childIds.first)
                                .flatMap { findLeafWindow(from: $0, snappedTo: direction) }
                        } else {
                            return mostRecentChildId(of: container.id)
                                .flatMap { findLeafWindow(from: $0, snappedTo: direction) }
                        }
                    case .macosFullscreen, .macosHiddenApps, .macosMinimized, .macosPopup:
                        return nil
                }
        }
    }

    func closestParent(
        of nodeId: TreeNodeId,
        hasChildrenInDirection direction: CardinalDirection,
        withLayout layout: Layout?,
    ) -> TreeDirectionalSibling? {
        guard let cursor = cursor(to: nodeId) else { return nil }
        let path = cursor.path.nodeIds
        guard path.count >= 2 else { return nil }

        for index in stride(from: path.count - 1, through: 1, by: -1) {
            let childId = path[index]
            let parentId = path[index - 1]
            guard let parentNode = nodes[parentId] else { return nil }

            switch parentNode {
                case .container(let parent) where parent.kind == .tiling:
                    guard parent.orientation == direction.orientation,
                          layout == nil || parent.layout == layout,
                          let ownIndex = parent.childIds.firstIndex(of: childId)
                    else { continue }
                    if parent.childIds.indices.contains(ownIndex + direction.focusOffset) {
                        return TreeDirectionalSibling(parent: parent, ownIndex: ownIndex)
                    }
                case .workspace, .container, .window:
                    return nil
            }
        }
        return nil
    }

    func focusWindow(from nodeId: TreeNodeId, inDirection direction: CardinalDirection) -> WindowState? {
        guard let sibling = closestParent(of: nodeId, hasChildrenInDirection: direction, withLayout: nil) else {
            return nil
        }
        let siblingIndex = sibling.ownIndex + direction.focusOffset
        return sibling.parent.childIds.getOrNil(atIndex: siblingIndex)
            .flatMap { findLeafWindow(from: $0, snappedTo: direction.opposite) }
    }

    func markingAsMostRecent(_ nodeId: TreeNodeId) -> TreeState {
        guard let cursor = cursor(to: nodeId) else { return self }
        var result = self
        let path = cursor.path.nodeIds

        for index in stride(from: path.count - 1, through: 1, by: -1) {
            let childId = path[index]
            let parentId = path[index - 1]
            guard let parent = result.nodes[parentId] else { continue }
            result.nodes[parentId] = parent.withMruChild(childId)
        }

        return result
    }

    func mostRecentChildId(of nodeId: TreeNodeId) -> TreeNodeId? {
        guard let node = nodes[nodeId] else { return nil }
        let childIds = node.childIds
        guard !childIds.isEmpty else { return nil }
        let childSet = Set(childIds)
        return node.mruChildIds.first { childSet.contains($0) } ?? childIds.last
    }
}

extension TreeNodeState {
    fileprivate func withMruChild(_ childId: TreeNodeId) -> TreeNodeState {
        let mruChildIds = [childId] + self.mruChildIds.filter { $0 != childId }
        return switch self {
            case .workspace(let workspace):
                .workspace(WorkspaceState(
                    id: workspace.id,
                    name: workspace.name,
                    isVisible: workspace.isVisible,
                    isFocused: workspace.isFocused,
                    assignedMonitorTopLeft: workspace.assignedMonitorTopLeft,
                    forcedMonitorTopLeft: workspace.forcedMonitorTopLeft,
                    childIds: workspace.childIds,
                    mruChildIds: mruChildIds,
                ))
            case .container(let container):
                .container(ContainerState(
                    id: container.id,
                    kind: container.kind,
                    orientation: container.orientation,
                    layout: container.layout,
                    adaptiveWeight: container.adaptiveWeight,
                    childIds: container.childIds,
                    mruChildIds: mruChildIds,
                ))
            case .window:
                self
        }
    }
}
