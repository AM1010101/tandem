import Foundation

/// Where the CLI's own output goes.
///
/// Native libraries sometimes print straight to descriptor 1: Core ML says
/// "E5RT encountered an STL exception..." when Bark loads, with no newline,
/// right in front of the JSON an agent is about to parse. So at startup
/// `claim()` keeps the real stdout on a private descriptor for the CLI and
/// points descriptor 1 (and C's `stdout`, which libraries' printf and
/// std::cout use) at stderr. Everything the CLI means to print goes through
/// `line(_:)`.
///
/// Writes go straight to the descriptor with no buffer, one line per write,
/// so `tandem watch` and wait progress show up as they happen and nothing is
/// left unflushed when the process calls `exit()` or a signal ends it.
enum StandardOutput {
    nonisolated(unsafe) private(set) static var handle = FileHandle.standardOutput

    static func claim() {
        fflush(stdout)
        let saved = dup(STDOUT_FILENO)
        guard saved >= 0 else { return }
        // Children the CLI starts (ffmpeg and the like) shouldn't inherit it.
        _ = fcntl(saved, F_SETFD, FD_CLOEXEC)
        guard dup2(STDERR_FILENO, STDOUT_FILENO) >= 0 else {
            close(saved)
            return
        }
        // Stray library lines read better on stderr a line at a time.
        setvbuf(stdout, nil, _IOLBF, 0)
        handle = FileHandle(fileDescriptor: saved, closeOnDealloc: false)
    }

    /// Writes `text` and a newline, like `print`.
    static func line(_ text: String) {
        write(text + "\n")
    }

    static func write(_ text: String) {
        // A reader that has gone away (`tandem watch | head`) ends the
        // process with SIGPIPE, as print did, unless the command ignores it.
        try? handle.write(contentsOf: Data(text.utf8))
    }

    /// For tests: prints the way Core ML does, both through the descriptor
    /// and through C's stdout, with no newline, so a test can check none of
    /// it reaches the CLI's output.
    static func printStrayLinesForTests(environment: [String: String]) {
        guard environment["TANDEM_TEST_STRAY_STDOUT"] == "1" else { return }
        let raw = "E5RT encountered an STL exception (write). msg = Failed to PropagateInputTensorShapes"
        _ = raw.withCString { Darwin.write(STDOUT_FILENO, $0, strlen($0)) }
        fputs("E5RT encountered an STL exception (stdio). msg = Failed to PropagateInputTensorShapes", stdout)
        fflush(stdout)
    }
}
