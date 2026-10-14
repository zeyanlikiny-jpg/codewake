import Darwin
import Foundation

// Also install a process-wide backstop for any Foundation write that bypasses
// the descriptor-level F_SETNOSIGPIPE setting.
Darwin.signal(SIGPIPE, SIG_IGN)

do {
    let journalStore: DisplayBlackoutJournalStore
    if let injectedPath = ProcessInfo.processInfo.environment[
        "LIDLESS_DISPLAY_BLACKOUT_JOURNAL_PATH"
    ], !injectedPath.isEmpty {
        journalStore = DisplayBlackoutJournalStore(
            fileURL: URL(fileURLWithPath: injectedPath, isDirectory: false)
        )
    } else {
        journalStore = DisplayBlackoutJournalStore()
    }

    let dependencies = try DisplayBlackoutWatchdogDependencies.system(
        journalStore: journalStore
    )
    let exitCode = DisplayBlackoutWatchdog(dependencies: dependencies).run()
    Darwin.exit(exitCode)
} catch {
    Darwin.exit(DisplayBlackoutWatchdog.operationErrorExitCode)
}
