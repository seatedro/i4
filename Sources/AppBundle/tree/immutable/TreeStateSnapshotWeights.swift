import AppKit

extension TreeState {
    func snapshotBindingWeight(of nodeId: TreeNodeId) -> CGFloat {
        guard let parentId = parentId(of: nodeId),
              case .container(let parent) = nodes[parentId],
              parent.kind == .tiling,
              parent.orientation != nil
        else {
            return 1
        }
        return nodes[nodeId]?.snapshotStoredAdaptiveWeight ?? 1
    }
}

extension TreeNodeState {
    fileprivate var snapshotStoredAdaptiveWeight: CGFloat? {
        switch self {
            case .workspace: nil
            case .container(let state): state.adaptiveWeight
            case .window(let state): state.adaptiveWeight
        }
    }
}
