import AppKit
import Common

/// First line of defence against lock screen
///
/// When you lock the screen, all accessibility API becomes unobservable (all attributes become empty, window id
/// becomes nil, etc.) which tricks AeroSpace into thinking that all windows were closed.
/// That's why every time a window dies AeroSpace caches the "entire world" (unless window is already presented in the cache)
/// so that once the screen is unlocked, AeroSpace could restore windows to where they were
@MainActor private var closedWindowsCache = ClosedWindowsCacheSnapshot.empty

private struct ClosedWindowsCacheSnapshot {
    let tree: TreeState
    let monitors: [FrozenMonitor]
    let windowIds: Set<UInt32>

    static let empty = ClosedWindowsCacheSnapshot(tree: .empty, monitors: [], windowIds: [])
}

struct FrozenMonitor: Sendable {
    let topLeftCorner: CGPoint
    let visibleWorkspace: String

    @MainActor init(_ monitor: Monitor) {
        topLeftCorner = monitor.rect.topLeftCorner
        visibleWorkspace = monitor.activeWorkspace.name
    }
}

@MainActor func cacheClosedWindowIfNeeded() {
    let allWs = Workspace.all
    TreeStore.shared.refreshFromMutableTree(workspaces: allWs)
    let tree = TreeStore.shared.current
    let allWindowIds = tree.closedWindowsCacheWindowIds
    if allWindowIds.isSubset(of: closedWindowsCache.windowIds) {
        return // already cached
    }
    closedWindowsCache = ClosedWindowsCacheSnapshot(
        tree: tree,
        monitors: monitors.map(FrozenMonitor.init),
        windowIds: allWindowIds,
    )
}

@MainActor func restoreClosedWindowsCacheIfNeeded(newlyDetectedWindow: Window) async throws -> Bool {
    if !closedWindowsCache.windowIds.contains(newlyDetectedWindow.windowId) {
        return false
    }
    let monitors = monitors
    let topLeftCornerToMonitor = monitors.grouped { $0.rect.topLeftCorner }

    let tree = closedWindowsCache.tree
    for workspaceId in tree.workspaceIdsInOrder {
        guard case .workspace(let workspaceState) = tree.nodes[workspaceId] else { continue }
        let workspace = Workspace.get(byName: workspaceState.name)
        _ = workspaceState.assignedMonitorTopLeft.flatMap { topLeftCornerToMonitor[$0]?.singleOrNil() }?
            .setActiveWorkspace(workspace)
        for window in tree.floatingWindows(in: workspaceState) {
            MacWindow.get(byId: window.windowId)?.bindAsFloatingWindow(to: workspace)
        }
        for window in tree.macosUnconventionalWindows(in: workspaceState) { // Will get fixed by normalizations
            MacWindow.get(byId: window.windowId)?.bindAsFloatingWindow(to: workspace)
        }
        let prevRoot = workspace.rootTilingContainer // Save prevRoot into a variable to avoid it being garbage collected earlier than needed
        let potentialOrphans = prevRoot.allLeafWindowsRecursive
        prevRoot.unbindFromParent()
        if let rootId = tree.rootTilingContainer(for: workspaceId)?.id {
            restoreTreeRecursive(tree: tree, nodeId: rootId, parent: workspace, index: INDEX_BIND_LAST)
        }
        for window in (potentialOrphans - workspace.rootTilingContainer.allLeafWindowsRecursive) {
            try await window.relayoutWindow(on: workspace, forceTile: true)
        }
    }

    for monitor in closedWindowsCache.monitors {
        _ = topLeftCornerToMonitor[monitor.topLeftCorner]?
            .singleOrNil()?
            .setActiveWorkspace(Workspace.get(byName: monitor.visibleWorkspace))
    }
    TreeStore.shared.refreshFromMutableTree()
    return true
}

@discardableResult
@MainActor
private func restoreTreeRecursive(tree: TreeState, nodeId: TreeNodeId, parent: NonLeafTreeNodeObject, index: Int) -> Bool {
    guard case .container(let containerState) = tree.nodes[nodeId],
          containerState.kind == .tiling,
          let orientation = containerState.orientation,
          let layout = containerState.layout
    else { return false }

    let container = TilingContainer(
        parent: parent,
        adaptiveWeight: tree.snapshotBindingWeight(of: containerState.id),
        orientation,
        layout,
        index: index,
    )

    for (index, childId) in containerState.childIds.enumerated() {
        guard let child = tree.nodes[childId] else { return false }
        switch child {
            case .window(let windowState):
                // Stop the loop if can't find the window, because otherwise all the subsequent windows will have incorrect index
                guard let window = MacWindow.get(byId: windowState.windowId) else { return false }
                window.bind(to: container, adaptiveWeight: tree.snapshotBindingWeight(of: windowState.id), index: index)
            case .container(let childContainer) where childContainer.kind == .tiling:
                // There is no reason to continue
                if !restoreTreeRecursive(tree: tree, nodeId: childContainer.id, parent: container, index: index) { return false }
            case .workspace, .container:
                return false
        }
    }
    return true
}

// Consider the following case:
// 1. Close window
// 2. The previous step lead to caching the whole world
// 3. Change something in the layout
// 4. Lock the screen
// 5. The cache won't be updated because all alive windows are already cached
// 6. Unlock the screen
// 7. The wrong cache is used
//
// That's why we have to reset the cache every time layout changes. The layout can only be changed by running commands
// and with mouse manipulations
@MainActor func resetClosedWindowsCache() {
    closedWindowsCache = .empty
}

extension TreeState {
    fileprivate var closedWindowsCacheWindowIds: Set<UInt32> {
        workspaceIdsInOrder.flatMap { workspaceId -> [UInt32] in
            guard case .workspace(let workspace) = nodes[workspaceId] else { return [] }
            return floatingWindows(in: workspace).map(\.windowId) +
                macosUnconventionalWindows(in: workspace).map(\.windowId) +
                (rootTilingContainer(for: workspace.id).map { leafWindowsRecursive(from: $0.id).map(\.windowId) } ?? [])
        }.toSet()
    }

    fileprivate func floatingWindows(in workspace: WorkspaceState) -> [WindowState] {
        workspace.childIds.compactMap { childId in
            guard case .window(let window) = nodes[childId] else { return nil }
            return window
        }
    }

    fileprivate func macosUnconventionalWindows(in workspace: WorkspaceState) -> [WindowState] {
        workspace.childIds.flatMap { childId -> [WindowState] in
            guard case .container(let container) = nodes[childId],
                  container.kind == .macosHiddenApps || container.kind == .macosFullscreen
            else { return [] }
            return container.childIds.compactMap { windowId in
                guard case .window(let window) = nodes[windowId] else { return nil }
                return window
            }
        }
    }
}
