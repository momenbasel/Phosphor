import Foundation
import Darwin

/// Runs shell commands and captures output. Core utility for all libimobiledevice interactions.
enum Shell {

    struct Result {
        let exitCode: Int32
        let stdout: String
        let stderr: String

        var succeeded: Bool { exitCode == 0 }
        var output: String { stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// A POSIX-spawned child. Launching with `POSIX_SPAWN_SETSID` gives every
    /// managed command a session/process group before its first instruction.
    final class ManagedProcess: @unchecked Sendable {
        let processIdentifier: pid_t
        fileprivate let processTree: ProcessTree

        init(processIdentifier: pid_t) {
            self.processIdentifier = processIdentifier
            // Capture the dedicated session/group while the leader is guaranteed
            // to exist. Reconstructing this after waitpid() has reaped the leader
            // loses the group identity and can miss a still-writing descendant.
            self.processTree = ProcessTree(rootProcessID: processIdentifier)
        }

        var isRunning: Bool {
            Shell.processExists(processIdentifier)
        }
    }

    private static func launchManagedProcess(
        _ command: String,
        arguments: [String],
        environment: [String: String],
        stdoutPipe: Pipe,
        stderrPipe: Pipe
    ) throws -> ManagedProcess {
        var fileActions: posix_spawn_file_actions_t? = nil
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        guard posix_spawn_file_actions_adddup2(&fileActions, stdoutPipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&fileActions, stderrPipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        var attributes: posix_spawnattr_t? = nil
        guard posix_spawnattr_init(&attributes) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { posix_spawnattr_destroy(&attributes) }
        // CLOEXEC_DEFAULT is not optional here. Without it the child inherits
        // every descriptor the app has open, including the write ends of OTHER
        // in-flight Shell commands' stdout pipes. The parent closes only its own
        // copy, so readDataToEndOfFile never sees EOF and that unrelated command
        // returns exit code 0 with empty output. Measured before the flag was
        // added: 40 of 60 concurrent commands lost stdout entirely. The two
        // posix_spawn_file_actions_adddup2 calls below still work under it -
        // that is the documented pairing.
        let spawnFlags = Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT)
        guard posix_spawnattr_setflags(&attributes, spawnFlags) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        let argvStrings = ["/usr/bin/env", command] + arguments
        let environmentStrings = environment.map { "\($0.key)=\($0.value)" }
        let argv = argvStrings.map { strdup($0) } + [nil]
        let envp = environmentStrings.map { strdup($0) } + [nil]
        defer {
            argv.dropLast().forEach { free($0) }
            envp.dropLast().forEach { free($0) }
        }

        var processID: pid_t = 0
        let status = argv.withUnsafeBufferPointer { argvBuffer in
            envp.withUnsafeBufferPointer { environmentBuffer in
                posix_spawn(
                    &processID,
                    "/usr/bin/env",
                    &fileActions,
                    &attributes,
                    UnsafeMutablePointer(mutating: argvBuffer.baseAddress),
                    UnsafeMutablePointer(mutating: environmentBuffer.baseAddress)
                )
            }
        }
        guard status == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(status))
        }
        stdoutPipe.fileHandleForWriting.closeFile()
        stderrPipe.fileHandleForWriting.closeFile()
        return ManagedProcess(processIdentifier: processID)
    }

    private final class AsyncCommandState: @unchecked Sendable {
        private let lock = NSLock()
        private var stdoutData = Data()
        private var stderrData = Data()
        private var didFinish = false
        private var timedOut = false
        private var watchdog: Task<Void, Never>?

        /// Hand the timeout watchdog to the state so it can be cancelled the moment the
        /// command finishes. Without this the watchdog sleeps the full timeout (default
        /// 300s) after the process already exited, holding the pipe file descriptors open
        /// the whole time — under Phosphor's frequent device probes that leaks fds.
        func attachWatchdog(_ task: Task<Void, Never>) {
            lock.lock()
            let alreadyFinished = didFinish
            if !alreadyFinished { watchdog = task }
            lock.unlock()
            if alreadyFinished { task.cancel() }
        }

