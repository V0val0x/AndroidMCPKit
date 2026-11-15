import Foundation
import Darwin

/// Centralized supervisor for child `Process` instances (`adb`, etc.) with timeout watchdogs
/// and clean `SIGTERM` -> `SIGKILL` termination on cancellation or shutdown.
public final class ProcessSupervisor: @unchecked Sendable {
    public static let shared = ProcessSupervisor()

    private struct TrackedProcess {
        let process: Process
        let tag: String
    }

    private let lock = NSLock()
    private var tracked: [UUID: TrackedProcess] = [:]

    private init() {}

    /// Registers a running (or about-to-run) `Process` and automatically unregisters it when it exits.
    @discardableResult
    public func register(_ process: Process, tag: String) -> UUID {
        let id = UUID()
        let previousHandler = process.terminationHandler
        process.terminationHandler = { [weak self] proc in
            self?.unregister(id)
            previousHandler?(proc)
        }
        lock.lock()
        tracked[id] = TrackedProcess(process: process, tag: tag)
        lock.unlock()
        return id
    }

    /// Removes a process from the active registry.
    public func unregister(_ id: UUID) {
        lock.lock()
        tracked.removeValue(forKey: id)
        lock.unlock()
    }

    /// Returns the number of currently tracked running processes.
    public var activeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        tracked = tracked.filter { $0.value.process.isRunning }
        return tracked.count
    }

    /// Terminates a single process gracefully with `SIGTERM`, escalating to `SIGKILL` after `gracePeriodMs` if still alive.
    public func terminateProcess(_ process: Process, gracePeriodMs: UInt64 = 350) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        process.terminate()

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(Int(gracePeriodMs))) {
            if process.isRunning && pid > 0 {
                kill(pid, SIGKILL)
            }
        }
    }

    /// Terminates all tracked processes matching `tag` (`SIGTERM` -> `SIGKILL` fallback).
    public func terminateProcesses(withTag tag: String, gracePeriodMs: UInt64 = 350) {
        lock.lock()
        let matches = tracked.filter { $0.value.tag == tag }
        for key in matches.keys {
            tracked.removeValue(forKey: key)
        }
        lock.unlock()

        for (_, entry) in matches {
            terminateProcess(entry.process, gracePeriodMs: gracePeriodMs)
        }
    }

    /// Terminates every tracked child process.
    public func terminateAllProcesses(synchronousWait: Bool = false, gracePeriodMs: UInt64 = 250) {
        lock.lock()
        let all = Array(tracked.values)
        tracked.removeAll()
        lock.unlock()

        let running = all.map(\.process).filter { $0.isRunning }
        guard !running.isEmpty else { return }

        for proc in running {
            proc.terminate()
        }

        if synchronousWait {
            let deadline = Date().addingTimeInterval(Double(gracePeriodMs) / 1000.0)
            while Date() < deadline {
                if running.allSatisfy({ !$0.isRunning }) {
                    return
                }
                Thread.sleep(forTimeInterval: 0.025)
            }
            for proc in running where proc.isRunning {
                let pid = proc.processIdentifier
                if pid > 0 {
                    kill(pid, SIGKILL)
                }
            }
        } else {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(Int(gracePeriodMs))) {
                for proc in running where proc.isRunning {
                    let pid = proc.processIdentifier
                    if pid > 0 {
                        kill(pid, SIGKILL)
                    }
                }
            }
        }
    }

    /// Executes a binary asynchronously with a strict timeout watchdog and Swift `Task` cancellation support.
    public func runProcess(
        executablePath: String,
        arguments: [String],
        environment: [String: String]? = nil,
        timeoutSeconds: Double = 10.0,
        tag: String = "adb"
    ) async throws -> Data {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw NSError(
                domain: "AndroidMCPKit.ProcessSupervisor",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Executable not found or not executable at '\(executablePath)'."]
            )
        }
        try Task.checkCancellation()

        final class ExecutionState: @unchecked Sendable {
            let lock = NSLock()
            var hasResumed = false
            var isCancelled = false
            var process: Process?
            var trackedId: UUID?
            var timer: DispatchSourceTimer?
            var continuation: CheckedContinuation<Data, Error>?

            func cancel(supervisor: ProcessSupervisor) {
                lock.lock()
                isCancelled = true
                let proc = process
                let tid = trackedId
                let tmr = timer
                let cont = (!hasResumed) ? continuation : nil
                if cont != nil {
                    hasResumed = true
                    continuation = nil
                }
                lock.unlock()

                tmr?.cancel()
                if let tid {
                    supervisor.unregister(tid)
                }
                if let proc {
                    supervisor.terminateProcess(proc, gracePeriodMs: 250)
                }
                cont?.resume(throwing: CancellationError())
            }
        }

        let state = ExecutionState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.lock.lock()
                if state.isCancelled {
                    state.hasResumed = true
                    state.lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                state.continuation = continuation
                state.lock.unlock()

                DispatchQueue.global(qos: .userInitiated).async {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: executablePath)
                    process.arguments = arguments

                    var env = environment ?? ProcessInfo.processInfo.environment
                    let existingPath = env["PATH"] ?? ""
                    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + existingPath
                    env["ADB_MDNS_OPENSCREEN"] = "1"
                    process.environment = env

                    let stdoutPipe = Pipe()
                    let stderrPipe = Pipe()
                    process.standardOutput = stdoutPipe
                    process.standardError = stderrPipe

                    let trackedId = self.register(process, tag: tag)

                    let timer = DispatchSource.makeTimerSource(queue: .global())
                    timer.schedule(deadline: .now() + timeoutSeconds)
                    timer.setEventHandler {
                        state.lock.lock()
                        let cont = (!state.hasResumed) ? state.continuation : nil
                        if cont != nil {
                            state.hasResumed = true
                            state.continuation = nil
                        }
                        state.lock.unlock()
                        if let cont {
                            self.unregister(trackedId)
                            self.terminateProcess(process, gracePeriodMs: 250)
                            cont.resume(throwing: NSError(
                                domain: "AndroidMCPKit.ProcessSupervisor",
                                code: -1,
                                userInfo: [NSLocalizedDescriptionKey: "Command timed out after \(String(format: "%.1f", timeoutSeconds))s."]
                            ))
                        }
                    }

                    state.lock.lock()
                    if state.isCancelled || state.hasResumed {
                        state.lock.unlock()
                        self.unregister(trackedId)
                        return
                    }
                    state.process = process
                    state.trackedId = trackedId
                    state.timer = timer
                    state.lock.unlock()

                    timer.resume()

                    do {
                        try process.run()

                        var stdoutData = Data()
                        var stderrData = Data()
                        let readGroup = DispatchGroup()

                        readGroup.enter()
                        DispatchQueue.global().async {
                            stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                            readGroup.leave()
                        }

                        readGroup.enter()
                        DispatchQueue.global().async {
                            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                            readGroup.leave()
                        }

                        process.waitUntilExit()
                        readGroup.wait()
                        self.unregister(trackedId)

                        state.lock.lock()
                        timer.cancel()
                        let cont = (!state.hasResumed) ? state.continuation : nil
                        if cont != nil {
                            state.hasResumed = true
                            state.continuation = nil
                        }
                        state.lock.unlock()

                        if let cont {
                            if process.terminationStatus == 0 {
                                cont.resume(returning: stdoutData)
                            } else {
                                let errStr = String(decoding: stderrData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                                let outStr = String(decoding: stdoutData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                                cont.resume(throwing: NSError(
                                    domain: "AndroidMCPKit.ProcessSupervisor",
                                    code: Int(process.terminationStatus),
                                    userInfo: [NSLocalizedDescriptionKey: errStr.isEmpty ? outStr : errStr]
                                ))
                            }
                        }
                    } catch {
                        self.unregister(trackedId)
                        state.lock.lock()
                        timer.cancel()
                        let cont = (!state.hasResumed) ? state.continuation : nil
                        if cont != nil {
                            state.hasResumed = true
                            state.continuation = nil
                        }
                        state.lock.unlock()
                        cont?.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            state.cancel(supervisor: self)
        }
    }
}
