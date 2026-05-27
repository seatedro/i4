import AppKit
import Common

struct TreeBindingState: Equatable, Sendable {
    let parentId: TreeNodeId
    let adaptiveWeight: CGFloat
    let index: Int
}

extension TreeState {
    func flatteningWorkspace(_ workspaceId: TreeNodeId) -> TreeState? {
        guard let rootId = rootTilingContainer(for: workspaceId)?.id else { return nil }
        let windows = leafWindowsRecursive(from: rootId)
        var result = self
        for window in windows {
            guard result.insert(window.id, to: rootId, adaptiveWeight: 1, index: INDEX_BIND_LAST) else {
                return nil
            }
        }
        return result
    }

    func balancingWorkspace(_ workspaceId: TreeNodeId) -> TreeState? {
        guard let rootId = rootTilingContainer(for: workspaceId)?.id else { return nil }
        var result = self
        result.balance(containerId: rootId)
        return result
    }

    func movingWindowToWorkspace(
        _ windowId: TreeNodeId,
        targetWorkspaceId: TreeNodeId,
        index: Int = INDEX_BIND_LAST,
    ) -> TreeState? {
        guard case .window = nodes[windowId],
              let currentWorkspaceId = workspaceId(containing: windowId)
        else { return nil }
        if currentWorkspaceId == targetWorkspaceId {
            return self
        }

        let targetParentId: TreeNodeId
        if parentIsWorkspace(windowId) {
            targetParentId = targetWorkspaceId
        } else {
            guard let rootId = rootTilingContainer(for: targetWorkspaceId)?.id else { return nil }
            targetParentId = rootId
        }

        var result = self
        guard result.insert(windowId, to: targetParentId, adaptiveWeight: WEIGHT_AUTO, index: index) else {
            return nil
        }
        return result
    }

    func floatingWindow(_ windowId: TreeNodeId, workspaceId: TreeNodeId) -> TreeState? {
        guard case .window = nodes[windowId],
              case .workspace = nodes[workspaceId]
        else { return nil }

        var result = self
        guard result.insert(windowId, to: workspaceId, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST) else {
            return nil
        }
        return result
    }

    func tilingWindow(_ windowId: TreeNodeId, workspaceId: TreeNodeId) -> TreeState? {
        guard case .window = nodes[windowId],
              case .workspace = nodes[workspaceId],
              let rootId = rootTilingContainer(for: workspaceId)?.id
        else { return nil }

        var result = self
        guard result.removeFromParent(windowId) != nil else { return nil }
        let insertion: (parentId: TreeNodeId, index: Int) = if let mruWindow = result.mostRecentWindowRecursive(from: workspaceId),
                                                               let mruParentId = result.parentId(of: mruWindow.id),
                                                               case .container(let mruParent) = result.nodes[mruParentId],
                                                               mruParent.kind == .tiling,
                                                               let mruIndex = mruParent.childIds.firstIndex(of: mruWindow.id)
        {
            (mruParentId, mruIndex + 1)
        } else {
            (rootId, INDEX_BIND_LAST)
        }
        guard result.insert(windowId, to: insertion.parentId, adaptiveWeight: WEIGHT_AUTO, index: insertion.index) else {
            return nil
        }
        return result
    }

    func changingTilingLayout(
        of windowId: TreeNodeId,
        targetLayout: Layout?,
        targetOrientation: Orientation?,
        normalizeOppositeOrientationForNestedContainers: Bool,
    ) -> TreeState? {
        guard case .window = nodes[windowId],
              let parentId = parentId(of: windowId),
              case .container(let parent) = nodes[parentId],
              parent.kind == .tiling
        else { return nil }

        var result = self
        result.nodes[parentId] = .container(ContainerState(
            id: parent.id,
            kind: parent.kind,
            orientation: parent.orientation,
            layout: targetLayout ?? parent.layout,
            adaptiveWeight: parent.adaptiveWeight,
            childIds: parent.childIds,
            mruChildIds: parent.mruChildIds,
        ))
        guard let targetOrientation else { return result }
        return result.changingContainerOrientation(
            parentId,
            to: targetOrientation,
            normalizeOppositeOrientationForNestedContainers: normalizeOppositeOrientationForNestedContainers,
        )
    }

