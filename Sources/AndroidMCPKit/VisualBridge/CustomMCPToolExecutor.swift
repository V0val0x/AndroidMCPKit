import Foundation
import os

/// Dispatches Self-Healing Vision OCR events to the console logger and optional host callback.
public final class MCPSelfHealingNotifier: @unchecked Sendable {
    public static let shared = MCPSelfHealingNotifier()
    private static let logger = Logger(subsystem: "com.androidmcpkit", category: "MCPSelfHealing")

    private let lock = NSLock()
    private var _onHealed: (@Sendable (MCPSelfHealingEvent) -> Void)?

    public var onHealed: (@Sendable (MCPSelfHealingEvent) -> Void)? {
        get { lock.withLock { _onHealed } }
        set { lock.withLock { _onHealed = newValue } }
    }

    private init() {}

    public func notifyHealed(_ event: MCPSelfHealingEvent) {
        Self.logger.warning("Semantic ID failed, healed via Vision OCR (tool=\(event.toolName, privacy: .public), expected=\(event.expectedLabel, privacy: .public), matched=\(event.matchedText, privacy: .public), coords=\(event.x),\(event.y))")
        onHealed?(event)
    }
}

public struct ResolvedTapPoint: Sendable, Equatable {
    public enum Strategy: String, Sendable, Equatable {
        case resourceId
        case visionOCRHealed
        case semanticFallback
        case coordinateFallback
    }

    public let x: Int
    public let y: Int
    public let strategy: Strategy
    public let healedText: String?

    public init(x: Int, y: Int, strategy: Strategy, healedText: String?) {
        self.x = x
        self.y = y
        self.strategy = strategy
        self.healedText = healedText
    }
}

/// Executes user-created or community-imported `CustomMCPToolSchema` definitions safely via `AndroidAutomationDriver`.
public enum CustomMCPToolExecutor {

    public static func execute(
        schema: CustomMCPToolSchema,
        arguments: [String: MCPJSONValue],
        driver: AndroidAutomationDriver,
        executionConfiguration: MCPExecutionConfiguration? = nil,
        onSelfHealingNotice: (@Sendable (MCPSelfHealingEvent) -> Void)? = nil
    ) async -> MCPToolResult {
        do {
            try schema.validate()
            try Task.checkCancellation()
            let serial = try await AndroidMCPTools.resolveSerial(arguments["serial"]?.stringValue, driver: driver)
            let healingEnabled = schema.effectiveSelfHealingEnabled(configuration: executionConfiguration)

            switch schema.action {
            case .readTextUIAutomator:
                return try await readTextUIAutomator(serial: serial, target: schema.target, driver: driver)
            case .readTextOCR:
                return try await readTextOCR(serial: serial, target: schema.target, driver: driver)
            case .tapElement:
                return try await tapElement(
                    serial: serial,
                    toolName: schema.name,
                    target: schema.target,
                    selfHealingEnabled: healingEnabled,
                    driver: driver,
                    onSelfHealingNotice: onSelfHealingNotice
                )
            case .typeText:
                return try await typeText(
                    serial: serial,
                    toolName: schema.name,
                    target: schema.target,
                    textValue: resolveTypeTextArgument(
                        template: nil,
                        schema: schema,
                        arguments: arguments
                    ),
                    selfHealingEnabled: healingEnabled,
                    driver: driver,
                    onSelfHealingNotice: onSelfHealingNotice
                )
            case .macro:
                return try await executeMacro(
                    schema: schema,
                    serial: serial,
                    arguments: arguments,
                    driver: driver,
                    executionConfiguration: executionConfiguration,
                    onSelfHealingNotice: onSelfHealingNotice
                )
            }
        } catch is CancellationError {
            return .text("Execution of '\(schema.name)' was cancelled by Kill-Switch.", isError: true)
        } catch {
            return .text("Error executing '\(schema.name)': \(error.localizedDescription)", isError: true)
        }
    }

