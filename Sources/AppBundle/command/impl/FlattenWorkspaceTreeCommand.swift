import AppKit
import Common

struct FlattenWorkspaceTreeCommand: Command {
    let args: FlattenWorkspaceTreeCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache: Bool = true

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        TreeStore.shared.refreshFromMutableTree()
        let state = TreeStore.shared.current
        guard let workspace = state.workspace(named: target.workspace.name),
              let nextState = state.flatteningWorkspace(workspace.id)
        else { return .fail }
        return .from(bool: TreeStore.shared.commit(nextState))
    }
}