        func append(_ data: Data, toStdout: Bool) {
            guard !data.isEmpty else { return }
            lock.lock()
            if toStdout {
                stdoutData.append(data)
            } else {
                stderrData.append(data)
            }
            lock.unlock()
        }

        func markTimedOut() -> Bool {
            lock.lock()
            guard !didFinish else {
                lock.unlock()
                return false
            }
            timedOut = true
            lock.unlock()
            return true
        }

        func hasTimedOut() -> Bool {
            lock.lock()
            let value = timedOut
            lock.unlock()
            return value
        }

        func hasFinished() -> Bool {
            lock.lock()
            let value = didFinish
            lock.unlock()
            return value
        }

        func finish(timeout: TimeInterval, exitCode: Int32) -> Result? {
            lock.lock()
            guard !didFinish else {
                lock.unlock()
                return nil
            }
            didFinish = true
            let didTimeOut = timedOut
            let pendingWatchdog = watchdog
            watchdog = nil
            let stdout = stdoutData
            var stderr = String(data: stderrData, encoding: .utf8) ?? ""
            if didTimeOut {
                let timeoutMessage = "Command timed out after \(Int(timeout))s"
                stderr = stderr.isEmpty ? timeoutMessage : stderr + "\n" + timeoutMessage
            }
            lock.unlock()

            // Free the watchdog's captured Process/pipe references immediately.
            pendingWatchdog?.cancel()

            return Result(
                exitCode: didTimeOut ? -2 : exitCode,
                stdout: String(data: stdout, encoding: .utf8) ?? "",
                stderr: stderr
            )
        }
    }

    private final class StreamingCommandState: @unchecked Sendable {
        private let lock = NSLock()
        private var didFinish = false
        private var timedOut = false
        private var timeoutTask: Task<Void, Never>?

        func hasFinished() -> Bool {
            lock.lock()
            let value = didFinish
            lock.unlock()
            return value
        }

        func markTimedOut() -> Bool {
            lock.lock()
            guard !didFinish else {
                lock.unlock()
                return false
            }
            timedOut = true
            lock.unlock()
            return true
        }

        func hasTimedOut() -> Bool {
            lock.lock()
            let value = timedOut
            lock.unlock()
            return value
        }

        func setTimeoutTask(_ task: Task<Void, Never>) {
            lock.lock()
            if didFinish {
                lock.unlock()
                task.cancel()
                return
            }
            timeoutTask = task
            lock.unlock()
        }

        func finish(exitCode: Int32) -> Int32? {
            lock.lock()
            guard !didFinish else {
                lock.unlock()
                return nil
            }
            didFinish = true
            let result = timedOut ? -2 : exitCode
            let task = timeoutTask
            timeoutTask = nil
            lock.unlock()
            task?.cancel()
            return result
        }
    }

