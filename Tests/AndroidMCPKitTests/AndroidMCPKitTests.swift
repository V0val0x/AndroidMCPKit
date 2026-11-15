import XCTest
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
@testable import AndroidMCPKit

final class MockAndroidAutomationDriver: AndroidAutomationDriver, @unchecked Sendable {
    private let lock = NSLock()

    var devices: [AndroidDeviceInfo] = [
        AndroidDeviceInfo(
            serial: "MOCK-PIXEL-9",
            model: "Pixel 9 Pro",
            connectionType: "USB",
            state: "device",
            resolution: "1080x2400",
            batteryLevel: 92
        )
    ]

    var uiTreeXML: String = """
    <hierarchy rotation="0">
      <node index="0" text="Settings" resource-id="com.android.settings:id/title" class="android.widget.TextView" content-desc="" clickable="false" scrollable="false" bounds="[40,100][400,180]" />
      <node index="1" text="Transfer" resource-id="com.bank.app:id/btn_transfer" class="android.widget.Button" content-desc="Transfer funds" clickable="true" scrollable="false" bounds="[600,400][980,520]" />
    </hierarchy>
    """

    var screenshotPNGData: Data = MockAndroidAutomationDriver.makePNG(width: 1080, height: 2400)
    var screenSizeValue: AndroidScreenSize? = AndroidScreenSize(width: 1080, height: 2400)
    var notificationsDump: String = """
    NotificationRecord(0x1234: pkg=org.telegram.messenger user=UserHandle{0} id=42)
      when=1731624000000
      android.title=String (Alice)
      android.text=String (Your code is 482910)
    """
    var ocrTextResult: String = "$4,250.00"
    var ocrMatchResult: AndroidOCRTextMatch?

    private(set) var recordedTaps: [(serial: String, x: Int, y: Int)] = []
    private(set) var recordedSwipes: [(serial: String, x1: Int, y1: Int, x2: Int, y2: Int, durationMs: Int)] = []
    private(set) var recordedTypes: [(serial: String, text: String, pressEnter: Bool)] = []
    private(set) var recordedKeyevents: [(serial: String, keyCode: String)] = []
    private(set) var recordedLaunches: [(serial: String, query: String)] = []

    var artificialTapDelayNs: UInt64 = 0

    func listDevices() async throws -> [AndroidDeviceInfo] {
        lock.withLock { devices }
    }

    func fetchUITreeXML(serial: String) async throws -> String {
        lock.withLock { uiTreeXML }
    }

    func captureScreenshotPNG(serial: String) async throws -> Data {
        lock.withLock { screenshotPNGData }
    }

    func screenSize(serial: String) async throws -> AndroidScreenSize? {
        lock.withLock { screenSizeValue }
    }

    func tap(serial: String, x: Int, y: Int) async throws {
        if artificialTapDelayNs > 0 {
            try await Task.sleep(nanoseconds: artificialTapDelayNs)
        }
        lock.withLock {
            recordedTaps.append((serial, x, y))
        }
    }

    func swipe(serial: String, x1: Int, y1: Int, x2: Int, y2: Int, durationMs: Int) async throws {
        lock.withLock {
            recordedSwipes.append((serial, x1, y1, x2, y2, durationMs))
        }
    }

    func typeText(serial: String, text: String, pressEnter: Bool) async throws {
        lock.withLock {
            recordedTypes.append((serial, text, pressEnter))
        }
    }

    func sendKeyevent(serial: String, keyCode: String) async throws {
        lock.withLock {
            recordedKeyevents.append((serial, keyCode))
        }
    }

    func launchApp(serial: String, packageOrQuery: String) async throws -> String {
        lock.withLock {
            recordedLaunches.append((serial, packageOrQuery))
        }
        if packageOrQuery.lowercased().contains("whatsapp") {
            return "com.whatsapp"
        }
        return packageOrQuery
    }

    func fetchNotificationsDump(serial: String) async throws -> String {
        lock.withLock { notificationsDump }
    }

    func recognizeText(serial: String, normalizedCropRect: CGRect?) async throws -> String {
        lock.withLock { ocrTextResult }
    }

    func findTextCenter(serial: String, matching query: String) async throws -> AndroidOCRTextMatch? {
        lock.withLock { ocrMatchResult }
    }

    static func makePNG(width: Int, height: Int) -> Data {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return Data() }
        ctx.setFillColor(CGColor(red: 0.1, green: 0.3, blue: 0.8, alpha: 1.0))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = ctx.makeImage() else { return Data() }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else {
            return Data()
        }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }
}

final class AndroidMCPKitTests: XCTestCase {

    // MARK: - Core Protocol & Kill Switch