    func movingWindow(
        _ windowId: TreeNodeId,
        direction: CardinalDirection,
        boundariesAction: MoveCmdArgs.WhenBoundariesCrossed,
        implicitContainerId: TreeNodeId,
    ) -> TreeState? {
        guard case .window = nodes[windowId],
              let parentId = parentId(of: windowId),
              let parentNode = nodes[parentId]
        else { return nil }

        switch parentNode {
            case .container(let parent) where parent.kind == .tiling:
                guard let orientation = parent.orientation,
                      let indexOfCurrent = parent.childIds.firstIndex(of: windowId)
                else { return nil }
                let indexOfSiblingTarget = indexOfCurrent + direction.focusOffset
                if orientation == direction.orientation && parent.childIds.indices.contains(indexOfSiblingTarget) {
                    let siblingId = parent.childIds[indexOfSiblingTarget]
                    if isTilingContainer(siblingId) {
                        return deepMovingWindow(windowId, into: siblingId, moveDirection: direction)
                    } else {
                        var result = self
                        guard let binding = result.removeFromParent(windowId) else { return nil }
                        guard result.insert(windowId, to: parentId, adaptiveWeight: binding.adaptiveWeight, index: indexOfSiblingTarget) else {
                            return nil
                        }
                        return result
                    }
                }
                return movingWindowOut(
                    windowId,
                    direction: direction,
                    boundariesAction: boundariesAction,
                    implicitContainerId: implicitContainerId,
                )
            case .workspace, .container, .window:
                return nil
        }
    }

    func swappingWindows(_ lhs: TreeNodeId, _ rhs: TreeNodeId) -> TreeState? {
        if lhs == rhs { return self }
        var result = self
        guard let lhsBinding = result.removeFromParent(lhs) else { return nil }
        guard let rhsBinding = result.removeFromParent(rhs) else { return nil }
        guard result.insert(lhs, to: rhsBinding.parentId, adaptiveWeight: rhsBinding.adaptiveWeight, index: rhsBinding.index) else {
            return nil
        }
        guard result.insert(rhs, to: lhsBinding.parentId, adaptiveWeight: lhsBinding.adaptiveWeight, index: lhsBinding.index) else {
            return nil
        }
        return result
    }

    func splittingWindow(
        _ windowId: TreeNodeId,
        orientation: Orientation,
        newContainerId: TreeNodeId,
        normalizeOppositeOrientationForNestedContainers: Bool,
    ) -> TreeState? {
        guard case .window = nodes[windowId],
              let parentId = parentId(of: windowId),
              case .container(let parent) = nodes[parentId],
              parent.kind == .tiling
        else { return nil }

        if parent.childIds.count == 1 {
            return changingContainerOrientation(
                parentId,
                to: orientation,
                normalizeOppositeOrientationForNestedContainers: normalizeOppositeOrientationForNestedContainers,
            )
        }

        var result = self
        guard let binding = result.removeFromParent(windowId) else { return nil }
        let newContainer = ContainerState(
            id: newContainerId,
            kind: .tiling,
            orientation: orientation,
            layout: .tiles,
            adaptiveWeight: binding.adaptiveWeight,
            childIds: [],
            mruChildIds: [],
        )
        result.nodes[newContainerId] = .container(newContainer)
        guard result.insert(newContainerId, to: parentId, adaptiveWeight: binding.adaptiveWeight, index: binding.index) else {
            return nil
        }
        guard result.insert(windowId, to: newContainerId, adaptiveWeight: WEIGHT_AUTO, index: 0) else {
            return nil
        }
        return result
    }

    func joiningWindowWithSibling(
        _ windowId: TreeNodeId,
        direction: CardinalDirection,
        newContainerId: TreeNodeId,
    ) -> TreeState? {
        guard case .window = nodes[windowId],
              let sibling = closestParent(of: windowId, hasChildrenInDirection: direction, withLayout: nil)
        else { return nil }

        let joinWithTargetId = sibling.parent.childIds[sibling.ownIndex + direction.focusOffset]
        var result = self
        guard let targetBinding = result.removeFromParent(joinWithTargetId) else { return nil }
        let newContainer = ContainerState(
            id: newContainerId,
            kind: .tiling,
            orientation: sibling.parent.orientation?.opposite,
            layout: .tiles,
            adaptiveWeight: targetBinding.adaptiveWeight,
            childIds: [],
            mruChildIds: [],
        )
        result.nodes[newContainerId] = .container(newContainer)
        guard result.insert(newContainerId, to: targetBinding.parentId, adaptiveWeight: targetBinding.adaptiveWeight, index: targetBinding.index) else {
            return nil
        }
        guard result.removeFromParent(windowId) != nil else { return nil }
        guard result.insert(joinWithTargetId, to: newContainerId, adaptiveWeight: WEIGHT_AUTO, index: 0) else {
            return nil
        }
        let currentWindowIndex = direction.isPositive ? 0 : INDEX_BIND_LAST
        guard result.insert(windowId, to: newContainerId, adaptiveWeight: WEIGHT_AUTO, index: currentWindowIndex) else {
            return nil
        }
        return result
    }

