import Foundation

/// The shell a test starts reads nothing of the user's: a login zsh takes its startup files from
/// ZDOTDIR, here an empty folder, so a test never stops at a framework's update prompt (oh-my-zsh
/// asks before updating, on a terminal), waits on a slow profile or finds SSH_AUTH_SOCK pointed
/// elsewhere. Set once for the whole run and never put back: suites run at once, and one putting
/// the user's ZDOTDIR back would hand it to another's shell starting at that moment.
enum TestShell {
    static let clean: Void = {
        let empty = FileManager.default.temporaryDirectory.appending(path: "oricode-test-zdotdir-\(getpid())")
        try? FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        setenv("ZDOTDIR", empty.path, 1)
        setenv("SHELL", "/bin/zsh", 1)
    }()
}