    func testMCPServerInitializeToolsListAndKillSwitch() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("androidmcpkit-core-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let driver = MockAndroidAutomationDriver()
        let registry = CustomMCPToolRegistry(directoryURL: tmpDir)
        let core = MCPServerCore(driver: driver, registry: registry)
        core.isAgentPaused = false

        let initReq = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}"#
        let initRespData = await core.handleRawRequestData(Data(initReq.utf8))
        XCTAssertNotNil(initRespData)
        let initJSON = try JSONSerialization.jsonObject(with: initRespData!) as? [String: Any]
        let initResult = initJSON?["result"] as? [String: Any]
        XCTAssertEqual(initResult?["protocolVersion"] as? String, "2024-11-05")
        let caps = initResult?["capabilities"] as? [String: Any]
        let toolsCaps = caps?["tools"] as? [String: Any]
        XCTAssertEqual(toolsCaps?["listChanged"] as? Bool, true)

        let listReq = #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#
        let listRespData = await core.handleRawRequestData(Data(listReq.utf8))
        XCTAssertNotNil(listRespData)
        let listJSON = try JSONSerialization.jsonObject(with: listRespData!) as? [String: Any]
        let listResult = listJSON?["result"] as? [String: Any]
        let tools = listResult?["tools"] as? [[String: Any]]
        XCTAssertEqual(tools?.count, 9)

        // Notifications without id must return nil
        let notifReq = #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#
        let notifResp = await core.handleRawRequestData(Data(notifReq.utf8))
        XCTAssertNil(notifResp)

