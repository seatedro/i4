import AppKit

struct TreeStateExport {
    let state: TreeState
    let seenObjectIds: Set<ObjectIdentifier>
}

extension TreeState {
    @MainActor
    static func fromMutableTree(
        workspaces: [Workspace] = Workspace.all,
        idForNode: (TreeNode) -> TreeNodeId,
    ) -> TreeStateExport {
        var nodes: [TreeNodeId: TreeNodeState] = [:]
        var seenObjectIds: Set<ObjectIdentifier> = []

        func export(_ node: TreeNode) -> TreeNodeId {
            let id = idForNode(node)
            seenObjectIds.insert(ObjectIdentifier(node))
            let childIds = node.children.map(export)
            let mruChildIds = node.mruChildren.map(idForNode)

            nodes[id] = switch node.nodeCases {
                case .workspace(let workspace):
                    .workspace(WorkspaceState(
                        id: id,
                        name: workspace.name,
                        isVisible: workspace.isVisible,
                        isFocused: focus.workspace === workspace,
                        assignedMonitorTopLeft: workspace.workspaceMonitor.rect.topLeftCorner,
                        forcedMonitorTopLeft: workspace.forceAssignedMonitor?.rect.topLeftCorner,
                        childIds: childIds,
                        mruChildIds: mruChildIds,
                    ))
                case .tilingContainer(let container):
                    .container(ContainerState(
                        id: id,
                        kind: .tiling,
                        orientation: container.orientation,
                        layout: container.layout,
                        adaptiveWeight: container.treeAdaptiveWeight,
                        childIds: childIds,
                        mruChildIds: mruChildIds,
                    ))
                case .macosFullscreenWindowsContainer:
                    .container(ContainerState(
                        id: id,
                        kind: .macosFullscreen,
                        orientation: nil,
                        layout: nil,
                        adaptiveWeight: node.treeAdaptiveWeight,
                        childIds: childIds,
                        mruChildIds: mruChildIds,
                    ))
                case .macosHiddenAppsWindowsContainer:
                    .container(ContainerState(
                        id: id,
                        kind: .macosHiddenApps,
                        orientation: nil,
                        layout: nil,
                        adaptiveWeight: node.treeAdaptiveWeight,
                        childIds: childIds,
                        mruChildIds: mruChildIds,
                    ))
                case .macosMinimizedWindowsContainer:
                    .container(ContainerState(
                        id: id,
                        kind: .macosMinimized,
                        orientation: nil,
                        layout: nil,
                        adaptiveWeight: node.treeAdaptiveWeight,
                        childIds: childIds,
                        mruChildIds: mruChildIds,
                    ))
                case .macosPopupWindowsContainer:
                    .container(ContainerState(
                        id: id,
                        kind: .macosPopup,
                        orientation: nil,
                        layout: nil,
                        adaptiveWeight: node.treeAdaptiveWeight,
                        childIds: childIds,
                        mruChildIds: mruChildIds,
                    ))
                case .window(let window):
                    .window(WindowState(
                        id: id,
                        windowId: window.windowId,
                        appPid: window.app.pid,
                        appBundleId: window.app.rawAppBundleId,
                        adaptiveWeight: window.treeAdaptiveWeight,
                        lastFloatingSize: window.lastFloatingSize,
                        isFullscreen: window.isFullscreen,
                        noOuterGapsInFullscreen: window.noOuterGapsInFullscreen,
                        layoutReason: WindowLayoutReasonState(window.layoutReason),
                    ))
            }
            return id
        }

        let workspaceIds = workspaces.sorted().map(export)
        let globalContainerIds = [macosMinimizedWindowsContainer, macosPopupWindowsContainer].map(export)
        let focusedWorkspaceId = idForNode(focus.workspace)
        let focusedWindowNodeId = focus.windowOrNil.map(idForNode)
        return TreeStateExport(
            state: TreeState(
                nodes: nodes,
                workspaceIdsInOrder: workspaceIds,
                globalContainerIdsInOrder: globalContainerIds,
                focusedWorkspaceId: focusedWorkspaceId,
                focusedWindowNodeId: focusedWindowNodeId,
            ),
            seenObjectIds: seenObjectIds,
        )
    }
}

extension WindowLayoutReasonState {
    init(_ layoutReason: LayoutReason) {
        self = switch layoutReason {
            case .standard: .standard
            case .macos(let prevParentKind): .macos(prevParentKind: prevParentKind)
        }
    }
}