    func changingContainerOrientation(
        _ containerId: TreeNodeId,
        to targetOrientation: Orientation,
        normalizeOppositeOrientationForNestedContainers: Bool,
    ) -> TreeState? {
        guard case .container(let container) = nodes[containerId], container.kind == .tiling else {
            return nil
        }
        if container.orientation == targetOrientation {
            return self
        }

        var result = self
        if normalizeOppositeOrientationForNestedContainers {
            var orientation = targetOrientation
            let path = cursor(to: containerId)?.path.nodeIds.reversed() ?? []
            for nodeId in path {
                guard case .container(let state) = result.nodes[nodeId], state.kind == .tiling else { continue }
                result.nodes[nodeId] = .container(ContainerState(
                    id: state.id,
                    kind: state.kind,
                    orientation: orientation,
                    layout: state.layout,
                    adaptiveWeight: state.adaptiveWeight,
                    childIds: state.childIds,
                    mruChildIds: state.mruChildIds,
                ))
                orientation = orientation.opposite
            }
        } else {
            result.nodes[containerId] = .container(ContainerState(
                id: container.id,
                kind: container.kind,
                orientation: targetOrientation,
                layout: container.layout,
                adaptiveWeight: container.adaptiveWeight,
                childIds: container.childIds,
                mruChildIds: container.mruChildIds,
            ))
        }
        return result
    }

    func parentId(of nodeId: TreeNodeId) -> TreeNodeId? {
        cursor(to: nodeId)?.parent?.id
    }

    func workspaceId(containing nodeId: TreeNodeId) -> TreeNodeId? {
        cursor(to: nodeId)?.path.nodeIds.first { id in
            if case .workspace = nodes[id] { true } else { false }
        }
    }

    func binding(of nodeId: TreeNodeId) -> TreeBindingState? {
        guard let parentId = parentId(of: nodeId),
              let index = nodes[parentId]?.childIds.firstIndex(of: nodeId),
              let node = nodes[nodeId]
        else { return nil }
        return TreeBindingState(parentId: parentId, adaptiveWeight: node.adaptiveWeight, index: index)
    }

    private mutating func removeFromParent(_ nodeId: TreeNodeId) -> TreeBindingState? {
        guard let binding = binding(of: nodeId), let parent = nodes[binding.parentId] else { return nil }
        var childIds = parent.childIds
        guard childIds.remove(element: nodeId) != nil else { return nil }
        let mruChildIds = parent.mruChildIds.filter { $0 != nodeId }
        nodes[binding.parentId] = parent.withChildren(childIds, mruChildIds: mruChildIds)
        return binding
    }

    private mutating func insert(
        _ nodeId: TreeNodeId,
        to parentId: TreeNodeId,
        adaptiveWeight: CGFloat,
        index: Int,
    ) -> Bool {
        guard let parent = nodes[parentId], nodes[nodeId] != nil else { return false }
        let relation = parent.childRelation(for: nodes[nodeId].orDie())
        guard relation.isValid else { return false }

        if self.parentId(of: nodeId) != nil {
            _ = removeFromParent(nodeId)
        }
        let resolvedWeight = resolvedAdaptiveWeight(adaptiveWeight, forChildOf: parentId)
        nodes[nodeId] = nodes[nodeId].orDie().withAdaptiveWeight(resolvedWeight)

        guard let parent = nodes[parentId] else { return false }
        var childIds = parent.childIds
        let insertionIndex = index == INDEX_BIND_LAST ? childIds.count : index
        guard (0 ... childIds.count).contains(insertionIndex) else { return false }
        childIds.insert(nodeId, at: insertionIndex)
        nodes[parentId] = parent.withChildren(childIds, mruChildIds: parent.mruChildIds)
        self = markingAsMostRecent(nodeId)
        return true
    }

    private func resolvedAdaptiveWeight(_ adaptiveWeight: CGFloat, forChildOf parentId: TreeNodeId) -> CGFloat {
        guard adaptiveWeight == WEIGHT_AUTO else { return adaptiveWeight }
        guard case .container(let parent) = nodes[parentId], parent.kind == .tiling, let orientation = parent.orientation else {
            return WEIGHT_DOESNT_MATTER
        }
        return CGFloat(parent.childIds.sumOfDouble { weight(of: $0, orientation: orientation) }).div(parent.childIds.count) ?? 1
    }

