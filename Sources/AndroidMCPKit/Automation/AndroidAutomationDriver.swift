import Foundation
import CoreGraphics

/// Connected Android device summary returned by `AndroidAutomationDriver`.
public struct AndroidDeviceInfo: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let model: String
    public let connectionType: String
    public let state: String
    public let resolution: String?
    public let batteryLevel: Int?

    public var serial: String { id }

    public init(
        serial: String,
        model: String = "Android",
        connectionType: String = "USB",
        state: String = "device",
        resolution: String? = nil,
        batteryLevel: Int? = nil
    ) {
        self.id = serial
        self.model = model
        self.connectionType = connectionType
        self.state = state
        self.resolution = resolution
        self.batteryLevel = batteryLevel
    }
}

/// Physical/override Android screen dimensions in pixels.
public struct AndroidScreenSize: Sendable, Equatable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// Installed launchable Android application entry.
public struct AndroidInstalledApp: Identifiable, Hashable, Sendable {
    public var id: String { packageName }
    public let packageName: String
    public let displayName: String

    public init(packageName: String, displayName: String? = nil) {
        self.packageName = packageName
        self.displayName = displayName ?? Self.friendlyName(for: packageName)
    }

    /// Resolves well-known Android package IDs or formats reverse-DNS package names into readable titles.
    public static func friendlyName(for packageName: String) -> String {
        let known: [String: String] = [
            "com.whatsapp": "WhatsApp",
            "org.telegram.messenger": "Telegram",
            "org.telegram.messenger.web": "Telegram",
            "com.google.android.youtube": "YouTube",
            "com.spotify.music": "Spotify",
            "com.instagram.android": "Instagram",
            "com.discord": "Discord",
            "com.zhiliaoapp.musically": "TikTok",
            "com.google.android.apps.maps": "Google Maps",
            "com.google.android.gm": "Gmail",
            "com.google.android.keep": "Google Keep",
            "com.google.android.apps.photos": "Google Photos",
            "com.android.chrome": "Chrome",
            "com.slack": "Slack",
            "com.notion.id": "Notion",
            "com.reddit.frontpage": "Reddit",
            "com.twitter.android": "X",
            "com.netflix.mediaclient": "Netflix",
            "com.ubercab": "Uber",
            "com.openai.chatgpt": "ChatGPT",
            "ru.yandex.yandexmaps": "Yandex Maps",
            "com.vkontakte.android": "VK"
        ]
        if let hit = known[packageName] {
            return hit
        }
        let segments = packageName.split(separator: ".").map(String.init)
        let ignored: Set<String> = ["com", "org", "net", "io", "app", "android", "google", "apps", "client", "mobile"]
        let meaningful = segments.filter { !ignored.contains($0.lowercased()) }
        let raw = meaningful.last ?? segments.last ?? packageName
        return raw
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
    }

    /// Parses `cmd package query-activities --brief` or `cmd package list packages` output into sorted entries.
    public static func parsePackageList(_ output: String) -> [AndroidInstalledApp] {
        var seen = Set<String>()
        var items: [AndroidInstalledApp] = []

        for rawLine in output.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let pkg: String
            if trimmed.hasPrefix("package:") {
                pkg = String(trimmed.dropFirst("package:".count))
            } else if let slashIdx = trimmed.firstIndex(of: "/"), !trimmed.contains(" "), !trimmed.contains("=") {
                pkg = String(trimmed[..<slashIdx])
            } else {
                pkg = trimmed
            }
            guard !pkg.isEmpty, !pkg.contains(" "), pkg.contains("."), !pkg.contains("="), seen.insert(pkg).inserted else {
                continue
            }
            items.append(AndroidInstalledApp(packageName: pkg))
        }

        return items.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
}

/// OCR match returned by an `AndroidAutomationDriver` with source image dimensions for coordinate mapping.
public struct AndroidOCRTextMatch: Sendable, Equatable {
    public let matchedText: String
    public let normalizedCenterX: Double
    public let normalizedCenterY: Double
    public let imageWidth: Int
    public let imageHeight: Int