        // Kill-switch must block tool calls while paused
        core.isAgentPaused = true
        defer { core.isAgentPaused = false }
        let callReq = #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"android_list_devices","arguments":{}}}"#
        let callRespData = await core.handleRawRequestData(Data(callReq.utf8))
        let callJSON = try JSONSerialization.jsonObject(with: callRespData!) as? [String: Any]
        let callResult = callJSON?["result"] as? [String: Any]
        XCTAssertEqual(callResult?["isError"] as? Bool, true)
    }

    func testKillSwitchAbortsInFlightToolCall() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("androidmcpkit-abort-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let driver = MockAndroidAutomationDriver()
        driver.artificialTapDelayNs = 1_500_000_000 // 1.5s
        let registry = CustomMCPToolRegistry(directoryURL: tmpDir)
        let core = MCPServerCore(driver: driver, registry: registry)

        let callReq = #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"android_tap_element","arguments":{"x":100,"y":200}}}"#
        let task = Task {
            await core.handleRawRequestData(Data(callReq.utf8))
        }
        try await Task.sleep(nanoseconds: 80_000_000)
        core.isAgentPaused = true

        let rawRespData = await task.value
        let respData = try XCTUnwrap(rawRespData)
        let json = try JSONSerialization.jsonObject(with: respData) as? [String: Any]
        let result = json?["result"] as? [String: Any]
        XCTAssertEqual(result?["isError"] as? Bool, true)
    }

    // MARK: - Built-in Tools Routing with Mock Driver

    func testBuiltInToolsRoutingViaMCPServerCore() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("androidmcpkit-builtin-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let driver = MockAndroidAutomationDriver()
        let registry = CustomMCPToolRegistry(directoryURL: tmpDir)
        let core = MCPServerCore(driver: driver, registry: registry)

        func callTool(_ name: String, args: [String: Any]) async throws -> [String: Any] {
            let payload: [String: Any] = [
                "jsonrpc": "2.0",
                "id": 1,
                "method": "tools/call",
                "params": ["name": name, "arguments": args]
            ]
            let reqData = try JSONSerialization.data(withJSONObject: payload)
            let rawResp = await core.handleRawRequestData(reqData)
            let respData = try XCTUnwrap(rawResp)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: respData) as? [String: Any])
            return try XCTUnwrap(json["result"] as? [String: Any])
        }

        // 1. android_list_devices
        let devicesRes = try await callTool("android_list_devices", args: [:])
        XCTAssertEqual(devicesRes["isError"] as? Bool, false)
        let devicesText = ((devicesRes["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertTrue(devicesText.contains("MOCK-PIXEL-9"))
        XCTAssertTrue(devicesText.contains("Pixel 9 Pro"))

        // 2. android_get_ui_tree
        let treeRes = try await callTool("android_get_ui_tree", args: [:])
        let treeText = ((treeRes["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertTrue(treeText.contains("com.bank.app:id/btn_transfer"))

        // 3. android_screenshot (downscaled from 2400px height to <=1080px)
        let shotRes = try await callTool("android_screenshot", args: [:])
        let shotContent = try XCTUnwrap((shotRes["content"] as? [[String: Any]])?.first)
        XCTAssertEqual(shotContent["type"] as? String, "image")
        XCTAssertEqual(shotContent["mimeType"] as? String, "image/png")
        let b64 = try XCTUnwrap(shotContent["data"] as? String)
        let pngBytes = try XCTUnwrap(Data(base64Encoded: b64))
        let cgImg = try XCTUnwrap(VisionTextRecognizer.cgImage(fromImageData: pngBytes))
        XCTAssertEqual(cgImg.height, 1080)

        // 4. android_tap_element (semantic text match)
        let tapRes = try await callTool("android_tap_element", args: ["text": "Transfer"])
        XCTAssertEqual(tapRes["isError"] as? Bool, false)
        XCTAssertEqual(driver.recordedTaps.last?.x, 790)
        XCTAssertEqual(driver.recordedTaps.last?.y, 460)

        // 5. android_swipe
        let swipeRes = try await callTool("android_swipe", args: ["direction": "up", "duration_ms": 250])
        XCTAssertEqual(swipeRes["isError"] as? Bool, false)
        XCTAssertEqual(driver.recordedSwipes.last?.durationMs, 250)

        // 6. android_type_text
        let typeRes = try await callTool("android_type_text", args: ["text": "Привет!", "press_enter": true])
        XCTAssertEqual(typeRes["isError"] as? Bool, false)
        XCTAssertEqual(driver.recordedTypes.last?.text, "Привет!")
        XCTAssertEqual(driver.recordedTypes.last?.pressEnter, true)

        // 7. android_keyevent
        let keyRes = try await callTool("android_keyevent", args: ["key": "HOME"])
        XCTAssertEqual(keyRes["isError"] as? Bool, false)
        XCTAssertEqual(driver.recordedKeyevents.last?.keyCode, "3")

        // 8. android_launch_app
        let launchRes = try await callTool("android_launch_app", args: ["app": "WhatsApp"])
        XCTAssertEqual(launchRes["isError"] as? Bool, false)
        XCTAssertEqual(driver.recordedLaunches.last?.query, "WhatsApp")

        // 9. android_get_notifications
        let notifRes = try await callTool("android_get_notifications", args: [:])
        let notifText = ((notifRes["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertTrue(notifText.contains("482910"))
    }

    // MARK: - Parsers & Sanitization

    func testAndroidUITreeParserStripsContainersAndComputesCenters() {
        let xml = """
        UI hierchary dumped to: /dev/tty
        <hierarchy rotation="0">
          <node index="0" text="" resource-id="" class="android.widget.FrameLayout" content-desc="" clickable="false" scrollable="false" bounds="[0,0][1080,2400]">
            <node index="1" text="Confirm" resource-id="com.app:id/btn_confirm" class="android.widget.Button" content-desc="" clickable="true" scrollable="false" bounds="[100,200][500,300]" />
            <node index="2" text="" resource-id="" class="android.view.ViewGroup" content-desc="" clickable="false" scrollable="false" bounds="[0,0][1080,200]" />
          </node>
        </hierarchy>
        """
        let nodes = AndroidUITreeParser.parse(xmlString: xml)
        XCTAssertEqual(nodes.count, 1)
        XCTAssertEqual(nodes[0].text, "Confirm")
        XCTAssertEqual(nodes[0].resource_id, "com.app:id/btn_confirm")
        XCTAssertEqual(nodes[0].class, "Button")
        XCTAssertEqual(nodes[0].center_x, 300)
        XCTAssertEqual(nodes[0].center_y, 250)
    }

    func testMCPNotificationsParser() {
        let dumpsys = """
        NotificationRecord(0x1234: pkg=org.telegram.messenger user=UserHandle{0} id=42)
          when=1731624000000
          android.title=String (Alice)
          android.text=String (Your code is 482910)
        NotificationRecord(0x5678: pkg=com.android.systemui user=UserHandle{0} id=1)
        """
        let parsed = AndroidMCPTools.parseNotifications(from: dumpsys)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].package, "org.telegram.messenger")
        XCTAssertEqual(parsed[0].title, "Alice")
        XCTAssertEqual(parsed[0].text, "Your code is 482910")
    }

    func testCommandInjectionResistanceAndPackageValidation() {
        XCTAssertTrue(AndroidCommandSanitizer.validateSerial("61061JEA307110"))
        XCTAssertTrue(AndroidCommandSanitizer.validateSerial("192.168.1.42:5555"))
        XCTAssertFalse(AndroidCommandSanitizer.validateSerial("-H"))
        XCTAssertFalse(AndroidCommandSanitizer.validateSerial("12345;rm -rf /"))

        XCTAssertTrue(AndroidCommandSanitizer.validateTargetEndpoint("192.168.0.10:5555"))
        XCTAssertFalse(AndroidCommandSanitizer.validateTargetEndpoint("192.168.0.10:99999"))

        XCTAssertTrue(AndroidCommandSanitizer.validatePackageName("com.whatsapp"))
        XCTAssertTrue(AndroidCommandSanitizer.validatePackageName("org.telegram.messenger"))
        XCTAssertFalse(AndroidCommandSanitizer.validatePackageName("com.whatsapp; id"))
        XCTAssertFalse(AndroidCommandSanitizer.validatePackageName("com.whatsapp$(reboot)"))
        XCTAssertFalse(AndroidCommandSanitizer.validatePackageName("-rf"))
        XCTAssertFalse(AndroidCommandSanitizer.validatePackageName("nodot"))
        XCTAssertFalse(AndroidCommandSanitizer.validatePackageName(""))

        let malicious = "hello'; rm -rf /; echo $(id) `uname` | cat > /tmp/x\0"
        let quoted = AndroidCommandSanitizer.shellQuote(malicious)
        XCTAssertTrue(quoted.hasPrefix("'"))
        XCTAssertTrue(quoted.hasSuffix("'"))
        XCTAssertFalse(quoted.contains("\0"))
        XCTAssertEqual(quoted, "'hello'\\''; rm -rf /; echo $(id) `uname` | cat > /tmp/x'")

        let asciiInject = AndroidMCPTools.buildSafeTypeTextCommand("hi; id > /sdcard/pwn")
        XCTAssertFalse(asciiInject.useClipboard)
        XCTAssertEqual(asciiInject.quotedArg, "'hi;%sid%s>%s/sdcard/pwn'")

        let unicodeInject = AndroidMCPTools.buildSafeTypeTextCommand("Привет; $(reboot)\n")
        XCTAssertTrue(unicodeInject.useClipboard)
        XCTAssertEqual(unicodeInject.quotedArg, "'Привет; $(reboot)\n'")
    }

    func testStandaloneADBParsingHelpers() {
        let wmOut = """
        Physical size: 1080x2400
        Override size: 1440x3120
        """
        XCTAssertEqual(StandaloneADBAutomationDriver.parseScreenSize(from: wmOut), AndroidScreenSize(width: 1440, height: 3120))
        XCTAssertEqual(StandaloneADBAutomationDriver.parseBatteryLevel(from: "  level: 87\n  status: 2"), 87)

        let pkgOut = """
        package:com.whatsapp
        package:org.telegram.messenger
        com.google.android.youtube/.HomeActivity
        """
        let apps = AndroidInstalledApp.parsePackageList(pkgOut)
        XCTAssertEqual(apps.count, 3)
        XCTAssertTrue(apps.contains(where: { $0.packageName == "com.whatsapp" && $0.displayName == "WhatsApp" }))
    }

    // MARK: - HTTP/SSE Security & Socket Integration

    func testMCPHTTPServerOriginHostAndBearerSecurity() async throws {
        XCTAssertTrue(MCPHTTPServer.validateOriginAndHost(headers: "POST /message HTTP/1.1\r\nHost: 127.0.0.1:8765\r\n"))
        XCTAssertTrue(MCPHTTPServer.validateOriginAndHost(headers: "POST /message HTTP/1.1\r\nHost: [::1]:8765\r\n"))
        XCTAssertTrue(MCPHTTPServer.validateOriginAndHost(headers: "POST /message HTTP/1.1\r\nHost: localhost:8765\r\nOrigin: http://localhost:3000\r\n"))

        XCTAssertFalse(MCPHTTPServer.validateOriginAndHost(headers: "POST /message HTTP/1.1\r\nHost: evil.com:8765\r\n"))
        XCTAssertFalse(MCPHTTPServer.validateOriginAndHost(headers: "POST /message HTTP/1.1\r\nHost: 127.0.0.1:8765\r\nOrigin: https://evil.com\r\n"))
        XCTAssertFalse(MCPHTTPServer.validateOriginAndHost(headers: "POST /message HTTP/1.1\r\nHost: 127.0.0.1:8765\r\nOrigin: http://localhost.evil.com\r\n"))
        XCTAssertFalse(MCPHTTPServer.validateOriginAndHost(headers: "POST /message HTTP/1.1\r\nHost: 127.0.0.1:8765\r\nOrigin: http://127.0.0.1.evil.com\r\n"))

        let headersWithToken = "POST /message HTTP/1.1\r\nAuthorization: Bearer secret-session-token\r\n"
        XCTAssertTrue(MCPHTTPServer.validateBearerToken(headers: headersWithToken, expectedToken: "secret-session-token"))
        XCTAssertFalse(MCPHTTPServer.validateBearerToken(headers: headersWithToken, expectedToken: "wrong-token"))
        XCTAssertFalse(MCPHTTPServer.validateBearerToken(headers: "POST /message HTTP/1.1\r\n", expectedToken: "secret-session-token"))

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("androidmcpkit-http-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let core = MCPServerCore(driver: MockAndroidAutomationDriver(), registry: CustomMCPToolRegistry(directoryURL: tmpDir))
        let server = MCPHTTPServer(serverCore: core)
        let testPort: UInt16 = 18766
        let testToken = "live-session-secret-\(UUID().uuidString)"
        server.bearerToken = testToken

        final class ResumeOnce: @unchecked Sendable {
            private let lock = NSLock()
            private var resumed = false
            func tryResume() -> Bool {
                lock.lock(); defer { lock.unlock() }
                guard !resumed else { return false }
                resumed = true
                return true
            }
        }
        let resumeOnce = ResumeOnce()
        let started = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            server.start(port: testPort) { isRunning in
                if resumeOnce.tryResume() {
                    cont.resume(returning: isRunning)
                }
            }
        }
        defer {
            server.bearerToken = nil
            server.stop()
        }
        XCTAssertTrue(started, "MCPHTTPServer should bind to 127.0.0.1:\(testPort)")

        let url = URL(string: "http://127.0.0.1:\(testPort)/")!

        // 1. Missing Bearer token -> 401
        var unauthReq = URLRequest(url: url)
        unauthReq.httpMethod = "GET"
        let (_, unauthResp) = try await URLSession.shared.data(for: unauthReq)
        XCTAssertEqual((unauthResp as? HTTPURLResponse)?.statusCode, 401)

        // 2. Spoofed Origin -> 403
        var badOriginReq = URLRequest(url: url)
        badOriginReq.httpMethod = "GET"
        badOriginReq.setValue("Bearer \(testToken)", forHTTPHeaderField: "Authorization")
        badOriginReq.setValue("http://localhost.evil.com", forHTTPHeaderField: "Origin")
        let (_, badOriginResp) = try await URLSession.shared.data(for: badOriginReq)
        XCTAssertEqual((badOriginResp as? HTTPURLResponse)?.statusCode, 403)

        // 3. Valid Bearer token + loopback -> 200
        var okReq = URLRequest(url: url)
        okReq.httpMethod = "GET"
        okReq.setValue("Bearer \(testToken)", forHTTPHeaderField: "Authorization")
        let (_, okResp) = try await URLSession.shared.data(for: okReq)
        XCTAssertEqual((okResp as? HTTPURLResponse)?.statusCode, 200)

        // 4. POST JSON-RPC tools/list over HTTP -> 200
        var postReq = URLRequest(url: URL(string: "http://127.0.0.1:\(testPort)/message")!)
        postReq.httpMethod = "POST"
        postReq.setValue("Bearer \(testToken)", forHTTPHeaderField: "Authorization")
        postReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        postReq.httpBody = Data(#"{"jsonrpc":"2.0","id":10,"method":"tools/list"}"#.utf8)
        let (postData, postResp) = try await URLSession.shared.data(for: postReq)
        XCTAssertEqual((postResp as? HTTPURLResponse)?.statusCode, 200)
        let postText = String(decoding: postData, as: UTF8.self)
        XCTAssertTrue(postText.contains("android_tap_element"))
    }

    // MARK: - Visual-to-MCP Matching, Registry, Macros & Self-Healing

    func testVisualNodeMatcherMapsUIAutomatorNodeAndFallback() {
        let xml = """
        <hierarchy rotation="0">
          <node index="0" text="" resource-id="" class="android.widget.LinearLayout" content-desc="" clickable="false" scrollable="false" bounds="[0,0][1080,2400]">
            <node index="1" text="$4,250.00" resource-id="com.bank.app:id/balance_amount" class="android.widget.TextView" content-desc="Account balance" clickable="false" scrollable="false" bounds="[100,400][540,520]" />
            <node index="2" text="Transfer" resource-id="com.bank.app:id/btn_transfer" class="android.widget.Button" content-desc="" clickable="true" scrollable="false" bounds="[600,400][980,520]" />
          </node>
        </hierarchy>
        """
        let nodes = AndroidUITreeParser.parse(xmlString: xml)
        let normRect = CGRect(x: 0.09, y: 0.165, width: 0.41, height: 0.055)
        let matched = VisualNodeMatcher.matchBestNode(
            normalizedRect: normRect,
            deviceWidth: 1080,
            deviceHeight: 2400,
            nodes: nodes
        )
        XCTAssertEqual(matched.node?.resource_id, "com.bank.app:id/balance_amount")
        XCTAssertEqual(matched.node?.text, "$4,250.00")
        XCTAssertEqual(matched.node?.class, "TextView")
        XCTAssertGreaterThan(matched.iouScore, 0.7)

        let emptyArea = CGRect(x: 0.1, y: 0.85, width: 0.2, height: 0.05)
        let fallback = VisualNodeMatcher.matchBestNode(
            normalizedRect: emptyArea,
            deviceWidth: 1080,
            deviceHeight: 2400,
            nodes: nodes
        )
        XCTAssertNil(fallback.node)
        XCTAssertEqual(fallback.fallbackCenterX, 216)
        XCTAssertEqual(fallback.fallbackCenterY, 2100)
    }

    func testCustomMCPToolSchemaValidationAndJSONRPCDefinition() throws {
        XCTAssertTrue(CustomMCPToolSchema.isValidToolName("get_bank_balance"))
        XCTAssertFalse(CustomMCPToolSchema.isValidToolName("android_tap_element"))
        XCTAssertFalse(CustomMCPToolSchema.isValidToolName("Bad Name!"))
        XCTAssertFalse(CustomMCPToolSchema.isValidParameterName("serial"))
        XCTAssertTrue(CustomMCPToolSchema.isValidParameterName("account_id"))

        let schema = CustomMCPToolSchema(
            name: "tap_transfer",
            description: "Tap the Transfer button",
            isEnabled: true,
            action: .tapElement,
            target: VisualNodeTarget(
                resourceId: "com.bank.app:id/btn_transfer",
                className: "Button",
                text: "Transfer",
                contentDesc: nil,
                fallbackX: 790,
                fallbackY: 460,
                normalizedRect: [0.55, 0.16, 0.35, 0.05]
            ),
            parameters: [
                CustomMCPParameter(name: "amount", type: "integer", description: "Transfer amount", required: true)
            ]
        )
        try schema.validate()
        let def = schema.toMCPToolDefinition()
        XCTAssertEqual(def.name, "tap_transfer")
        let props = def.inputSchema.objectValue?["properties"]?.objectValue
        XCTAssertNotNil(props?["serial"])
        XCTAssertNotNil(props?["amount"])
        if case .array(let reqValues) = def.inputSchema.objectValue?["required"] {
            XCTAssertEqual(reqValues.compactMap(\.stringValue), ["amount"])
        } else {
            XCTFail("Expected required array in inputSchema")
        }
    }

    func testCustomMCPToolRegistryPersistenceAndImportExport() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("androidmcpkit-mcptools-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let registry = CustomMCPToolRegistry(directoryURL: tmpDir)
        XCTAssertTrue(registry.allToolsSnapshot().isEmpty)

        let schema = CustomMCPToolSchema(
            name: "get_bank_balance",
            description: "Read current balance",
            isEnabled: true,
            action: .readTextUIAutomator,
            target: VisualNodeTarget(
                resourceId: "com.bank.app:id/balance_amount",
                className: "TextView",
                text: "$4,250.00",
                contentDesc: nil,
                fallbackX: 320,
                fallbackY: 460,
                normalizedRect: [0.09, 0.16, 0.41, 0.05]
            )
        )
        try registry.saveTool(schema)
        XCTAssertEqual(registry.enabledMCPDefinitions().map(\.name), ["get_bank_balance"])

        let exported = try registry.exportJSON(name: "get_bank_balance")
        try registry.setEnabled(name: "get_bank_balance", enabled: false)
        XCTAssertTrue(registry.enabledMCPDefinitions().isEmpty)

        try registry.deleteTool(name: "get_bank_balance")
        XCTAssertTrue(registry.allToolsSnapshot().isEmpty)

        let imported = try registry.importFromJSON(exported)
        XCTAssertEqual(imported.name, "get_bank_balance")
        XCTAssertTrue(imported.isEnabled)
    }

    func testMultiStepMacroSchemaAutoParametersAndOverrides() throws {
        let searchTarget = VisualNodeTarget(
            resourceId: "com.chat:id/search_btn",
            className: "ImageButton",
            text: "Search",
            contentDesc: "Search chats",
            fallbackX: 900,
            fallbackY: 160,
            normalizedRect: [0.8, 0.05, 0.1, 0.05]
        )
        let inputTarget = VisualNodeTarget(
            resourceId: "com.chat:id/composer",
            className: "EditText",
            text: nil,
            contentDesc: "Message",
            fallbackX: 400,
            fallbackY: 2200,
            normalizedRect: [0.1, 0.88, 0.7, 0.06]
        )
        let sendTarget = VisualNodeTarget(
            resourceId: "com.chat:id/send_btn",
            className: "ImageButton",
            text: "Send",
            contentDesc: nil,
            fallbackX: 980,
            fallbackY: 2200,
            normalizedRect: [0.85, 0.88, 0.1, 0.06]
        )

        let macro = CustomMCPToolSchema(
            name: "send_chat_macro",
            description: "Search contact and send a message",
            isEnabled: true,
            action: .macro,
            target: searchTarget,
            parameters: [],
            steps: [
                VisualMacroStep(action: .tapElement, target: searchTarget, delayAfterMs: 300),
                VisualMacroStep(action: .typeText, target: inputTarget, textTemplate: "{{contact_name}}", delayAfterMs: 500),
                VisualMacroStep(action: .typeText, target: inputTarget, textTemplate: "{{message_body}}", delayAfterMs: 350),
                VisualMacroStep(action: .tapElement, target: sendTarget, delayAfterMs: 250)
            ],
            defaultStepDelayMs: 650,
            maxSteps: 12,
            maxDurationSeconds: 25,
            selfHealingEnabled: true
        )
        try macro.validate()

        let def = macro.toMCPToolDefinition()
        let props = def.inputSchema.objectValue?["properties"]?.objectValue
        XCTAssertNotNil(props?["contact_name"])
        XCTAssertNotNil(props?["message_body"])

        let interpolated = CustomMCPToolSchema.interpolateTemplate(
            "Hello {{contact_name}}: {{message_body}}",
            arguments: [
                "contact_name": .string("Alex"),
                "message_body": .string("See you at 5")
            ]
        )
        XCTAssertEqual(interpolated, "Hello Alex: See you at 5")

        XCTAssertEqual(macro.effectiveStepDelayMs(), 650)
        XCTAssertEqual(macro.effectiveMaxSteps(), 12)
        XCTAssertEqual(macro.effectiveMaxDurationSeconds(), 25)
        XCTAssertTrue(macro.effectiveSelfHealingEnabled())

        let legacyJSON = """
        {
          "name": "legacy_tap",
          "description": "Legacy tool",
          "isEnabled": true,
          "action": "tap_element",
          "target": {
            "resourceId": "com.app:id/ok",
            "fallbackX": 500,
            "fallbackY": 1000,
            "normalizedRect": [0.4, 0.4, 0.2, 0.1]
          },
          "parameters": [],
          "createdAt": "2026-11-15T00:00:00Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decodedLegacy = try decoder.decode(CustomMCPToolSchema.self, from: Data(legacyJSON.utf8))
        XCTAssertNil(decodedLegacy.steps)
        XCTAssertNil(decodedLegacy.defaultStepDelayMs)
    }

    func testMultiStepMacroExecutionAndSelfHealingViaMCPServerCore() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("androidmcpkit-macro-exec-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let driver = MockAndroidAutomationDriver()
        driver.uiTreeXML = """
        <hierarchy rotation="0">
          <node index="0" text="Search" resource-id="com.chat:id/search_btn" class="android.widget.ImageButton" content-desc="Search chats" clickable="true" scrollable="false" bounds="[850,110][950,210]" />
          <node index="1" text="" resource-id="com.chat:id/composer" class="android.widget.EditText" content-desc="Message" clickable="true" scrollable="false" bounds="[100,2150][700,2250]" />
        </hierarchy>
        """
        // Send button's resource-id disappeared -> Tier 2 OCR heals it!
        driver.ocrMatchResult = AndroidOCRTextMatch(
            matchedText: "Send",
            normalizedCenterX: 0.9,
            normalizedCenterY: 0.9,
            imageWidth: 1080,
            imageHeight: 2400
        )

        let registry = CustomMCPToolRegistry(directoryURL: tmpDir)
        let searchTarget = VisualNodeTarget(
            resourceId: "com.chat:id/search_btn",
            className: "ImageButton",
            text: "Search",
            contentDesc: "Search chats",
            fallbackX: 900,
            fallbackY: 160,
            normalizedRect: [0.8, 0.05, 0.1, 0.05]
        )
        let inputTarget = VisualNodeTarget(
            resourceId: "com.chat:id/composer",
            className: "EditText",
            text: nil,
            contentDesc: "Message",
            fallbackX: 400,
            fallbackY: 2200,
            normalizedRect: [0.1, 0.88, 0.7, 0.06]
        )
        let sendTarget = VisualNodeTarget(
            resourceId: "com.chat:id/missing_send_btn_v2",
            className: "ImageButton",
            text: "Send",
            contentDesc: nil,
            fallbackX: 100,
            fallbackY: 100,
            normalizedRect: [0.85, 0.88, 0.1, 0.06]
        )

        let macro = CustomMCPToolSchema(
            name: "send_chat_macro",
            description: "Search contact and send message",
            isEnabled: true,
            action: .macro,
            target: searchTarget,
            steps: [
                VisualMacroStep(action: .tapElement, target: searchTarget, delayAfterMs: 10),
                VisualMacroStep(action: .typeText, target: inputTarget, textTemplate: "Hi {{contact_name}}: {{message_body}}", delayAfterMs: 10),
                VisualMacroStep(action: .tapElement, target: sendTarget, delayAfterMs: 10)
            ],
            defaultStepDelayMs: 50,
            maxSteps: 10,
            maxDurationSeconds: 10,
            selfHealingEnabled: true
        )
        try registry.saveTool(macro)

        final class HealingBox: @unchecked Sendable {
            private let lock = NSLock()
            var events: [MCPSelfHealingEvent] = []
            func append(_ e: MCPSelfHealingEvent) { lock.withLock { events.append(e) } }
        }
        let healingBox = HealingBox()

        let core = MCPServerCore(driver: driver, registry: registry)
        core.onSelfHealingNotice = { event in
            healingBox.append(event)
        }

        // tools/list includes the 9 built-in tools + 1 custom macro = 10
        let rawListData = await core.handleRawRequestData(Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8))
        let listData = try XCTUnwrap(rawListData)
        let listJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: listData) as? [String: Any])
        let listedTools = (listJSON["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        XCTAssertEqual(listedTools?.count, 10)

        let callPayload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": [
                "name": "send_chat_macro",
                "arguments": [
                    "contact_name": "Alex",
                    "message_body": "Meet at 5"
                ]
            ]
        ]
        let reqBytes = try JSONSerialization.data(withJSONObject: callPayload)
        let rawCallData = await core.handleRawRequestData(reqBytes)
        let callData = try XCTUnwrap(rawCallData)
        let callJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: callData) as? [String: Any])
        let callResult = try XCTUnwrap(callJSON["result"] as? [String: Any])
        XCTAssertEqual(callResult["isError"] as? Bool, false)
        let textOut = ((callResult["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertTrue(textOut.contains("Executed macro 'send_chat_macro' (3 steps)"))
        XCTAssertTrue(textOut.contains("Healed via Vision OCR"))

        // Verify exact recorded driver calls: tap search (900,160), tap input (400,2200), type interpolated, tap healed Send (972,2160)
        XCTAssertEqual(driver.recordedTypes.last?.text, "Hi Alex: Meet at 5")
        XCTAssertEqual(driver.recordedTaps.count, 3)
        XCTAssertEqual(driver.recordedTaps[0].x, 900)
        XCTAssertEqual(driver.recordedTaps[0].y, 160)
        XCTAssertEqual(driver.recordedTaps[2].x, 972)
        XCTAssertEqual(driver.recordedTaps[2].y, 2160)

        XCTAssertEqual(healingBox.events.count, 1)
        XCTAssertEqual(healingBox.events.first?.matchedText, "Send")
    }

    func testSelfHealingThreeTierTapResolution() async {
        let target = VisualNodeTarget(
            resourceId: "com.bank.app:id/old_transfer_btn",
            className: "Button",
            text: "Transfer",
            contentDesc: nil,
            fallbackX: 100,
            fallbackY: 200,
            normalizedRect: [0.1, 0.1, 0.2, 0.05]
        )

        // Tier 1: Exact resource-id found -> uses XML node coordinates, never calls Vision OCR
        let matchingNode = AndroidUINode(
            index: 0,
            text: "Transfer",
            resource_id: "com.bank.app:id/old_transfer_btn",
            content_desc: "",
            class: "Button",
            clickable: true,
            scrollable: false,
            bounds: "[250,580][450,660]",
            center_x: 350,
            center_y: 620
        )
        let tier1 = await CustomMCPToolExecutor.resolveTapStrategy(
            nodes: [matchingNode],
            target: target,
            selfHealingEnabled: true
        ) { _ in
            XCTFail("Vision OCR should not be called when resource-id matches")
            return nil
        }
        XCTAssertEqual(tier1.strategy, .resourceId)
        XCTAssertEqual(tier1.x, 350)
        XCTAssertEqual(tier1.y, 620)

        // Tier 2: App updated its resource-id, so XML lacks old ID -> Vision OCR heals it
        let updatedNodeDifferentText = AndroidUINode(
            index: 1,
            text: "Home",
            resource_id: "com.bank.app:id/nav_home",
            content_desc: "",
            class: "Button",
            clickable: true,
            scrollable: false,
            bounds: "[60,2150][180,2250]",
            center_x: 120,
            center_y: 2200
        )
        let tier2 = await CustomMCPToolExecutor.resolveTapStrategy(
            nodes: [updatedNodeDifferentText],
            target: target,
            selfHealingEnabled: true
        ) { query in
            XCTAssertEqual(query, "Transfer")
            return (x: 780, y: 1450, matchedText: "Transfer")
        }
        XCTAssertEqual(tier2.strategy, .visionOCRHealed)
        XCTAssertEqual(tier2.x, 780)
        XCTAssertEqual(tier2.y, 1450)
        XCTAssertEqual(tier2.healedText, "Transfer")

        // Tier 3: Self-Healing disabled -> falls back directly without Vision OCR
        let tier3 = await CustomMCPToolExecutor.resolveTapStrategy(
            nodes: [updatedNodeDifferentText],
            target: target,
            selfHealingEnabled: false
        ) { _ in
            XCTFail("Vision OCR must not run when selfHealingEnabled is false")
            return nil
        }
        XCTAssertEqual(tier3.strategy, .coordinateFallback)
        XCTAssertEqual(tier3.x, 100)
        XCTAssertEqual(tier3.y, 200)
    }

    // MARK: - Vision OCR & Process Supervision

    func testVisionOCRPixelCropRectAndTextRecognition() async throws {
        let crop = VisionTextRecognizer.pixelCropRect(
            normalizedRect: CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.25),
            imageWidth: 1080,
            imageHeight: 2400
        )
        XCTAssertEqual(crop, CGRect(x: 270, y: 1200, width: 540, height: 600))

        let clamped = VisionTextRecognizer.pixelCropRect(
            normalizedRect: CGRect(x: -0.5, y: 0.9, width: 2.0, height: 0.5),
            imageWidth: 1000,
            imageHeight: 2000
        )
        XCTAssertEqual(clamped.origin.x, 0)
        XCTAssertLessThanOrEqual(clamped.maxX, 1000)
        XCTAssertLessThanOrEqual(clamped.maxY, 2000)

        // Render high-contrast text into a CGImage and verify Apple Vision OCR finds it
        let width = 600
        let height = 200
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 48, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        ]
        let attrStr = NSAttributedString(string: "TRANSFER", attributes: attrs)
        let line = CTLineCreateWithAttributedString(attrStr)
        ctx.textPosition = CGPoint(x: 120, y: 80)
        CTLineDraw(line, ctx)

        let cgImage = try XCTUnwrap(ctx.makeImage())
        let match = try await VisionTextRecognizer.shared.findTextCenter(matching: "Transfer", in: cgImage)
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.matchedText.uppercased(), "TRANSFER")
    }

    func testProcessSupervisorRegistrationAndCleanup() throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sleep")
        proc.arguments = ["5"]
        try proc.run()
        let trackedId = ProcessSupervisor.shared.register(proc, tag: "unit-test")
        XCTAssertGreaterThanOrEqual(ProcessSupervisor.shared.activeCount, 1)
        ProcessSupervisor.shared.terminateProcess(proc, gracePeriodMs: 100)
        proc.waitUntilExit()
        ProcessSupervisor.shared.unregister(trackedId)
        XCTAssertFalse(proc.isRunning)
    }
}
