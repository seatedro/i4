@testable import AppBundle
import Common
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

        TreeStore.shared.refreshFromMutableTree()
        let normalized = TreeStore.shared.current.normalized(
            flattenContainers: config.enableNormalizationFlattenContainers,
            oppositeOrientationForNestedContainers: config.enableNormalizationOppositeOrientationForNestedContainers,
        )
        let normalizedWorkspace = normalized.workspace(named: workspace.name).orDie()
        assertEquals(normalized.invariantViolations(), [])
        assertEquals(normalized.layoutDescription(for: normalizedWorkspace.id), .workspace([.hTiles([])]))

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

    func testNormalizedMatchesMutableRemovingEmptyContainers() {
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.apply {
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                _ = TilingContainer.newHTiles(parent: $0, adaptiveWeight: 1)
            }
        }

        assertNormalizedStateMatchesMutableNormalization(workspace)
    }

    func testNormalizedMatchesMutableFlatteningSingleChildContainers() {
        config.enableNormalizationFlattenContainers = true
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.apply {
            TestWindow.new(id: 0, parent: $0)
            TilingContainer.newHTiles(parent: $0, adaptiveWeight: 1).apply {
                TestWindow.new(id: 1, parent: $0)
            }
        }

        assertNormalizedStateMatchesMutableNormalization(workspace)
    }

    func testNormalizedMatchesMutableFlatteningRootContainerChild() {
        config.enableNormalizationFlattenContainers = true
        let workspace = Workspace.get(byName: name)
        TilingContainer.newVTiles(parent: workspace.rootTilingContainer, adaptiveWeight: 1).apply {
            TestWindow.new(id: 1, parent: $0)
        }

        assertNormalizedStateMatchesMutableNormalization(workspace)
    }

    func testNormalizedMatchesMutableOppositeNestedOrientation() {
        config.enableNormalizationOppositeOrientationForNestedContainers = true
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.apply {
            TilingContainer.newHTiles(parent: $0, adaptiveWeight: 1).apply {
                TilingContainer.newHTiles(parent: $0, adaptiveWeight: 1).apply {
                    TestWindow.new(id: 1, parent: $0)
                }
            }
        }

        assertNormalizedStateMatchesMutableNormalization(workspace)
    }

    func testLeafWindowsRecursiveMatchesMutableDfsOrder() {
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.apply {
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                TestWindow.new(id: 1, parent: $0)
                TilingContainer.newHTiles(parent: $0, adaptiveWeight: 1).apply {
                    TestWindow.new(id: 2, parent: $0)
                    TestWindow.new(id: 3, parent: $0)
                }
            }
            TestWindow.new(id: 4, parent: $0)
        }

        TreeStore.shared.refreshFromMutableTree()
        let state = TreeStore.shared.current
        let workspaceState = state.workspace(named: workspace.name).orDie()
        let rootState = state.rootTilingContainer(for: workspaceState.id).orDie()
        assertEquals(
            state.leafWindowsRecursive(from: rootState.id).map(\.windowId),
            workspace.rootTilingContainer.allLeafWindowsRecursive.map(\.windowId),
        )
    }

    func testMostRecentWindowRecursiveMatchesMutableMru() {
        let workspace = Workspace.get(byName: name)
        var window2: Window!
        var window3: Window!
        workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                window2 = TestWindow.new(id: 2, parent: $0)
                window3 = TestWindow.new(id: 3, parent: $0)
            }
        }

        assertMostRecentWindowMatches(workspace)
        window2.markAsMostRecentChild()
        assertMostRecentWindowMatches(workspace)
        window3.markAsMostRecentChild()
        assertMostRecentWindowMatches(workspace)
    }

    func testMarkingAsMostRecentMatchesMutableMruPropagation() {
        let workspace = Workspace.get(byName: name)
        var window2: Window!
        workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                window2 = TestWindow.new(id: 2, parent: $0)
                TestWindow.new(id: 3, parent: $0)
            }
        }

        TreeStore.shared.refreshFromMutableTree()
        let state = TreeStore.shared.current
        let window2State = state.windowNode(withWindowId: window2.windowId).orDie()
        let immutableMarkedState = state.markingAsMostRecent(window2State.id)

        window2.markAsMostRecentChild()
        TreeStore.shared.refreshFromMutableTree()
        let mutableMarkedState = TreeStore.shared.current
        let workspaceState = immutableMarkedState.workspace(named: workspace.name).orDie()
        let mutableWorkspaceState = mutableMarkedState.workspace(named: workspace.name).orDie()

        assertEquals(
            immutableMarkedState.mostRecentWindowRecursive(from: workspaceState.id)?.windowId,
            mutableMarkedState.mostRecentWindowRecursive(from: mutableWorkspaceState.id)?.windowId,
        )
    }

    func testDirectionalFocusCandidateMatchesMutableMruDescent() {
        let workspace = Workspace.get(byName: name)
        var startWindow: Window!
        var window2: Window!
        var window3: Window!
        var unrelatedWindow: Window!
        workspace.rootTilingContainer.apply {
            startWindow = TestWindow.new(id: 1, parent: $0)
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                TilingContainer.newHTiles(parent: $0, adaptiveWeight: 1).apply {
                    window2 = TestWindow.new(id: 2, parent: $0)
                    unrelatedWindow = TestWindow.new(id: 5, parent: $0)
                }
                window3 = TestWindow.new(id: 3, parent: $0)
            }
        }

        assertFocusCandidateMatches(startWindow, direction: .right)
        window2.markAsMostRecentChild()
        _ = startWindow.focusWindow()
        assertFocusCandidateMatches(startWindow, direction: .right)
        window3.markAsMostRecentChild()
        unrelatedWindow.markAsMostRecentChild()
        _ = startWindow.focusWindow()
        assertFocusCandidateMatches(startWindow, direction: .right)
    }

    func testSnappedLeafWindowMatchesMutableTraversal() {
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                TestWindow.new(id: 2, parent: $0)
                TestWindow.new(id: 3, parent: $0)
            }
        }

        TreeStore.shared.refreshFromMutableTree()
        let state = TreeStore.shared.current
        let workspaceState = state.workspace(named: workspace.name).orDie()
        for direction in CardinalDirection.allCases {
            assertEquals(
                state.findLeafWindow(from: workspaceState.id, snappedTo: direction)?.windowId,
                workspace.findLeafWindowRecursive(snappedTo: direction)?.windowId,
            )
        }
    }

    func testPureSwapMatchesMutableSwapCommand() async throws {
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.apply {
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                assertEquals(TestWindow.new(id: 1, parent: $0).focusWindow(), true)
                TestWindow.new(id: 2, parent: $0)
            }
            TestWindow.new(id: 3, parent: $0)
        }

        TreeStore.shared.refreshFromMutableTree()
        let state = TreeStore.shared.current
        let currentWindow = state.windowNode(withWindowId: 1).orDie()
        let targetWindow = state.focusWindow(from: currentWindow.id, inDirection: .right).orDie()
        let mutated = state.swappingWindows(currentWindow.id, targetWindow.id).orDie()

        try await SwapCommand(args: SwapCmdArgs(rawArgs: [], target: .direction(.right))).run(.defaultEnv, .emptyStdin)
        assertCurrentWorkspaceStateMatches(mutated, workspace)
    }

    func testPureSplitMatchesMutableSplitCommand() async throws {
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.apply {
            assertEquals(TestWindow.new(id: 1, parent: $0).focusWindow(), true)
            TestWindow.new(id: 2, parent: $0)
        }

        TreeStore.shared.refreshFromMutableTree()
        let state = TreeStore.shared.current
        let currentWindow = state.windowNode(withWindowId: 1).orDie()
        let mutated = state.splittingWindow(
            currentWindow.id,
            orientation: .v,
            newContainerId: nextUnusedNodeId(in: state),
            normalizeOppositeOrientationForNestedContainers: config.enableNormalizationOppositeOrientationForNestedContainers,
        ).orDie()

        try await SplitCommand(args: SplitCmdArgs(rawArgs: [], .vertical)).run(.defaultEnv, .emptyStdin)
        assertCurrentWorkspaceStateMatches(mutated, workspace)
    }

    func testPureJoinMatchesMutableJoinWithCommand() async throws {
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.apply {
            TestWindow.new(id: 0, parent: $0)
            assertEquals(TestWindow.new(id: 1, parent: $0).focusWindow(), true)
            TestWindow.new(id: 2, parent: $0)
        }

        TreeStore.shared.refreshFromMutableTree()
        let state = TreeStore.shared.current
        let currentWindow = state.windowNode(withWindowId: 1).orDie()
        let mutated = state.joiningWindowWithSibling(
            currentWindow.id,
            direction: .right,
            newContainerId: nextUnusedNodeId(in: state),
        ).orDie()

        try await JoinWithCommand(args: JoinWithCmdArgs(rawArgs: [], direction: .right)).run(.defaultEnv, .emptyStdin)
        assertCurrentWorkspaceStateMatches(mutated, workspace)
    }

    func testPureMoveSiblingMatchesMutableMoveCommand() async throws {
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.apply {
            assertEquals(TestWindow.new(id: 1, parent: $0).focusWindow(), true)
            TestWindow.new(id: 2, parent: $0)
        }

        TreeStore.shared.refreshFromMutableTree()
        let state = TreeStore.shared.current
        let currentWindow = state.windowNode(withWindowId: 1).orDie()
        let mutated = state.movingWindow(
            currentWindow.id,
            direction: .right,
            boundariesAction: .createImplicitContainer,
            implicitContainerId: nextUnusedNodeId(in: state),
        ).orDie()

        try await MoveCommand(args: MoveCmdArgs(rawArgs: [], .right)).run(.defaultEnv, .emptyStdin)
        assertCurrentWorkspaceStateMatches(mutated, workspace)
    }

    func testPureMoveIntoMatchesMutableMoveCommand() async throws {
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.apply {
            TestWindow.new(id: 0, parent: $0)
            assertEquals(TestWindow.new(id: 1, parent: $0).focusWindow(), true)
            TilingContainer.newHTiles(parent: $0, adaptiveWeight: 1).apply {
                TilingContainer.newHTiles(parent: $0, adaptiveWeight: 1).apply {
                    TestWindow.new(id: 2, parent: $0)
                }
            }
        }

        TreeStore.shared.refreshFromMutableTree()
        let state = TreeStore.shared.current
        let currentWindow = state.windowNode(withWindowId: 1).orDie()
        let mutated = state.movingWindow(
            currentWindow.id,
            direction: .right,
            boundariesAction: .createImplicitContainer,
            implicitContainerId: nextUnusedNodeId(in: state),
        ).orDie()

        try await MoveCommand(args: MoveCmdArgs(rawArgs: [], .right)).run(.defaultEnv, .emptyStdin)
        assertCurrentWorkspaceStateMatches(mutated, workspace)
    }

    func testPureMoveOutMatchesMutableMoveCommand() async throws {
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                assertEquals(TestWindow.new(id: 2, parent: $0).focusWindow(), true)
                TestWindow.new(id: 3, parent: $0)
                TestWindow.new(id: 4, parent: $0)
            }
        }

        TreeStore.shared.refreshFromMutableTree()
        let state = TreeStore.shared.current
        let currentWindow = state.windowNode(withWindowId: 2).orDie()
        let mutated = state.movingWindow(
            currentWindow.id,
            direction: .left,
            boundariesAction: .createImplicitContainer,
            implicitContainerId: nextUnusedNodeId(in: state),
        ).orDie()

        try await MoveCommand(args: MoveCmdArgs(rawArgs: [], .left)).run(.defaultEnv, .emptyStdin)
        assertCurrentWorkspaceStateMatches(mutated, workspace)
    }

    func testPureMoveImplicitContainerMatchesMutableMoveCommand() async throws {
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            assertEquals(TestWindow.new(id: 2, parent: $0).focusWindow(), true)
            TestWindow.new(id: 3, parent: $0)
        }

        TreeStore.shared.refreshFromMutableTree()
        let state = TreeStore.shared.current
        let currentWindow = state.windowNode(withWindowId: 2).orDie()
        let mutated = state.movingWindow(
            currentWindow.id,
            direction: .up,
            boundariesAction: .createImplicitContainer,
            implicitContainerId: nextUnusedNodeId(in: state),
        ).orDie()

        try await MoveCommand(args: MoveCmdArgs(rawArgs: [], .up)).run(.defaultEnv, .emptyStdin)
        assertCurrentWorkspaceStateMatches(mutated, workspace)
    }

    func testSnapshotBindingWeightMatchesFrozenRootFallback() {
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            assertEquals(TestWindow.new(id: 2, parent: $0).focusWindow(), true)
        }

        TreeStore.shared.refreshFromMutableTree()
        let state = TreeStore.shared.current
        let workspaceState = state.workspace(named: workspace.name).orDie()
        let currentWindow = state.windowNode(withWindowId: 2).orDie()
        let mutated = state.movingWindow(
            currentWindow.id,
            direction: .up,
            boundariesAction: .createImplicitContainer,
            implicitContainerId: nextUnusedNodeId(in: state),
        ).orDie()

        let mutatedWorkspace = mutated.workspace(named: workspaceState.name).orDie()
        let root = mutated.rootTilingContainer(for: mutatedWorkspace.id).orDie()
        assertEquals(root.adaptiveWeight, WEIGHT_DOESNT_MATTER)
        assertEquals(mutated.snapshotBindingWeight(of: root.id), 1)
    }

    func testCommitMaterializesMutableTreeFromImmutableState() {
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            assertEquals(TestWindow.new(id: 2, parent: $0).focusWindow(), true)
            TestWindow.new(id: 3, parent: $0)
        }

        TreeStore.shared.refreshFromMutableTree()
        let state = TreeStore.shared.current
        let currentWindow = state.windowNode(withWindowId: 2).orDie()
        let mutated = state.movingWindow(
            currentWindow.id,
            direction: .up,
            boundariesAction: .createImplicitContainer,
            implicitContainerId: TreeStore.shared.allocateNodeId(),
        ).orDie()
        let mutatedWorkspace = mutated.workspace(named: workspace.name).orDie()

        XCTAssertTrue(TreeStore.shared.commit(mutated))
        assertEquals(
            TreeLayoutDescription.fromMutableNode(workspace),
            mutated.layoutDescription(for: mutatedWorkspace.id),
        )
        assertEquals(workspace.mostRecentWindowRecursive?.windowId, mutated.mostRecentWindowRecursive(from: mutatedWorkspace.id)?.windowId)
    }

    func testPureFlattenWorkspaceMatchesMutableCommand() async throws {
        let workspace = Workspace.get(byName: name).apply {
            $0.rootTilingContainer.apply {
                TestWindow.new(id: 1, parent: $0)
                TilingContainer.newHTiles(parent: $0, adaptiveWeight: 1).apply {
                    TestWindow.new(id: 2, parent: $0)
                }
            }
            TestWindow.new(id: 3, parent: $0)
        }
        assertEquals(workspace.focusWorkspace(), true)

        TreeStore.shared.refreshFromMutableTree()
        let state = TreeStore.shared.current
        let workspaceState = state.workspace(named: workspace.name).orDie()
        let mutated = state.flatteningWorkspace(workspaceState.id).orDie().normalized(
            flattenContainers: config.enableNormalizationFlattenContainers,
            oppositeOrientationForNestedContainers: config.enableNormalizationOppositeOrientationForNestedContainers,
        )

        try await FlattenWorkspaceTreeCommand(args: FlattenWorkspaceTreeCmdArgs(rawArgs: [])).run(.defaultEnv, .emptyStdin)
        assertCurrentWorkspaceStateMatches(mutated, workspace)
    }

    func testPureBalanceWorkspaceMatchesMutableCommand() async throws {
        let workspace = Workspace.get(byName: name).apply { workspace in
            workspace.rootTilingContainer.apply {
                TestWindow.new(id: 1, parent: $0, adaptiveWeight: 1)
                TestWindow.new(id: 2, parent: $0, adaptiveWeight: 2)
                TestWindow.new(id: 3, parent: $0, adaptiveWeight: 3)
            }
        }

        TreeStore.shared.refreshFromMutableTree()
        let state = TreeStore.shared.current
        let workspaceState = state.workspace(named: workspace.name).orDie()
        let mutated = state.balancingWorkspace(workspaceState.id).orDie()

        try await BalanceSizesCommand(args: BalanceSizesCmdArgs(rawArgs: [])).run(.defaultEnv.copy(\.workspaceName, name), .emptyStdin)
        TreeStore.shared.refreshFromMutableTree()
        let actual = TreeStore.shared.current
        for windowId: UInt32 in [1, 2, 3] {
            assertEquals(
                mutated.windowNode(withWindowId: windowId)?.adaptiveWeight,
                actual.windowNode(withWindowId: windowId)?.adaptiveWeight,
            )
        }
    }

    func testPureLayoutChangeMatchesMutableCommand() async throws {
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.apply {
            assertEquals(TestWindow.new(id: 1, parent: $0).focusWindow(), true)
            TestWindow.new(id: 2, parent: $0)
        }

        TreeStore.shared.refreshFromMutableTree()
        let state = TreeStore.shared.current
        let currentWindow = state.windowNode(withWindowId: 1).orDie()
        let mutated = state.changingTilingLayout(
            of: currentWindow.id,
            targetLayout: .accordion,
            targetOrientation: .v,
            normalizeOppositeOrientationForNestedContainers: config.enableNormalizationOppositeOrientationForNestedContainers,
        ).orDie()

        try await LayoutCommand(args: LayoutCmdArgs(rawArgs: [], toggleBetween: [.v_accordion])).run(.defaultEnv, .emptyStdin)
        assertCurrentWorkspaceStateMatches(mutated, workspace)
    }

    func testPureMoveWindowToWorkspaceMatchesMutableCommand() async throws {
        let workspaceA = Workspace.get(byName: "a")
        let workspaceB = Workspace.get(byName: "b")
        _ = workspaceB.rootTilingContainer
        workspaceA.rootTilingContainer.apply {
            _ = TestWindow.new(id: 1, parent: $0).focusWindow()
        }

        TreeStore.shared.refreshFromMutableTree()
        let state = TreeStore.shared.current
        let currentWindow = state.windowNode(withWindowId: 1).orDie()
        let targetWorkspace = state.workspace(named: workspaceB.name).orDie()
        let mutated = state.movingWindowToWorkspace(currentWindow.id, targetWorkspaceId: targetWorkspace.id).orDie()

        try await MoveNodeToWorkspaceCommand(args: MoveNodeToWorkspaceCmdArgs(workspace: workspaceB.name)).run(.defaultEnv, .emptyStdin)
        assertCurrentWorkspaceStateMatches(mutated, workspaceB)
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

    private func assertMostRecentWindowMatches(
        _ workspace: Workspace,
        file: String = #filePath,
        line: Int = #line,
    ) {
        TreeStore.shared.refreshFromMutableTree()
        let state = TreeStore.shared.current
        let workspaceState = state.workspace(named: workspace.name).orDie()
        assertEquals(
            state.mostRecentWindowRecursive(from: workspaceState.id)?.windowId,
            workspace.mostRecentWindowRecursive?.windowId,
            file: file,
            line: line,
        )
    }

    private func assertFocusCandidateMatches(
        _ startWindow: Window,
        direction: CardinalDirection,
        file: String = #filePath,
        line: Int = #line,
    ) {
        TreeStore.shared.refreshFromMutableTree()
        let state = TreeStore.shared.current
        let startWindowState = state.windowNode(withWindowId: startWindow.windowId).orDie()
        let mutableCandidate = startWindow.closestParent(hasChildrenInDirection: direction, withLayout: nil)
            .flatMap { parent, ownIndex in
                parent.children[ownIndex + direction.focusOffset]
                    .findLeafWindowRecursive(snappedTo: direction.opposite)
            }
        assertEquals(
            state.focusWindow(from: startWindowState.id, inDirection: direction)?.windowId,
            mutableCandidate?.windowId,
            file: file,
            line: line,
        )
    }

    private func assertCurrentWorkspaceStateMatches(
        _ expectedState: TreeState,
        _ workspace: Workspace,
        file: String = #filePath,
        line: Int = #line,
    ) {
        TreeStore.shared.refreshFromMutableTree()
        let actualState = TreeStore.shared.current
        let expectedWorkspace = expectedState.workspace(named: workspace.name).orDie()
        let actualWorkspace = actualState.workspace(named: workspace.name).orDie()
        assertEquals(expectedState.invariantViolations(), [], file: file, line: line)
        assertEquals(actualState.invariantViolations(), [], file: file, line: line)
        assertEquals(
            expectedState.layoutDescription(for: expectedWorkspace.id),
            actualState.layoutDescription(for: actualWorkspace.id),
            file: file,
            line: line,
        )
    }

    private func nextUnusedNodeId(in state: TreeState) -> TreeNodeId {
        TreeNodeId(rawValue: (state.nodes.keys.map(\.rawValue).max() ?? 0) + 1)
    }

    private func assertNormalizedStateMatchesMutableNormalization(
        _ workspace: Workspace,
        file: String = #filePath,
        line: Int = #line,
    ) {
        TreeStore.shared.refreshFromMutableTree()
        let normalized = TreeStore.shared.current.normalized(
            flattenContainers: config.enableNormalizationFlattenContainers,
            oppositeOrientationForNestedContainers: config.enableNormalizationOppositeOrientationForNestedContainers,
        )
        assertEquals(normalized.invariantViolations(), [], file: file, line: line)

        workspace.normalizeContainers()
        TreeStore.shared.refreshFromMutableTree()
        let mutableNormalized = TreeStore.shared.current
        assertEquals(mutableNormalized.invariantViolations(), [], file: file, line: line)

        let normalizedWorkspace = normalized.workspace(named: workspace.name).orDie()
        let mutableWorkspace = mutableNormalized.workspace(named: workspace.name).orDie()
        assertEquals(
            normalized.layoutDescription(for: normalizedWorkspace.id),
            mutableNormalized.layoutDescription(for: mutableWorkspace.id),
            file: file,
            line: line,
        )
    }
}
