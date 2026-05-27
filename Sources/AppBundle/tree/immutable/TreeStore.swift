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