    private static func executeMacro(
        schema: CustomMCPToolSchema,
        serial: String,
        arguments: [String: MCPJSONValue],
        driver: AndroidAutomationDriver,
        executionConfiguration: MCPExecutionConfiguration?,
        onSelfHealingNotice: (@Sendable (MCPSelfHealingEvent) -> Void)?
    ) async throws -> MCPToolResult {
        let steps = schema.steps ?? []
        let maxSteps = schema.effectiveMaxSteps(configuration: executionConfiguration)
        guard steps.count <= maxSteps else {
            return .text(
                "Macro '\(schema.name)' aborted: \(steps.count) steps exceeds max_steps limit (\(maxSteps)).",
                isError: true
            )
        }

        let maxDuration = TimeInterval(schema.effectiveMaxDurationSeconds(configuration: executionConfiguration))
        let defaultDelayMs = schema.effectiveStepDelayMs(configuration: executionConfiguration)
        let healingEnabled = schema.effectiveSelfHealingEnabled(configuration: executionConfiguration)
        let startTime = Date()
        var stepLogs: [String] = []
        var healingNotes: [String] = []

        for (idx, step) in steps.enumerated() {
            try Task.checkCancellation()
            if Date().timeIntervalSince(startTime) > maxDuration {
                return .text(
                    "Macro '\(schema.name)' stopped at step \(idx + 1)/\(steps.count): exceeded max duration cap (\(Int(maxDuration))s).",
                    isError: true
                )
            }

            let stepNum = idx + 1
            let result: MCPToolResult
            switch step.action {
            case .tapElement, .macro:
                result = try await tapElement(
                    serial: serial,
                    toolName: schema.name,
                    target: step.target,
                    selfHealingEnabled: healingEnabled,
                    driver: driver,
                    onSelfHealingNotice: onSelfHealingNotice
                )
            case .typeText:
                let resolvedText = resolveTypeTextArgument(
                    template: step.textTemplate,
                    schema: schema,
                    arguments: arguments
                )
                result = try await typeText(
                    serial: serial,
                    toolName: schema.name,
                    target: step.target,
                    textValue: resolvedText,
                    selfHealingEnabled: healingEnabled,
                    driver: driver,
                    onSelfHealingNotice: onSelfHealingNotice
                )
            case .readTextUIAutomator:
                result = try await readTextUIAutomator(serial: serial, target: step.target, driver: driver)
            case .readTextOCR:
                result = try await readTextOCR(serial: serial, target: step.target, driver: driver)
            }

            let textSummary = extractPlainText(from: result)
            if result.isError {
                return .text("Macro '\(schema.name)' failed at step \(stepNum) (\(step.action.rawValue)): \(textSummary)", isError: true)
            }
            if textSummary.contains("[Healed via Vision OCR") {
                healingNotes.append("Step \(stepNum): \(textSummary)")
            }
            stepLogs.append("Step \(stepNum) (\(step.action.rawValue)): \(textSummary)")

            if idx < steps.count - 1 {
                let waitMs = max(0, min(MCPExecutionDefaults.maxStepDelayMs, step.delayAfterMs ?? defaultDelayMs))
                let remainingMs = Int(max(0, (maxDuration - Date().timeIntervalSince(startTime)) * 1000))
                if waitMs > remainingMs {
                    return .text(
                        "Macro '\(schema.name)' stopped after step \(stepNum): wait would exceed \(Int(maxDuration))s duration cap.",
                        isError: true
                    )
                }
                if waitMs > 0 {
                    try await Task.sleep(nanoseconds: UInt64(waitMs) * 1_000_000)
                }
            }
        }

        var summary = "Executed macro '\(schema.name)' (\(steps.count) steps):\n" + stepLogs.joined(separator: "\n")
        if !healingNotes.isEmpty {
            summary += "\n[Healed via Vision OCR during execution]"
        }
        return .text(summary)
    }

    private static func resolveTypeTextArgument(
        template: String?,
        schema: CustomMCPToolSchema,
        arguments: [String: MCPJSONValue]
    ) -> String {
        if let template, !template.isEmpty {
            return CustomMCPToolSchema.interpolateTemplate(template, arguments: arguments)
        }
        let firstParamName = schema.parameters.first?.name
        return arguments["text"]?.stringValue
            ?? (firstParamName.flatMap { arguments[$0]?.stringValue })
            ?? ""
    }

    private static func extractPlainText(from result: MCPToolResult) -> String {
        result.content.compactMap {
            if case .text(let s) = $0 { return s }
            return nil
        }.joined(separator: " ")
    }

    private static func readTextUIAutomator(
        serial: String,
        target: VisualNodeTarget,
        driver: AndroidAutomationDriver
    ) async throws -> MCPToolResult {
        let nodes = try await driver.fetchUITree(serial: serial)
        guard let matched = resolveLiveNode(from: nodes, target: target) else {
            return .text("Target UI element not found on current Android screen.", isError: true)
        }
        let value = !matched.text.isEmpty ? matched.text : matched.content_desc
        if value.isEmpty {
            return .text("(Element found at (\(matched.center_x), \(matched.center_y)), but it contains no text or content-desc.)")
        }
        return .text(value)
    }

