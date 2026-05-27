import AppKit
import Common

struct SplitCommand: Command {
    let args: SplitCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        if config.enableNormalizationFlattenContainers {
            return .fail(io.err("'split' has no effect when 'enable-normalization-flatten-containers' normalization enabled. My recommendation: keep the normalizations enabled, and prefer 'join-with' over 'split'."))
        }
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        guard let window = target.windowOrNil else {
            return .fail(io.err(noWindowIsFocused))
        }
        guard let parent = window.parent else { return .fail }
        switch parent.cases {
            case .workspace:
                // Nothing to do for floating and macOS native fullscreen windows
                return .fail(io.err("Can't split floating windows"))
            case .tilingContainer(let parent):
                let orientation: Orientation = switch args.arg.val {
                    case .vertical: .v
                    case .horizontal: .h
                    case .opposite: parent.orientation.opposite
                }
                TreeStore.shared.refreshFromMutableTree()
                let state = TreeStore.shared.current
                guard let windowState = state.windowNode(withWindowId: window.windowId),
                      let nextState = state.splittingWindow(
                          windowState.id,
                          orientation: orientation,
                          newContainerId: TreeStore.shared.allocateNodeId(),
                          normalizeOppositeOrientationForNestedContainers: config.enableNormalizationOppositeOrientationForNestedContainers,
                      )
                else { return .fail }
                return .from(bool: TreeStore.shared.commit(nextState))
            case .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer, .macosHiddenAppsWindowsContainer:
                return .fail(io.err("Can't split macos fullscreen, minimized windows and windows of hidden apps. This behavior may change in the future"))
            case .macosPopupWindowsContainer:
                return .fail // Impossible
        }
    }
}