    public init(
        matchedText: String,
        normalizedCenterX: Double,
        normalizedCenterY: Double,
        imageWidth: Int,
        imageHeight: Int
    ) {
        self.matchedText = matchedText
        self.normalizedCenterX = normalizedCenterX
        self.normalizedCenterY = normalizedCenterY
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
    }
}

/// Event emitted when Tier 2 Vision OCR self-healing recovers a missing `resource-id` selector.
public struct MCPSelfHealingEvent: Sendable, Equatable {
    public let toolName: String
    public let expectedLabel: String
    public let matchedText: String
    public let x: Int
    public let y: Int

    public init(toolName: String, expectedLabel: String, matchedText: String, x: Int, y: Int) {
        self.toolName = toolName
        self.expectedLabel = expectedLabel
        self.matchedText = matchedText
        self.x = x
        self.y = y
    }
}

/// Abstraction over Android device discovery, UI hierarchy inspection, input injection, and screen capture/OCR.
///
/// Use `StandaloneADBAutomationDriver` out of the box, or conform in host applications (such as AndOnMac)
/// to inject live scrcpy video frames or custom HID input transports.
public protocol AndroidAutomationDriver: Sendable {
    func listDevices() async throws -> [AndroidDeviceInfo]
    func fetchUITreeXML(serial: String) async throws -> String
    func fetchUITree(serial: String) async throws -> [AndroidUINode]
    func captureScreenshotPNG(serial: String) async throws -> Data
    func captureScreenshotCGImage(serial: String) async throws -> CGImage
    func screenSize(serial: String) async throws -> AndroidScreenSize?
    func tap(serial: String, x: Int, y: Int) async throws
    func swipe(serial: String, x1: Int, y1: Int, x2: Int, y2: Int, durationMs: Int) async throws
    func typeText(serial: String, text: String, pressEnter: Bool) async throws
    func sendKeyevent(serial: String, keyCode: String) async throws
    func launchApp(serial: String, packageOrQuery: String) async throws -> String
    func fetchNotificationsDump(serial: String) async throws -> String
    func fetchNotifications(serial: String) async throws -> [AndroidNotificationSummary]
    func recognizeText(serial: String, normalizedCropRect: CGRect?) async throws -> String
    func findTextCenter(serial: String, matching query: String) async throws -> AndroidOCRTextMatch?
}

public extension AndroidAutomationDriver {
    func fetchUITree(serial: String) async throws -> [AndroidUINode] {
        let xml = try await fetchUITreeXML(serial: serial)
        return AndroidUITreeParser.parse(xmlString: xml)
    }

    func captureScreenshotCGImage(serial: String) async throws -> CGImage {
        let pngData = try await captureScreenshotPNG(serial: serial)
        guard let image = VisionTextRecognizer.cgImage(fromImageData: pngData) else {
            throw NSError(
                domain: "AndroidMCPKit.Driver",
                code: 10,
                userInfo: [NSLocalizedDescriptionKey: "Failed to decode Android screenshot PNG into CGImage."]
            )
        }
        return image
    }

    func screenSize(serial: String) async throws -> AndroidScreenSize? {
        nil
    }

    func fetchNotifications(serial: String) async throws -> [AndroidNotificationSummary] {
        let dump = try await fetchNotificationsDump(serial: serial)
        return AndroidMCPTools.parseNotifications(from: dump)
    }

    func recognizeText(serial: String, normalizedCropRect: CGRect?) async throws -> String {
        let cgImage = try await captureScreenshotCGImage(serial: serial)
        return try await VisionTextRecognizer.shared.recognizeText(
            in: cgImage,
            normalizedCropRect: normalizedCropRect
        )
    }

    func findTextCenter(serial: String, matching query: String) async throws -> AndroidOCRTextMatch? {
        let cgImage = try await captureScreenshotCGImage(serial: serial)
        guard let match = try await VisionTextRecognizer.shared.findTextCenter(matching: query, in: cgImage) else {
            return nil
        }
        return AndroidOCRTextMatch(
            matchedText: match.matchedText,
            normalizedCenterX: match.normalizedCenterX,
            normalizedCenterY: match.normalizedCenterY,
            imageWidth: cgImage.width,
            imageHeight: cgImage.height
        )
    }
}