    private static func readTextOCR(
        serial: String,
        target: VisualNodeTarget,
        driver: AndroidAutomationDriver
    ) async throws -> MCPToolResult {
        let extracted = try await driver.recognizeText(serial: serial, normalizedCropRect: target.cgNormalizedRect)
        let trimmed = extracted.trimmingCharacters(in: .whitespacesAndNewlines)
        return .text(trimmed.isEmpty ? "(No text recognized in target region.)" : trimmed)
    }

    private static func tapElement(
        serial: String,
        toolName: String,
        target: VisualNodeTarget,
        selfHealingEnabled: Bool,
        driver: AndroidAutomationDriver,
        onSelfHealingNotice: (@Sendable (MCPSelfHealingEvent) -> Void)?
    ) async throws -> MCPToolResult {
        let resolved = await resolveTapPointWithHealing(
            serial: serial,
            toolName: toolName,
            target: target,
            selfHealingEnabled: selfHealingEnabled,
            driver: driver,
            onSelfHealingNotice: onSelfHealingNotice
        )
        try await driver.tap(serial: serial, x: resolved.x, y: resolved.y)
        let label = target.resourceId ?? target.text ?? target.contentDesc ?? "(\(resolved.x), \(resolved.y))"
        if resolved.strategy == .visionOCRHealed, let healedText = resolved.healedText {
            return .text("Tapped '\(label)' at (\(resolved.x), \(resolved.y)). [Healed via Vision OCR: matched '\(healedText)']")
        }
        return .text("Tapped '\(label)' at (\(resolved.x), \(resolved.y)).")
    }

    private static func typeText(
        serial: String,
        toolName: String,
        target: VisualNodeTarget,
        textValue: String,
        selfHealingEnabled: Bool,
        driver: AndroidAutomationDriver,
        onSelfHealingNotice: (@Sendable (MCPSelfHealingEvent) -> Void)?
    ) async throws -> MCPToolResult {
        guard !textValue.isEmpty else {
            return .text("Missing text argument for '\(toolName)'.", isError: true)
        }

        let resolved = await resolveTapPointWithHealing(
            serial: serial,
            toolName: toolName,
            target: target,
            selfHealingEnabled: selfHealingEnabled,
            driver: driver,
            onSelfHealingNotice: onSelfHealingNotice
        )
        try await driver.tap(serial: serial, x: resolved.x, y: resolved.y)
        try await driver.typeText(serial: serial, text: textValue, pressEnter: false)

        if resolved.strategy == .visionOCRHealed, let healedText = resolved.healedText {
            return .text("Typed \(textValue.count) characters into '\(toolName)'. [Healed via Vision OCR: matched '\(healedText)' at (\(resolved.x), \(resolved.y))]")
        }
        return .text("Typed \(textValue.count) characters into '\(toolName)'.")
    }

    /// 3-tier Self-Healing target resolution:
    /// Tier 1: Exact `resourceId` in live UIAutomator XML.
    /// Tier 2: Vision OCR bounding-box fallback when expected `resourceId` disappears (logs warning & notifies callback).
    /// Tier 3: Semantic text/desc/class XML match or stored coordinate fallback.
    public static func resolveTapStrategy(
        nodes: [AndroidUINode],
        target: VisualNodeTarget,
        selfHealingEnabled: Bool,
        visionLocator: (_ expectedLabel: String) async -> (x: Int, y: Int, matchedText: String)?
    ) async -> ResolvedTapPoint {
        if let rid = target.resourceId, !rid.isEmpty {
            let idMatches = nodes.filter { $0.resource_id == rid }
            if let exact = closestNode(in: idMatches, toX: target.fallbackX, y: target.fallbackY) {
                return ResolvedTapPoint(x: exact.center_x, y: exact.center_y, strategy: .resourceId, healedText: nil)
            }

            // Tier 2: Semantic resource-id disappeared (e.g., app update). Heal via Vision OCR on screen frame.
            let expectedLabel = [target.text, target.contentDesc]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first(where: { !$0.isEmpty })

            if selfHealingEnabled, let label = expectedLabel,
               let healed = await visionLocator(label) {
                return ResolvedTapPoint(
                    x: healed.x,
                    y: healed.y,
                    strategy: .visionOCRHealed,
                    healedText: healed.matchedText
                )
            }
        }

        // Tier 3: Semantic text/desc/class match without resourceId, else stored fallback coordinates
        if let live = resolveLiveNode(from: nodes, target: target) {
            return ResolvedTapPoint(x: live.center_x, y: live.center_y, strategy: .semanticFallback, healedText: nil)
        }
        return ResolvedTapPoint(x: target.fallbackX, y: target.fallbackY, strategy: .coordinateFallback, healedText: nil)
    }

