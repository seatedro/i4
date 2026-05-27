import Common

struct BalanceSizesCommand: Command {
    let args: BalanceSizesCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        TreeStore.shared.refreshFromMutableTree()
        let state = TreeStore.shared.current
        guard let workspace = state.workspace(named: target.workspace.name),
              let nextState = state.balancingWorkspace(workspace.id)
        else { return .fail }
        return .from(bool: TreeStore.shared.commit(nextState))
    }
}