    private static func environmentWithToolPaths() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extra = "\(home)/.local/bin:\(home)/.local/pipx/venvs/pymobiledevice3/bin:/opt/homebrew/bin:/usr/local/bin"
        if let path = environment["PATH"], !path.isEmpty {
            environment["PATH"] = extra + ":" + path
        } else {
            environment["PATH"] = extra + ":/usr/bin:/bin"
        }
        return environment
    }

    /// Supervises the session/process group created atomically by posix_spawn.
    /// Group signalling covers descendants forked after a snapshot, while the
    /// PID snapshot remains a compatibility fallback should session setup fail.
    fileprivate final class ProcessTree: @unchecked Sendable {
        private let lock = NSLock()
        private let rootProcessID: pid_t
        private let processGroupID: pid_t?
        private var knownProcessIDs: Set<pid_t>

        init(rootProcessID: pid_t, hasDedicatedProcessGroup: Bool = true) {
            self.rootProcessID = rootProcessID
            self.knownProcessIDs = [rootProcessID]
            // Do not call setpgid from the parent: that reintroduces the launch
            // race this runner exists to remove. POSIX_SPAWN_SETSID established
            // the group before the command's first instruction.
            self.processGroupID = hasDedicatedProcessGroup && Darwin.getpgid(rootProcessID) == rootProcessID
                ? rootProcessID
                : nil
        }

        func terminate(with signal: Int32) {
            if let processGroupID {
                // Negative PID targets every current member, including a child
                // forked after timeout discovery or after the leader has exited.
                _ = Darwin.kill(-processGroupID, signal)
                return
            }

            recordDescendants()
            signalKnownProcesses(signal)
            // Capture once more while the leader is still alive to catch a child
            // created between discovery and the first signal.
            recordDescendants()
            signalKnownProcesses(signal)
        }

        func cleanupComplete() -> Bool {
            // Reap first: the leader may have exited already and be sitting as a
            // zombie, which kill(-pgid, 0) still reports as a live group member.
            // Polling without reaping meant the grace window could never be
            // satisfied and SIGTERM always escalated to SIGKILL.
            Shell.reapIfExited(rootProcessID)
            if let processGroupID {
                return !Shell.processGroupExists(processGroupID)
            }
            lock.lock()
            let processIDs = knownProcessIDs
            lock.unlock()
            return processIDs.allSatisfy { !Shell.processExists($0) }
        }

        private func recordDescendants() {
            let descendants = Shell.descendantProcessIDs(of: rootProcessID)
            lock.lock()
            knownProcessIDs.formUnion(descendants)
            lock.unlock()
        }

        private func signalKnownProcesses(_ signal: Int32) {
            lock.lock()
            let processIDs = knownProcessIDs
            lock.unlock()

            // Work from the leaves inward. This lets parents reap their children
            // normally when possible, before the leader itself is signalled.
            for processID in processIDs where processID != rootProcessID {
                _ = Darwin.kill(processID, signal)
            }
            _ = Darwin.kill(rootProcessID, signal)
        }
    }

    private static func descendantProcessIDs(of rootProcessID: pid_t) -> Set<pid_t> {
        guard rootProcessID > 0 else { return [] }
        var descendants: Set<pid_t> = []
        var pending = [rootProcessID]

        while let parent = pending.popLast() {
            var children = Array(repeating: pid_t(0), count: 1_024)
            let reported = children.withUnsafeMutableBufferPointer {
                proc_listchildpids(parent, $0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.stride))
            }
            let count = min(max(0, Int(reported)), children.count)
            for child in children.prefix(count) where child > 0 && descendants.insert(child).inserted {
                pending.append(child)
            }
        }
        return descendants
    }

    private static func processExists(_ processID: pid_t) -> Bool {
        guard processID > 0 else { return false }
        if Darwin.kill(processID, 0) == 0 { return true }
        return errno == EPERM
    }

    private static func processGroupExists(_ processGroupID: pid_t) -> Bool {
        guard processGroupID > 0 else { return false }
        if Darwin.kill(-processGroupID, 0) == 0 { return true }
        return errno == EPERM
    }

    /// Reap the leader if it has already exited. `kill(-pgid, 0)` succeeds for a
    /// zombie, so without this an exited-but-unreaped child counts as "still
    /// alive" for the whole grace window and every termination escalates to
    /// SIGKILL - including cancelling a backup or restore mid-write, which is
    /// the one place in this app where a forced kill costs the user data.
    @discardableResult
    private static func reapIfExited(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return true }
        var status: Int32 = 0
        let waited = waitpid(pid, &status, WNOHANG)
        if waited == pid { return true }
        return waited < 0 && errno == ECHILD
    }

    /// Reap the leader, but never block a Task forever waiting for a child that
    /// will not die. Returns true if the child was reaped inside the window.
    @discardableResult
    private static func reapWithinDeadline(_ pid: pid_t, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if reapIfExited(pid) { return true }
            if Date() >= deadline { return false }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    private static func terminateProcessTree(_ tree: ProcessTree, signal: Int32) {
        tree.terminate(with: signal)
    }

    private static func waitForProcessTreeCleanup(_ tree: ProcessTree, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !tree.cleanupComplete() {
            guard Date() < deadline else { return false }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return true
    }

    private static func waitForProcessTreeCleanupSynchronously(_ tree: ProcessTree, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !tree.cleanupComplete() {
            guard Date() < deadline else { return false }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return true
    }

    /// A timeout cannot leave a TERM-ignoring process group alive long enough to
    /// fork an escaped worker. Give cooperative commands a very short grace, then
    /// kill the *entire* dedicated group (not just the original leader).
    /// Grace given to a one-shot probe (`ideviceinfo`, `pymobiledevice3 list`).
    /// Killing one of these early costs nothing, and a slow timeout here is felt
    /// on every poll, so keep it short.
    static let probeTerminationGrace: TimeInterval = 0.25

    /// Grace given to a streaming command. `runStreaming` is what drives
    /// idevicebackup2 and pymobiledevice3 backup/restore, which flush and close
    /// the snapshot they are part-way through writing when they take SIGTERM.
    /// The 50ms this replaced meant they never got there, so a timeout or a
    /// user cancel amputated the backup. Now that cleanupComplete() reaps, a
    /// child that exits promptly still returns in milliseconds - this is only
    /// the ceiling for one that needs the time.
    static let streamTerminationGrace: TimeInterval = 2.0

    private static func terminateTimedOutTree(
        _ tree: ProcessTree,
        grace: TimeInterval = probeTerminationGrace
    ) async {
        terminateProcessTree(tree, signal: SIGTERM)
        if !(await waitForProcessTreeCleanup(tree, timeout: grace)) {
            terminateProcessTree(tree, signal: SIGKILL)
            _ = await waitForProcessTreeCleanup(tree, timeout: 1)
        }
    }

    private static func terminateTimedOutTreeSynchronously(_ tree: ProcessTree) {
        terminateProcessTree(tree, signal: SIGTERM)
        if !waitForProcessTreeCleanupSynchronously(tree, timeout: 2.0) {
            terminateProcessTree(tree, signal: SIGKILL)
            _ = waitForProcessTreeCleanupSynchronously(tree, timeout: 1)
        }
    }

    /// Run a command synchronously and return the result.
    @discardableResult
    static func run(_ command: String, arguments: [String] = [], timeout: TimeInterval = 60) -> Result {
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let process: ManagedProcess
        do {
            process = try launchManagedProcess(
                command,
                arguments: arguments,
                environment: environmentWithToolPaths(),
                stdoutPipe: stdoutPipe,
                stderrPipe: stderrPipe
            )
        } catch {
            return Result(exitCode: -1, stdout: "", stderr: "Failed to launch: \(error.localizedDescription)")
        }

        let stdoutQueue = DispatchQueue(label: "com.phosphor.shell.stdout")
        let stderrQueue = DispatchQueue(label: "com.phosphor.shell.stderr")
        var stdoutData = Data()
        var stderrData = Data()
        let readGroup = DispatchGroup()
        let waitSemaphore = DispatchSemaphore(value: 0)
        let processTree = process.processTree
        let exitSource = DispatchSource.makeProcessSource(
            identifier: process.processIdentifier,
            eventMask: .exit,
            queue: DispatchQueue(label: "com.phosphor.shell.sync-exit")
        )
        var exitCode: Int32 = -1
        exitSource.setEventHandler {
            var status: Int32 = 0
            let waited = waitpid(process.processIdentifier, &status, 0)
            exitCode = waited == process.processIdentifier && status & 0x7f == 0
                ? (status >> 8) & 0xff
                : -1
            waitSemaphore.signal()
        }
        exitSource.resume()

        readGroup.enter()
        stdoutQueue.async {
            stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            readGroup.leave()
        }
        readGroup.enter()
        stderrQueue.async {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            readGroup.leave()
        }

        let timedOut = waitSemaphore.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            terminateTimedOutTreeSynchronously(processTree)
            _ = waitSemaphore.wait(timeout: .now() + 1)
        }
        exitSource.cancel()
        _ = readGroup.wait(timeout: .now() + 2)

        var stderr = String(data: stderrData, encoding: .utf8) ?? ""
        if timedOut {
            let timeoutMessage = "Command timed out after \(Int(timeout))s"
            stderr = stderr.isEmpty ? timeoutMessage : stderr + "\n" + timeoutMessage
        }
        return Result(
            exitCode: timedOut ? -2 : exitCode,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: stderr
        )
    }

    /// Run a command asynchronously.
    ///
    /// `extraEnvironment` is merged over the inherited environment. Use it to pass
    /// secrets (for example `BACKUP_PASSWORD`) that must not appear in the process
    /// argument list, where any local process could read them via `ps`.
    static func runAsync(_ command: String, arguments: [String] = [], timeout: TimeInterval = 300, extraEnvironment: [String: String] = [:]) async -> Result {
        await withCheckedContinuation { continuation in
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            let state = AsyncCommandState()
            var environment = environmentWithToolPaths()
            for (key, value) in extraEnvironment { environment[key] = value }

            let process: ManagedProcess
            do {
                process = try launchManagedProcess(
                    command,
                    arguments: arguments,
                    environment: environment,
                    stdoutPipe: stdoutPipe,
                    stderrPipe: stderrPipe
                )
            } catch {
                continuation.resume(returning: Result(
                    exitCode: -1,
                    stdout: "",
                    stderr: "Failed to launch: \(error.localizedDescription)"
                ))
                return
            }

            let processTree = process.processTree
            let exitSource = DispatchSource.makeProcessSource(
                identifier: process.processIdentifier,
                eventMask: .exit,
                queue: DispatchQueue(label: "com.phosphor.shell.exit")
            )

            @Sendable func finish(exitCode: Int32) {
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                state.append(stdoutPipe.fileHandleForReading.availableData, toStdout: true)
                state.append(stderrPipe.fileHandleForReading.availableData, toStdout: false)
                guard let result = state.finish(timeout: timeout, exitCode: exitCode) else { return }
                exitSource.cancel()
                continuation.resume(returning: result)
            }

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                state.append(handle.availableData, toStdout: true)
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                state.append(handle.availableData, toStdout: false)
            }
            exitSource.setEventHandler {
                guard !state.hasTimedOut() else { return }
                var status: Int32 = 0
                let waited = waitpid(process.processIdentifier, &status, 0)
                let exitCode: Int32 = waited == process.processIdentifier && status & 0x7f == 0
                    ? (status >> 8) & 0xff
                    : -1
                finish(exitCode: exitCode)
            }
            exitSource.resume()

            let watchdogTask = Task {
                let nanoseconds = UInt64(max(timeout, 0) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                guard !Task.isCancelled, state.markTimedOut() else { return }
                await terminateTimedOutTree(processTree)
                // The process-exit source deliberately yields to the timeout
                // winner, so that winner must also reap the session leader.
                // Non-blocking: a leader wedged uninterruptibly in a USB or
                // lockdownd ioctl (flaky cable, stalled network destination -
                // exactly what timeouts are for) does not accept SIGKILL until
                // the kernel returns, and a blocking waitpid here parked the
                // Task forever. finish() then never ran, so the continuation in
                // BackupManager never resumed and the UI sat on "Backing up..."
                // with no timeout and no cancel. Reap if we can, give up if we
                // cannot, but always complete.
                reapWithinDeadline(process.processIdentifier, timeout: 1.0)
                finish(exitCode: -1)
            }
            state.attachWatchdog(watchdogTask)
        }
    }

    /// Run a command with real-time output streaming via callback. Returns a managed
    /// session leader that `Shell.terminate` can stop together with descendants.
    ///
    /// Long-running one-shot device operations (backup/restore) should pass a timeout so a
    /// wedged child process cannot leave the UI waiting forever. Truly open-ended streams
    /// such as syslog should keep the default `nil` timeout and be stopped explicitly by
    /// the caller.
    @discardableResult
    static func runStreaming(
        _ command: String,
        arguments: [String] = [],
        timeout: TimeInterval? = nil,
        environment: [String: String]? = nil,
        onOutput: @escaping (String) -> Void,
        onError: @escaping (String) -> Void = { _ in },
        completion: @escaping (Int32) -> Void
    ) -> ManagedProcess? {
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let state = StreamingCommandState()
        let process: ManagedProcess
        do {
            process = try launchManagedProcess(
                command,
                arguments: arguments,
                environment: environment ?? environmentWithToolPaths(),
                stdoutPipe: stdoutPipe,
                stderrPipe: stderrPipe
            )
        } catch {
            onError("Failed to launch: \(error.localizedDescription)")
            completion(-1)
            return nil
        }

        let processTree = process.processTree
        let exitSource = DispatchSource.makeProcessSource(
            identifier: process.processIdentifier,
            eventMask: .exit,
            queue: DispatchQueue(label: "com.phosphor.shell.stream-exit")
        )
        @Sendable func finish(exitCode: Int32) {
            guard let resolvedExitCode = state.finish(exitCode: exitCode) else { return }
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            exitSource.cancel()
            DispatchQueue.main.async { completion(resolvedExitCode) }
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let str = String(data: data, encoding: .utf8) {
                DispatchQueue.main.async { onOutput(str) }
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let str = String(data: data, encoding: .utf8) {
                DispatchQueue.main.async { onError(str) }
            }
        }
        exitSource.setEventHandler {
            guard !state.hasTimedOut() else { return }
            var status: Int32 = 0
            let waited = waitpid(process.processIdentifier, &status, 0)
            let exitCode: Int32 = waited == process.processIdentifier && status & 0x7f == 0
                ? (status >> 8) & 0xff
                : -1
            finish(exitCode: exitCode)
        }
        exitSource.resume()

        if let timeout {
            let timeoutTask = Task {
                let nanoseconds = UInt64(max(timeout, 0) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                guard !Task.isCancelled, state.markTimedOut() else { return }
                DispatchQueue.main.async { onError("Command timed out after \(Int(timeout))s") }
                await terminateTimedOutTree(processTree, grace: streamTerminationGrace)
                // The exit handler does not reap once timeout owns completion.
                // Bounded for the same reason as the runAsync watchdog: an
                // unkillable child must not strand the streaming completion.
                reapWithinDeadline(process.processIdentifier, timeout: 1.0)
                guard !Task.isCancelled else { return }
                finish(exitCode: -1)
            }
            state.setTimeoutTask(timeoutTask)
        }

        return process
    }

    /// Terminate a long-running managed command and every descendant it has spawned.
    static func terminate(_ process: ManagedProcess) {
        Task { await terminateAndWait(process) }
    }

    /// Awaited variant used by application termination. AppKit must not complete
    /// Quit while an idevicebackup2/pymobiledevice process group can still write.
    static func terminateAndWait(_ process: ManagedProcess) async {
        guard process.processIdentifier > 0 else { return }
        let processTree = process.processTree
        terminateProcessTree(processTree, signal: SIGTERM)
        // Give backup tools their normal flush window before escalation. The
        // process-tree helper verifies descendants as well as the session leader.
        if !(await waitForProcessTreeCleanup(processTree, timeout: streamTerminationGrace)) {
            terminateProcessTree(processTree, signal: SIGKILL)
            _ = await waitForProcessTreeCleanup(processTree, timeout: 1)
        }
    }

    /// Check if a command-line tool is available.
    static func which(_ tool: String) -> String? {
        let result = run("which", arguments: [tool])
        return result.succeeded ? result.output : nil
    }

    /// Check if required device-management tools are installed.
    static func checkDependencies() -> [String: Bool] {
        let tools = [
            "idevice_id",
            "ideviceinfo",
            "idevicepair",
            "idevicebackup2",
            "idevicediagnostics",
            "idevicesyslog",
            "idevicename",
            "idevicescreenshot",
            "ideviceinstaller"
        ]
        var status: [String: Bool] = [:]
        for tool in tools {
            status[tool] = which(tool) != nil
        }

        // Check pymobiledevice3 using the same resolver used by the app's device
        // operations. GUI apps often do not inherit the terminal's Python/PATH,
        // and pipx installs expose a runnable binary rather than an importable
        // module from Homebrew's `python3`.
        status["pymobiledevice3"] = PyMobileDevice.available()

        return status
    }
}