    private func weight(of nodeId: TreeNodeId, orientation: Orientation) -> CGFloat {
        guard let node = nodes[nodeId] else { return 1 }
        guard let parentId = parentId(of: nodeId) else { return node.adaptiveWeight }
        if case .container(let parent) = nodes[parentId], parent.kind == .tiling, parent.orientation == orientation {
            return node.adaptiveWeight
        }
        return weight(of: parentId, orientation: orientation)
    }

    private func movingWindowOut(
        _ windowId: TreeNodeId,
        direction: CardinalDirection,
        boundariesAction: MoveCmdArgs.WhenBoundariesCrossed,
        implicitContainerId: TreeNodeId,
    ) -> TreeState? {
        guard let path = cursor(to: windowId)?.path.nodeIds, path.count >= 2 else { return nil }
        let ancestorIds = path.dropLast().reversed()
        guard let innerMostChildId = ancestorIds.first(where: { ancestorId in
            guard let parentId = parentId(of: ancestorId), let parent = nodes[parentId] else { return true }
            switch parent {
                case .container(let parent) where parent.kind == .tiling:
                    return parent.orientation == direction.orientation
                case .workspace, .container, .window:
                    return true
            }
        }) else { return nil }
        guard let parentId = parentId(of: innerMostChildId), let parent = nodes[parentId] else { return nil }

        switch parent {
            case .container(let parent) where parent.kind == .tiling:
                guard parent.orientation == direction.orientation,
                      let ownIndex = parent.childIds.firstIndex(of: innerMostChildId)
                else { return nil }
                var result = self
                guard result.insert(windowId, to: parentId, adaptiveWeight: WEIGHT_AUTO, index: ownIndex + direction.insertionOffset) else {
                    return nil
                }
                return result
            case .workspace:
                switch boundariesAction {
                    case .stop:
                        return self
                    case .fail:
                        return nil
                    case .createImplicitContainer:
                        return creatingImplicitContainerAndMovingWindow(
                            windowId,
                            workspaceId: parentId,
                            direction: direction,
                            newRootContainerId: implicitContainerId,
                        )
                }
            case .container, .window:
                return nil
        }
    }

    private func creatingImplicitContainerAndMovingWindow(
        _ windowId: TreeNodeId,
        workspaceId: TreeNodeId,
        direction: CardinalDirection,
        newRootContainerId: TreeNodeId,
    ) -> TreeState? {
        guard let rootId = rootTilingContainer(for: workspaceId)?.id else { return nil }
        var result = self
        guard result.removeFromParent(rootId) != nil else { return nil }
        result.nodes[newRootContainerId] = .container(ContainerState(
            id: newRootContainerId,
            kind: .tiling,
            orientation: direction.orientation,
            layout: .tiles,
            adaptiveWeight: WEIGHT_DOESNT_MATTER,
            childIds: [],
            mruChildIds: [],
        ))
        guard result.insert(newRootContainerId, to: workspaceId, adaptiveWeight: WEIGHT_AUTO, index: 0) else { return nil }
        guard result.insert(rootId, to: newRootContainerId, adaptiveWeight: WEIGHT_AUTO, index: 0) else { return nil }
        guard result.insert(windowId, to: newRootContainerId, adaptiveWeight: WEIGHT_AUTO, index: direction.insertionOffset) else {
            return nil
        }
        return result
    }

    private func deepMovingWindow(
        _ windowId: TreeNodeId,
        into containerId: TreeNodeId,
        moveDirection: CardinalDirection,
    ) -> TreeState? {
        guard let deepTarget = deepMoveInTarget(from: containerId, orientation: moveDirection.orientation) else {
            return nil
        }
        var result = self
        switch deepTarget {
            case .container(let containerId):
                guard result.insert(windowId, to: containerId, adaptiveWeight: WEIGHT_AUTO, index: 0) else { return nil }
            case .window(let targetWindowId):
                guard let parentId = parentId(of: targetWindowId),
                      let parent = nodes[parentId],
                      parent.childIds.firstIndex(of: targetWindowId) != nil
                else { return nil }
                let targetIndex = parent.childIds.firstIndex(of: targetWindowId).orDie()
                guard result.insert(windowId, to: parentId, adaptiveWeight: WEIGHT_AUTO, index: targetIndex + 1) else {
                    return nil
                }
        }
        return result
    }

