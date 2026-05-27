import AppKit
import Common

struct JoinWithCommand: Command {
    let args: JoinWithCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        let direction = args.direction.val
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        guard let currentWindow = target.windowOrNil else {
            return .fail(io.err(noWindowIsFocused))
        }
        guard currentWindow.closestParent(hasChildrenInDirection: direction, withLayout: nil) != nil else {
            return .fail(io.err("No windows in the specified direction"))
        }
        TreeStore.shared.refreshFromMutableTree()
        let state = TreeStore.shared.current
        guard let windowState = state.windowNode(withWindowId: currentWindow.windowId),
              let nextState = state.joiningWindowWithSibling(
                  windowState.id,
                  direction: direction,
                  newContainerId: TreeStore.shared.allocateNodeId(),
              )
        else { return .fail }
        return .from(bool: TreeStore.shared.commit(nextState))
    }
}