    private static func resolveTapPointWithHealing(
        serial: String,
        toolName: String,
        target: VisualNodeTarget,
        selfHealingEnabled: Bool,
        driver: AndroidAutomationDriver,
        onSelfHealingNotice: (@Sendable (MCPSelfHealingEvent) -> Void)?
    ) async -> ResolvedTapPoint {
        let nodes = (try? await driver.fetchUITree(serial: serial)) ?? []
        let resolved = await resolveTapStrategy(
            nodes: nodes,
            target: target,
            selfHealingEnabled: selfHealingEnabled
        ) { expectedLabel in
            guard let match = try? await driver.findTextCenter(serial: serial, matching: expectedLabel) else {
                return nil
            }
            let reportedSize = try? await driver.screenSize(serial: serial)
            let coords = deviceCoordinates(
                normalizedX: match.normalizedCenterX,
                normalizedY: match.normalizedCenterY,
                imageWidth: match.imageWidth,
                imageHeight: match.imageHeight,
                deviceSize: reportedSize
            )
            let event = MCPSelfHealingEvent(
                toolName: toolName,
                expectedLabel: expectedLabel,
                matchedText: match.matchedText,
                x: coords.x,
                y: coords.y
            )
            MCPSelfHealingNotifier.shared.notifyHealed(event)
            onSelfHealingNotice?(event)
            return (coords.x, coords.y, match.matchedText)
        }
        return resolved
    }

    /// Maps top-left normalized (`0...1`) OCR coordinates into orientation-aware Android device pixels.
    public static func deviceCoordinates(
        normalizedX: Double,
        normalizedY: Double,
        imageWidth: Int,
        imageHeight: Int,
        deviceSize: AndroidScreenSize?
    ) -> (x: Int, y: Int) {
        var devW = deviceSize?.width ?? 0
        var devH = deviceSize?.height ?? 0
        if devW <= 0 || devH <= 0 {
            devW = max(1, imageWidth)
            devH = max(1, imageHeight)
        }
        // Account for orientation difference if screenshot is landscape while wm size reports portrait
        if imageWidth > 0, imageHeight > 0, (imageWidth > imageHeight) != (devW > devH) {
            swap(&devW, &devH)
        }
        let px = max(0, min(devW - 1, Int((normalizedX * Double(devW)).rounded())))
        let py = max(0, min(devH - 1, Int((normalizedY * Double(devH)).rounded())))
        return (px, py)
    }

    /// Resolves the best live `AndroidUINode` matching `target` by semantic ID, content-desc, text, or proximity.
    public static func resolveLiveNode(from nodes: [AndroidUINode], target: VisualNodeTarget) -> AndroidUINode? {
        if let rid = target.resourceId, !rid.isEmpty {
            let matches = nodes.filter { $0.resource_id == rid }
            if let closest = closestNode(in: matches, toX: target.fallbackX, y: target.fallbackY) {
                return closest
            }
        }
        if let desc = target.contentDesc, !desc.isEmpty {
            let matches = nodes.filter { $0.content_desc.localizedCaseInsensitiveContains(desc) }
            if let closest = closestNode(in: matches, toX: target.fallbackX, y: target.fallbackY) {
                return closest
            }
        }
        if let text = target.text, !text.isEmpty {
            let matches = nodes.filter { $0.text.localizedCaseInsensitiveContains(text) }
            if let closest = closestNode(in: matches, toX: target.fallbackX, y: target.fallbackY) {
                return closest
            }
        }
        if (target.resourceId?.isEmpty ?? true),
           (target.contentDesc?.isEmpty ?? true),
           (target.text?.isEmpty ?? true),
           let cls = target.className, !cls.isEmpty {
            let matches = nodes.filter { $0.class == cls }
            if let closest = closestNode(in: matches, toX: target.fallbackX, y: target.fallbackY) {
                return closest
            }
        }
        return nil
    }

    private static func closestNode(in candidates: [AndroidUINode], toX x: Int, y: Int) -> AndroidUINode? {
        candidates.min { a, b in
            let distA = (a.center_x - x) * (a.center_x - x) + (a.center_y - y) * (a.center_y - y)
            let distB = (b.center_x - x) * (b.center_x - x) + (b.center_y - y) * (b.center_y - y)
            return distA < distB
        }
    }
}
