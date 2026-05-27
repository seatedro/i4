@testable import AppBundle
import XCTest

@MainActor
final class ImmutableTreeStateTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testSnapshotMatchesMutableLayout() {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        TestWindow.new(id: 1, parent: root)
        TilingContainer.newVTiles(parent: root, adaptiveWeight: 2).apply {
            TestWindow.new(id: 2, parent: $0)
            TestWindow.new(id: 3, parent: $0)
        }
        TestWindow.new(id: 4, parent: workspace)
        TestWindow.new(id: 5, parent: workspace.macOsNativeFullscreenWindowsContainer)

        assertEquals(workspace.focusWorkspace(), true)
        TreeStore.shared.refreshFromMutableTree()

        let state = TreeStore.shared.current
        assertEquals(state.invariantViolations(), [])
        let workspaceState = state.workspace(named: workspace.name).orDie()
        assertEquals(
            state.layoutDescription(for: workspaceState.id),
            TreeLayoutDescription.fromMutableNode(workspace),
        )
    }

    func testCursorComputesParentPathWithoutParentPointers() {
        let workspace = Workspace.get(byName: name)
        let nested = TilingContainer.newVTiles(parent: workspace.rootTilingContainer, adaptiveWeight: 1)
        let window = TestWindow.new(id: 10, parent: nested)
        assertEquals(window.focusWindow(), true)

        TreeStore.shared.refreshFromMutableTree()
        let state = TreeStore.shared.current
        let windowNodeId = state.nodes.values.compactMap { node -> TreeNodeId? in
            if case .window(let windowState) = node, windowState.windowId == window.windowId {
                windowState.id
            } else {
                nil
            }
        }.singleOrNil().orDie()
        let cursor = state.cursor(to: windowNodeId).orDie()

        assertEquals(cursor.ref.id, windowNodeId)
        assertEquals(cursor.path.nodeIds.last, windowNodeId)
        assertNotNil(cursor.parent)
        assertEquals(state.focusedWindowNodeId, windowNodeId)
    }

    func testRootContainerSurvivesEmptyNormalization() {
        let workspace = Workspace.get(byName: name)
        _ = workspace.rootTilingContainer

        workspace.normalizeContainers()
        TreeStore.shared.refreshFromMutableTree()

        let state = TreeStore.shared.current
        assertEquals(state.invariantViolations(), [])
        let workspaceState = state.workspace(named: workspace.name).orDie()
        assertEquals(workspaceState.childIds.count, 1)
        guard case .container(let rootState) = state.nodes[workspaceState.childIds[0]] else {
            return XCTFail("Expected root tiling container")
        }
        assertEquals(rootState.kind, .tiling)
        assertEquals(state.layoutDescription(for: workspaceState.id), .workspace([.hTiles([])]))
    }

    func testInvariantDetectsDuplicateWindowIds() {
        let workspaceId = TreeNodeId(rawValue: 1)
        let firstWindowId = TreeNodeId(rawValue: 2)
        let secondWindowId = TreeNodeId(rawValue: 3)
        let state = TreeState(
            nodes: [
                workspaceId: .workspace(WorkspaceState(
                    id: workspaceId,
                    name: "w",
                    isVisible: true,
                    isFocused: true,
                    assignedMonitorTopLeft: nil,
                    forcedMonitorTopLeft: nil,
                    childIds: [firstWindowId, secondWindowId],
                    mruChildIds: [],
                )),
                firstWindowId: .window(Self.windowState(id: firstWindowId, windowId: 42)),
                secondWindowId: .window(Self.windowState(id: secondWindowId, windowId: 42)),
            ],
            workspaceIdsInOrder: [workspaceId],
            globalContainerIdsInOrder: [],
            focusedWorkspaceId: workspaceId,
            focusedWindowNodeId: firstWindowId,
        )

        XCTAssertTrue(state.invariantViolations().contains { $0.contains("window id 42 appears more than once") })
    }

    func testInvariantDetectsInvalidMruReferences() {
        let workspaceId = TreeNodeId(rawValue: 1)
        let childId = TreeNodeId(rawValue: 2)
        let notAChildId = TreeNodeId(rawValue: 3)
        let state = TreeState(
            nodes: [
                workspaceId: .workspace(WorkspaceState(
                    id: workspaceId,
                    name: "w",
                    isVisible: true,
                    isFocused: true,
                    assignedMonitorTopLeft: nil,
                    forcedMonitorTopLeft: nil,
                    childIds: [childId],
                    mruChildIds: [notAChildId],
                )),
                childId: .window(Self.windowState(id: childId, windowId: 42)),
            ],
            workspaceIdsInOrder: [workspaceId],
            globalContainerIdsInOrder: [],
            focusedWorkspaceId: workspaceId,
            focusedWindowNodeId: childId,
        )

        XCTAssertTrue(state.invariantViolations().contains { $0.contains("MRU child") })
    }

    private static func windowState(id: TreeNodeId, windowId: UInt32) -> WindowState {
        WindowState(
            id: id,
            windowId: windowId,
            appPid: 0,
            appBundleId: "test",
            adaptiveWeight: 1,
            lastFloatingSize: nil,
            isFullscreen: false,
            noOuterGapsInFullscreen: false,
            layoutReason: .standard,
        )
    }
}
