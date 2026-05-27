import AppKit
import Common

extension TreeState {
    func normalized(
        flattenContainers: Bool,
        oppositeOrientationForNestedContainers: Bool,
    ) -> TreeState {
        var normalizer = TreeStateNormalizer(
            state: self,
            flattenContainers: flattenContainers,
            oppositeOrientationForNestedContainers: oppositeOrientationForNestedContainers,
        )
        return normalizer.normalize()
    }
}

private struct TreeStateNormalizer {
    var state: TreeState
    let flattenContainers: Bool
    let oppositeOrientationForNestedContainers: Bool

    mutating func normalize() -> TreeState {
        for workspaceId in state.workspaceIdsInOrder {
            normalizeWorkspace(workspaceId)
        }
        if oppositeOrientationForNestedContainers {
            for workspaceId in state.workspaceIdsInOrder {
                normalizeOppositeOrientation(in: workspaceId, parentOrientation: nil)
            }
        }
        pruneUnreachableNodes()
        return state
    }

    private mutating func normalizeWorkspace(_ workspaceId: TreeNodeId) {
        guard case .workspace(let workspace) = state.nodes[workspaceId] else { return }

        var replacements: [TreeNodeId: TreeNodeId] = [:]
        var normalizedChildIds: [TreeNodeId] = []
        for childId in workspace.childIds {
            if isTilingContainer(childId), let replacementId = normalizeTilingContainer(childId, isRootContainer: true) {
                replacements[childId] = replacementId
                normalizedChildIds.append(replacementId)
            } else if state.nodes[childId] != nil {
                normalizedChildIds.append(childId)
            }
        }

        state.nodes[workspaceId] = .workspace(WorkspaceState(
            id: workspace.id,
            name: workspace.name,
            isVisible: workspace.isVisible,
            isFocused: workspace.isFocused,
            assignedMonitorTopLeft: workspace.assignedMonitorTopLeft,
            forcedMonitorTopLeft: workspace.forcedMonitorTopLeft,
            childIds: normalizedChildIds,
            mruChildIds: normalizedMruIds(workspace.mruChildIds, replacements: replacements, validChildIds: normalizedChildIds),
        ))
    }

    private mutating func normalizeTilingContainer(_ containerId: TreeNodeId, isRootContainer: Bool) -> TreeNodeId? {
        guard case .container(let container) = state.nodes[containerId], container.kind == .tiling else {
            return containerId
        }

        if flattenContainers,
           let childId = container.childIds.singleOrNil(),
           isTilingContainer(childId) || !isRootContainer
        {
            setAdaptiveWeight(of: childId, to: container.adaptiveWeight)
            if isTilingContainer(childId) {
                return normalizeTilingContainer(childId, isRootContainer: isRootContainer)
            }
            return childId
        }

        var replacements: [TreeNodeId: TreeNodeId] = [:]
        var normalizedChildIds: [TreeNodeId] = []
        for childId in container.childIds {
            if isTilingContainer(childId) {
                if let replacementId = normalizeTilingContainer(childId, isRootContainer: false) {
                    replacements[childId] = replacementId
                    normalizedChildIds.append(replacementId)
                }
            } else if state.nodes[childId] != nil {
                normalizedChildIds.append(childId)
            }
        }

        if normalizedChildIds.isEmpty && !isRootContainer {
            return nil
        }

        state.nodes[containerId] = .container(ContainerState(
            id: container.id,
            kind: container.kind,
            orientation: container.orientation,
            layout: container.layout,
            adaptiveWeight: container.adaptiveWeight,
            childIds: normalizedChildIds,
            mruChildIds: normalizedMruIds(container.mruChildIds, replacements: replacements, validChildIds: normalizedChildIds),
        ))
        return containerId
    }

    private mutating func normalizeOppositeOrientation(in nodeId: TreeNodeId, parentOrientation: Orientation?) {
        guard let node = state.nodes[nodeId] else { return }
        var orientationForChildren = parentOrientation

        if case .container(let container) = node, container.kind == .tiling, let orientation = container.orientation {
            let normalizedOrientation = orientation == parentOrientation ? orientation.opposite : orientation
            if normalizedOrientation != orientation {
                state.nodes[nodeId] = .container(ContainerState(
                    id: container.id,
                    kind: container.kind,
                    orientation: normalizedOrientation,
                    layout: container.layout,
                    adaptiveWeight: container.adaptiveWeight,
                    childIds: container.childIds,
                    mruChildIds: container.mruChildIds,
                ))
            }
            orientationForChildren = normalizedOrientation
        }

        for childId in state.nodes[nodeId]?.childIds ?? [] {
            normalizeOppositeOrientation(in: childId, parentOrientation: orientationForChildren)
        }
    }

    private mutating func pruneUnreachableNodes() {
        var reachable: Set<TreeNodeId> = []
        func visit(_ id: TreeNodeId) {
            guard reachable.insert(id).inserted, let node = state.nodes[id] else { return }
            for childId in node.childIds {
                visit(childId)
            }
        }
        for rootId in state.rootIdsInOrder {
            visit(rootId)
        }
        state.nodes = state.nodes.filter { reachable.contains($0.key) }
    }

    private func isTilingContainer(_ id: TreeNodeId) -> Bool {
        guard case .container(let container) = state.nodes[id] else { return false }
        return container.kind == .tiling
    }

    private mutating func setAdaptiveWeight(of nodeId: TreeNodeId, to adaptiveWeight: CGFloat) {
        guard let node = state.nodes[nodeId] else { return }
        state.nodes[nodeId] = switch node {
            case .workspace:
                node
            case .container(let container):
                .container(ContainerState(
                    id: container.id,
                    kind: container.kind,
                    orientation: container.orientation,
                    layout: container.layout,
                    adaptiveWeight: adaptiveWeight,
                    childIds: container.childIds,
                    mruChildIds: container.mruChildIds,
                ))
            case .window(let window):
                .window(WindowState(
                    id: window.id,
                    windowId: window.windowId,
                    appPid: window.appPid,
                    appBundleId: window.appBundleId,
                    adaptiveWeight: adaptiveWeight,
                    lastFloatingSize: window.lastFloatingSize,
                    isFullscreen: window.isFullscreen,
                    noOuterGapsInFullscreen: window.noOuterGapsInFullscreen,
                    layoutReason: window.layoutReason,
                ))
        }
    }

    private func normalizedMruIds(
        _ mruChildIds: [TreeNodeId],
        replacements: [TreeNodeId: TreeNodeId],
        validChildIds: [TreeNodeId],
    ) -> [TreeNodeId] {
        let validChildIds = Set(validChildIds)
        var seen: Set<TreeNodeId> = []
        return mruChildIds.compactMap { mruChildId in
            let candidate = replacements[mruChildId] ?? mruChildId
            guard validChildIds.contains(candidate), seen.insert(candidate).inserted else { return nil }
            return candidate
        }
    }
}
