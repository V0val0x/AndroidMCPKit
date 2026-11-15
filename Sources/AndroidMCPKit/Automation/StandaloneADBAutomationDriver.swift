import Foundation

/// Ready-to-use `AndroidAutomationDriver` powered by the `adb` CLI and Apple `Vision` (`VNRecognizeTextRequest`).
public final class StandaloneADBAutomationDriver: AndroidAutomationDriver, @unchecked Sendable {
    private let explicitADBPath: String?
    private let supervisor: ProcessSupervisor

    public init(adbPath: String? = nil, supervisor: ProcessSupervisor = .shared) {
        let trimmed = adbPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.explicitADBPath = (trimmed?.isEmpty == false) ? trimmed : nil
        self.supervisor = supervisor
    }

    /// Resolves the `adb` executable path from explicit configuration, common Homebrew/Android SDK paths, or `PATH`.
    public var resolvedADBPath: String {
        if let explicitADBPath {
            return explicitADBPath
        }

        let candidates = [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            "/opt/homebrew/share/android-commandlinetools/platform-tools/adb",
            NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }

        if let envPath = ProcessInfo.processInfo.environment["PATH"] {
            for dir in envPath.split(separator: ":") {
                let candidate = String(dir) + "/adb"
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }
        return "/opt/homebrew/bin/adb"
    }

    @discardableResult
    public func execute(arguments: [String], timeoutSeconds: Double = 8.0) async throws -> String {
        let data = try await executeData(arguments: arguments, timeoutSeconds: timeoutSeconds)
        return String(decoding: data, as: UTF8.self)
    }

    public func executeData(arguments: [String], timeoutSeconds: Double = 10.0) async throws -> Data {
        if let sIdx = arguments.firstIndex(of: "-s"), sIdx + 1 < arguments.count {
            guard AndroidCommandSanitizer.validateSerial(arguments[sIdx + 1]) else {
                throw NSError(
                    domain: "AndroidMCPKit.ADB",
                    code: 400,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid ADB device serial."]
                )
            }
        }
        return try await supervisor.runProcess(
            executablePath: resolvedADBPath,
            arguments: arguments,
            timeoutSeconds: timeoutSeconds,
            tag: "adb"
        )
    }

    // MARK: - AndroidAutomationDriver

    public func listDevices() async throws -> [AndroidDeviceInfo] {
        let output = try await execute(arguments: ["devices", "-l"], timeoutSeconds: 6.0)
        var devices: [AndroidDeviceInfo] = []

        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("List of devices") || line.hasPrefix("*") {
                continue
            }
            let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard parts.count >= 2 else { continue }

            let serial = parts[0]
            let rawState = parts[1]
            let isWifi = serial.contains(":")
            let connType = isWifi ? "Wi-Fi" : "USB"

            var model = "Android"
            var product = ""
            for part in parts.dropFirst(2) {
                if part.hasPrefix("model:") {
                    model = String(part.dropFirst("model:".count)).replacingOccurrences(of: "_", with: " ")
                } else if part.hasPrefix("product:") {
                    product = String(part.dropFirst("product:".count))
                }
            }

            var resolution: String?
            var battery: Int?
            if rawState == "device" {
                async let wmTask = try? execute(arguments: ["-s", serial, "shell", "wm", "size"], timeoutSeconds: 3.0)
                async let battTask = try? execute(arguments: ["-s", serial, "shell", "dumpsys", "battery"], timeoutSeconds: 3.0)
                if let wmOut = await wmTask, let parsedSize = Self.parseScreenSize(from: wmOut) {
                    resolution = "\(parsedSize.width)x\(parsedSize.height)"
                }
                if let battOut = await battTask {
                    battery = Self.parseBatteryLevel(from: battOut)
                }
            }

            devices.append(AndroidDeviceInfo(
                serial: serial,
                model: model.isEmpty ? (product.isEmpty ? "Android" : product) : model,
                connectionType: connType,
                state: rawState,
                resolution: resolution,
                batteryLevel: battery
            ))
        }
        return devices
    }

    public func fetchUITreeXML(serial: String) async throws -> String {
        var xml = (try? await execute(arguments: ["-s", serial, "exec-out", "uiautomator", "dump", "/dev/tty"], timeoutSeconds: 8.0)) ?? ""
        if !xml.contains("<hierarchy") {
            let remoteDump = "/sdcard/window_dump.xml"
            _ = try await execute(arguments: ["-s", serial, "shell", "uiautomator", "dump", remoteDump], timeoutSeconds: 8.0)
            xml = try await execute(arguments: ["-s", serial, "shell", "cat", remoteDump], timeoutSeconds: 6.0)
            _ = try? await execute(arguments: ["-s", serial, "shell", "rm", "-f", remoteDump], timeoutSeconds: 3.0)
        }
        return xml
    }

    public func captureScreenshotPNG(serial: String) async throws -> Data {
        try await executeData(arguments: ["-s", serial, "exec-out", "screencap", "-p"], timeoutSeconds: 10.0)
    }

