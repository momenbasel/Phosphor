import Foundation

/// Runs shell commands and captures output. Core utility for all libimobiledevice interactions.
enum Shell {

    struct Result {
        let exitCode: Int32
        let stdout: String
        let stderr: String

        var succeeded: Bool { exitCode == 0 }
        var output: String { stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
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

    /// Run a command synchronously and return the result.
    @discardableResult
    static func run(_ command: String, arguments: [String] = [], timeout: TimeInterval = 60) -> Result {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.environment = environmentWithToolPaths()

        do {
            try process.run()
        } catch {
            return Result(exitCode: -1, stdout: "", stderr: "Failed to launch: \(error.localizedDescription)")
        }

        let stdoutQueue = DispatchQueue(label: "com.phosphor.shell.stdout")
        let stderrQueue = DispatchQueue(label: "com.phosphor.shell.stderr")
        var stdoutData = Data()
        var stderrData = Data()
        let readGroup = DispatchGroup()

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

        let waitSemaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            waitSemaphore.signal()
        }

        var timedOut = false
        if waitSemaphore.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if waitSemaphore.wait(timeout: .now() + 2) == .timedOut {
                process.interrupt()
            }
        }

        _ = readGroup.wait(timeout: .now() + 2)

        var stderr = String(data: stderrData, encoding: .utf8) ?? ""
        if timedOut {
            let timeoutMessage = "Command timed out after \(Int(timeout))s"
            stderr = stderr.isEmpty ? timeoutMessage : stderr + "\n" + timeoutMessage
        }

        return Result(
            exitCode: timedOut ? -2 : process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: stderr
        )
    }

    /// Run a command asynchronously.
    static func runAsync(_ command: String, arguments: [String] = [], timeout: TimeInterval = 300) async -> Result {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = run(command, arguments: arguments, timeout: timeout)
                continuation.resume(returning: result)
            }
        }
    }

    /// Run a command with real-time output streaming via callback. Returns Process for termination.
    @discardableResult
    static func runStreaming(
        _ command: String,
        arguments: [String] = [],
        onOutput: @escaping (String) -> Void,
        onError: @escaping (String) -> Void = { _ in },
        completion: @escaping (Int32) -> Void
    ) -> Process? {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.environment = environmentWithToolPaths()

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

        process.terminationHandler = { proc in
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async { completion(proc.terminationStatus) }
        }

        do {
            try process.run()
            return process
        } catch {
            onError("Failed to launch: \(error.localizedDescription)")
            completion(-1)
            return nil
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