    private func deepMoveInTarget(from nodeId: TreeNodeId, orientation: Orientation) -> DeepMoveInTarget? {
        guard let node = nodes[nodeId] else { return nil }
        switch node {
            case .window:
                return .window(nodeId)
            case .container(let container) where container.kind == .tiling && container.orientation == orientation:
                return .container(nodeId)
            case .container(let container) where container.kind == .tiling:
                return mostRecentChildId(of: container.id).flatMap { deepMoveInTarget(from: $0, orientation: orientation) }
            case .workspace, .container:
                return nil
        }
    }

    private func isTilingContainer(_ nodeId: TreeNodeId) -> Bool {
        guard case .container(let container) = nodes[nodeId] else { return false }
        return container.kind == .tiling
    }

    private mutating func balance(containerId: TreeNodeId) {
        guard case .container(let container) = nodes[containerId], container.kind == .tiling else { return }
        for childId in container.childIds {
            if container.layout == .tiles {
                nodes[childId] = nodes[childId]?.withAdaptiveWeight(1)
            }
            if isTilingContainer(childId) {
                balance(containerId: childId)
            }
        }
    }

    private func parentIsWorkspace(_ nodeId: TreeNodeId) -> Bool {
        parentId(of: nodeId).flatMap { parentId in
            if case .workspace = nodes[parentId] { true } else { false }
        } ?? false
    }
}

private enum DeepMoveInTarget {
    case container(TreeNodeId)
    case window(TreeNodeId)
}

extension TreeNodeState {
    fileprivate var adaptiveWeight: CGFloat {
        switch self {
            case .workspace: WEIGHT_DOESNT_MATTER
            case .container(let state): state.adaptiveWeight
            case .window(let state): state.adaptiveWeight
        }
    }

    fileprivate func withAdaptiveWeight(_ adaptiveWeight: CGFloat) -> TreeNodeState {
        switch self {
            case .workspace:
                self
            case .container(let state):
                .container(ContainerState(
                    id: state.id,
                    kind: state.kind,
                    orientation: state.orientation,
                    layout: state.layout,
                    adaptiveWeight: adaptiveWeight,
                    childIds: state.childIds,
                    mruChildIds: state.mruChildIds,
                ))
            case .window(let state):
                .window(WindowState(
                    id: state.id,
                    windowId: state.windowId,
                    appPid: state.appPid,
                    appBundleId: state.appBundleId,
                    adaptiveWeight: adaptiveWeight,
                    lastFloatingSize: state.lastFloatingSize,
                    isFullscreen: state.isFullscreen,
                    noOuterGapsInFullscreen: state.noOuterGapsInFullscreen,
                    layoutReason: state.layoutReason,
                ))
        }
    }

    fileprivate func withChildren(_ childIds: [TreeNodeId], mruChildIds: [TreeNodeId]) -> TreeNodeState {
        switch self {
            case .workspace(let state):
                .workspace(WorkspaceState(
                    id: state.id,
                    name: state.name,
                    isVisible: state.isVisible,
                    isFocused: state.isFocused,
                    assignedMonitorTopLeft: state.assignedMonitorTopLeft,
                    forcedMonitorTopLeft: state.forcedMonitorTopLeft,
                    childIds: childIds,
                    mruChildIds: mruChildIds,
                ))
            case .container(let state):
                .container(ContainerState(
                    id: state.id,
                    kind: state.kind,
                    orientation: state.orientation,
                    layout: state.layout,
                    adaptiveWeight: state.adaptiveWeight,
                    childIds: childIds,
                    mruChildIds: mruChildIds,
                ))
            case .window:
                self
        }
    }

    fileprivate func childRelation(for child: TreeNodeState) -> TreeStateChildRelation {
        switch (child, self) {
            case (.workspace, _): .invalid
            case (.window, .workspace): .valid
            case (.container(let child), .workspace) where child.kind == .tiling: .valid
            case (.container(let child), .workspace) where child.kind == .macosFullscreen: .valid
            case (.container(let child), .workspace) where child.kind == .macosHiddenApps: .valid
            case (.window, .container(let parent)) where parent.kind == .tiling: .valid
            case (.container(let child), .container(let parent)) where child.kind == .tiling && parent.kind == .tiling: .valid
            case (.window, .container(let parent)) where parent.kind == .macosFullscreen: .valid
            case (.window, .container(let parent)) where parent.kind == .macosHiddenApps: .valid
            case (.window, .container(let parent)) where parent.kind == .macosMinimized: .valid
            case (.window, .container(let parent)) where parent.kind == .macosPopup: .valid
            default: .invalid
        }
    }
}

private enum TreeStateChildRelation {
    case valid
    case invalid

    var isValid: Bool { self == .valid }
}