    public func screenSize(serial: String) async throws -> AndroidScreenSize? {
        let output = try await execute(arguments: ["-s", serial, "shell", "wm", "size"], timeoutSeconds: 3.0)
        return Self.parseScreenSize(from: output)
    }

    public func tap(serial: String, x: Int, y: Int) async throws {
        _ = try await execute(
            arguments: ["-s", serial, "shell", "input", "tap", "\(x)", "\(y)"],
            timeoutSeconds: 5.0
        )
    }

    public func swipe(serial: String, x1: Int, y1: Int, x2: Int, y2: Int, durationMs: Int) async throws {
        _ = try await execute(
            arguments: ["-s", serial, "shell", "input", "swipe", "\(x1)", "\(y1)", "\(x2)", "\(y2)", "\(durationMs)"],
            timeoutSeconds: 6.0
        )
    }

    public func typeText(serial: String, text: String, pressEnter: Bool) async throws {
        let cmd = AndroidCommandSanitizer.buildSafeTypeTextCommand(text)
        if cmd.useClipboard {
            _ = try await execute(
                arguments: ["-s", serial, "shell", "cmd", "clipboard", "set", "text", cmd.quotedArg],
                timeoutSeconds: 4.0
            )
            _ = try await execute(
                arguments: ["-s", serial, "shell", "input", "keyevent", "279"],
                timeoutSeconds: 4.0
            )
        } else {
            _ = try await execute(
                arguments: ["-s", serial, "shell", "input", "text", cmd.quotedArg],
                timeoutSeconds: 6.0
            )
        }
        if pressEnter {
            _ = try await execute(
                arguments: ["-s", serial, "shell", "input", "keyevent", "66"],
                timeoutSeconds: 4.0
            )
        }
    }

    public func sendKeyevent(serial: String, keyCode: String) async throws {
        _ = try await execute(
            arguments: ["-s", serial, "shell", "input", "keyevent", keyCode],
            timeoutSeconds: 4.0
        )
    }

    public func launchApp(serial: String, packageOrQuery: String) async throws -> String {
        let query = packageOrQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetPackage: String
        if query.contains(".") && !query.contains(" ") {
            targetPackage = query
        } else {
            let apps = try await fetchInstalledApps(serial: serial)
            guard let match = apps.first(where: {
                $0.displayName.localizedCaseInsensitiveContains(query) ||
                $0.packageName.localizedCaseInsensitiveContains(query)
            }) else {
                throw NSError(
                    domain: "AndroidMCPKit.ADB",
                    code: 404,
                    userInfo: [NSLocalizedDescriptionKey: "Could not find installed app matching '\(query)'."]
                )
            }
            targetPackage = match.packageName
        }

        guard AndroidCommandSanitizer.validatePackageName(targetPackage) else {
            throw NSError(
                domain: "AndroidMCPKit.ADB",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Invalid Android package name: '\(targetPackage)'."]
            )
        }

        _ = try await execute(
            arguments: ["-s", serial, "shell", "monkey", "-p", targetPackage, "-c", "android.intent.category.LAUNCHER", "1"],
            timeoutSeconds: 6.0
        )
        return targetPackage
    }

    public func fetchNotificationsDump(serial: String) async throws -> String {
        try await execute(
            arguments: ["-s", serial, "shell", "dumpsys", "notification", "--noredact"],
            timeoutSeconds: 8.0
        )
    }

    // MARK: - Helpers

    public func fetchInstalledApps(serial: String) async throws -> [AndroidInstalledApp] {
        if let launchable = try? await execute(
            arguments: ["-s", serial, "shell", "cmd", "package", "query-activities", "--brief", "-a", "android.intent.action.MAIN", "-c", "android.intent.category.LAUNCHER"],
            timeoutSeconds: 8.0
        ) {
            let parsed = AndroidInstalledApp.parsePackageList(launchable)
            if !parsed.isEmpty {
                return parsed
            }
        }
        let output: String
        do {
            output = try await execute(arguments: ["-s", serial, "shell", "cmd", "package", "list", "packages"], timeoutSeconds: 8.0)
        } catch {
            output = try await execute(arguments: ["-s", serial, "shell", "pm", "list", "packages"], timeoutSeconds: 8.0)
        }
        return AndroidInstalledApp.parsePackageList(output)
    }

    /// Parses `wm size` output (preferring `Override size:` over `Physical size:` if both exist).
    public static func parseScreenSize(from wmOutput: String) -> AndroidScreenSize? {
        var resolved: AndroidScreenSize?
        for line in wmOutput.components(separatedBy: .newlines) {
            let nums = line.components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap { Int($0) }
            if nums.count >= 2, nums[0] > 0, nums[1] > 0 {
                resolved = AndroidScreenSize(width: nums[0], height: nums[1])
            }
        }
        return resolved
    }

    /// Parses battery level percentage from `dumpsys battery`.
    public static func parseBatteryLevel(from dumpsysOutput: String) -> Int? {
        for rawLine in dumpsysOutput.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("level:") {
                let parts = line.components(separatedBy: ":")
                if parts.count == 2, let level = Int(parts[1].trimmingCharacters(in: .whitespaces)) {
                    return level
                }
            }
        }
        return nil
    }
}
