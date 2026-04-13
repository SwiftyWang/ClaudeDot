import SwiftUI
import AppKit

@main
struct ClaudeDotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

// MARK: - Claude Code Status

enum ClaudeStatus: Equatable, Comparable {
    case disconnected
    case idle
    case thinking
    case responding
    case toolActive
    case awaitingPermission

    /// Higher = more urgent, used to pick the primary session
    var priority: Int {
        switch self {
        case .disconnected: return 0
        case .idle: return 1
        case .thinking: return 2
        case .responding: return 3
        case .toolActive: return 4
        case .awaitingPermission: return 5
        }
    }

    static func < (lhs: ClaudeStatus, rhs: ClaudeStatus) -> Bool {
        lhs.priority < rhs.priority
    }

    var label: String {
        switch self {
        case .disconnected: return String(localized: "status.disconnected")
        case .idle: return String(localized: "status.idle")
        case .thinking: return String(localized: "status.thinking")
        case .responding: return String(localized: "status.responding")
        case .toolActive: return String(localized: "status.toolActive")
        case .awaitingPermission: return String(localized: "status.awaitingPermission")
        }
    }

    var color: NSColor {
        switch self {
        case .disconnected:
            return NSColor(red: 142/255, green: 142/255, blue: 147/255, alpha: 1)
        case .idle:
            return NSColor(red: 52/255, green: 199/255, blue: 89/255, alpha: 1)
        case .thinking:
            return NSColor(red: 147/255, green: 112/255, blue: 255/255, alpha: 1)
        case .responding:
            return NSColor(red: 64/255, green: 156/255, blue: 255/255, alpha: 1)
        case .toolActive:
            return NSColor(red: 255/255, green: 149/255, blue: 0/255, alpha: 1)
        case .awaitingPermission:
            return NSColor(red: 255/255, green: 204/255, blue: 0/255, alpha: 1)
        }
    }
}

// MARK: - Session Info

struct SessionInfo {
    let pid: Int
    let sessionId: String
    let cwd: String
    var status: ClaudeStatus = .idle
}

// MARK: - Transcript Monitor (JSONL tail)

class TranscriptMonitor {
    private var currentPath: String?
    private var fileHandle: FileHandle?
    private var fileOffset: UInt64 = 0
    private var pendingToolIds: Set<String> = []
    private(set) var lastEventType: String = ""
    private(set) var lastEventTime: Date = .distantPast
    private var buffer: String = ""

    /// Switch to monitoring a new transcript file
    func setTranscriptPath(_ path: String?) {
        guard path != currentPath else { return }
        fileHandle?.closeFile()
        fileHandle = nil
        currentPath = path
        pendingToolIds.removeAll()
        lastEventType = ""
        lastEventTime = .distantPast
        buffer = ""
        fileOffset = 0

        guard let path, FileManager.default.fileExists(atPath: path) else { return }
        // Seek to near end — only parse last 4KB to catch recent state
        fileHandle = FileHandle(forReadingAtPath: path)
        if let fh = fileHandle {
            let fileSize = fh.seekToEndOfFile()
            let startPos = fileSize > 4096 ? fileSize - 4096 : 0
            fh.seek(toFileOffset: startPos)
            // Read the tail to establish current state
            let data = fh.readDataToEndOfFile()
            fileOffset = fh.offsetInFile
            if let text = String(data: data, encoding: .utf8) {
                // If we seeked into the middle, skip the first partial line
                let lines = text.components(separatedBy: "\n")
                let startIdx = startPos > 0 ? 1 : 0
                for i in startIdx..<lines.count {
                    parseLine(lines[i])
                }
            }
        }
    }

    /// Read new lines appended since last check
    func poll() {
        guard let fh = fileHandle else { return }
        fh.seek(toFileOffset: fileOffset)
        let data = fh.readDataToEndOfFile()
        fileOffset = fh.offsetInFile
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }

        buffer += text
        while let newlineRange = buffer.range(of: "\n") {
            let line = String(buffer[buffer.startIndex..<newlineRange.lowerBound])
            buffer = String(buffer[newlineRange.upperBound...])
            parseLine(line)
        }
    }

    private func parseLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        let type = json["type"] as? String ?? ""
        let timestamp = json["timestamp"] as? String

        if let timestamp, let date = parseISO8601(timestamp) {
            lastEventTime = date
        }

        let message = json["message"] as? [String: Any] ?? [:]
        let content = message["content"] as? [[String: Any]] ?? []

        var hasToolUseInMessage = false
        for item in content {
            let contentType = item["type"] as? String ?? ""

            switch contentType {
            case "thinking":
                lastEventType = "thinking"
            case "text" where type == "assistant":
                lastEventType = "text"
            case "tool_use":
                hasToolUseInMessage = true
                if let toolId = item["id"] as? String {
                    pendingToolIds.insert(toolId)
                }
                lastEventType = "tool_use"
            case "tool_result":
                if let toolId = item["tool_use_id"] as? String {
                    pendingToolIds.remove(toolId)
                }
                lastEventType = "tool_result"
            default:
                break
            }
        }

        // Assistant message with text but no tool_use means final response — clear pending tools
        if type == "assistant" && !content.isEmpty && !hasToolUseInMessage {
            pendingToolIds.removeAll()
        }

        // user type with tool_result content
        if type == "user" && !content.isEmpty {
            let hasToolResult = content.contains { ($0["type"] as? String) == "tool_result" }
            if hasToolResult {
                for item in content {
                    if let toolId = item["tool_use_id"] as? String {
                        pendingToolIds.remove(toolId)
                    }
                }
                lastEventType = "tool_result"
            } else {
                // User sent a new message — all prior tool calls are resolved
                pendingToolIds.removeAll()
                lastEventType = "user_message"
            }
        }
    }

    var hasActiveTool: Bool { !pendingToolIds.isEmpty }

    var secondsSinceLastEvent: TimeInterval {
        Date().timeIntervalSince(lastEventTime)
    }

    private func parseISO8601(_ str: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: str)
    }

    func reset() {
        fileHandle?.closeFile()
        fileHandle = nil
        currentPath = nil
        pendingToolIds.removeAll()
        lastEventType = ""
        lastEventTime = .distantPast
        buffer = ""
        fileOffset = 0
    }
}

// MARK: - Claude Status Monitor (statusLine-based)

class ClaudeStatusMonitor: @unchecked Sendable {
    private let sessionsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/sessions")
    private let statusFilePath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/claudedot-status.json").path
    private let projectsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects").path

    private let stalenessThreshold: TimeInterval = 5.0
    private var transcriptMonitors: [String: TranscriptMonitor] = [:]

    /// Verify that a PID actually belongs to a Claude Code (node) process
    private func isClaudeProcess(_ pid: Int) -> Bool {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", "\(pid)", "-o", "comm="]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let comm = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return comm.contains("node") || comm.contains("claude")
        } catch {
            return false
        }
    }

    /// Check if statusLine file is fresh (being refreshed by idle Claude)
    private func isStatusLineFresh() -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: statusFilePath),
              let attrs = try? fm.attributesOfItem(atPath: statusFilePath),
              let modDate = attrs[.modificationDate] as? Date
        else { return false }
        return Date().timeIntervalSince(modDate) < stalenessThreshold
    }

    /// Derive transcript path for a session
    private func transcriptPath(for session: SessionInfo) -> String? {
        // Claude Code encodes cwd as: /Users/foo/bar → -Users-foo-bar
        let encoded = session.cwd.replacingOccurrences(of: "/", with: "-")
        let dir = projectsDir + "/" + encoded
        let path = dir + "/" + session.sessionId + ".jsonl"
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// Get or create a TranscriptMonitor for a session
    private func monitor(for session: SessionInfo) -> TranscriptMonitor {
        if let existing = transcriptMonitors[session.sessionId] {
            return existing
        }
        let tm = TranscriptMonitor()
        transcriptMonitors[session.sessionId] = tm
        return tm
    }

    /// Determine status for a single session using its transcript monitor
    private func detectSessionStatus(session: SessionInfo, tm: TranscriptMonitor) -> ClaudeStatus {
        tm.poll()

        // Priority 1: Check notification hook for permission prompt
        if NotificationHookSetup.hasActiveNotification() {
            return .awaitingPermission
        }

        // Priority 2: Heuristic permission detection
        if tm.hasActiveTool && tm.secondsSinceLastEvent > 3.0 && !isStatusLineFresh() {
            return .awaitingPermission
        }

        // Priority 3: Active tool execution
        if tm.hasActiveTool {
            return .toolActive
        }

        // Priority 4: Recent transcript activity
        let recency = tm.secondsSinceLastEvent
        if recency < 10.0 {
            switch tm.lastEventType {
            case "thinking": return .thinking
            case "text": return .responding
            case "tool_result": return .thinking
            case "tool_use": return .toolActive
            case "user_message": return .thinking
            default: break
            }
        }

        // Priority 5: statusLine freshness
        if isStatusLineFresh() {
            return .idle
        }

        // Priority 6: Stale transcript
        if recency > 10.0 {
            let lastType = tm.lastEventType
            if lastType == "text" || lastType == "user_message" || lastType == "" {
                return .idle
            }
            return .thinking
        }

        return .idle
    }

    /// Find active Claude Code sessions from ~/.claude/sessions/
    func findActiveSessions() -> [SessionInfo] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: sessionsDir, includingPropertiesForKeys: nil
        ) else { return [] }

        var sessions: [SessionInfo] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = json["pid"] as? Int,
                  let sessionId = json["sessionId"] as? String,
                  let cwd = json["cwd"] as? String
            else { continue }

            if kill(Int32(pid), 0) == 0 && isClaudeProcess(pid) {
                sessions.append(SessionInfo(pid: pid, sessionId: sessionId, cwd: cwd))
            }
        }
        return sessions
    }

    /// Detect status for all active sessions
    func detectAllSessions() -> [SessionInfo] {
        var sessions = findActiveSessions()
        guard !sessions.isEmpty else {
            // Clean up all monitors
            transcriptMonitors.values.forEach { $0.reset() }
            transcriptMonitors.removeAll()
            cleanupStatusFile()
            NotificationHookSetup.clearMarker()
            return []
        }

        // Detect status for each session
        let activeIds = Set(sessions.map { $0.sessionId })
        for i in sessions.indices {
            let tm = monitor(for: sessions[i])
            if let path = transcriptPath(for: sessions[i]) {
                tm.setTranscriptPath(path)
            }
            sessions[i].status = detectSessionStatus(session: sessions[i], tm: tm)
        }

        // Clean up monitors for sessions that no longer exist
        for id in transcriptMonitors.keys where !activeIds.contains(id) {
            transcriptMonitors[id]?.reset()
            transcriptMonitors.removeValue(forKey: id)
        }

        return sessions
    }

    func cleanupStatusFile() {
        try? FileManager.default.removeItem(atPath: statusFilePath)
    }
}

// MARK: - Notification Hook Setup

class NotificationHookSetup {
    private static let scriptPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/claudedot-notify.sh").path
    static let markerPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/claudedot-notification.json").path

    static func ensureConfigured() {
        let fm = FileManager.default

        // 1. Create notification script
        let script = """
        #!/bin/bash
        MARKER="$HOME/.claude/claudedot-notification.json"
        INPUT=$(cat)
        if [ -n "$INPUT" ]; then
            echo "$INPUT" > "${MARKER}.tmp" && mv "${MARKER}.tmp" "$MARKER"
        fi
        """
        if !fm.fileExists(atPath: scriptPath) {
            do {
                try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
            } catch {
                print("[ClaudeDot] Failed to create notification script: \(error)")
            }
        }

        // 2. Add Notification hook to settings.json
        let settingsPath = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json").path

        guard fm.fileExists(atPath: settingsPath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: settingsPath)),
              var settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        if hooks["Notification"] == nil {
            hooks["Notification"] = [[
                "matcher": "",
                "hooks": [
                    ["type": "command", "command": scriptPath]
                ]
            ]]
            settings["hooks"] = hooks
            do {
                let newData = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
                try newData.write(to: URL(fileURLWithPath: settingsPath))
                print("[ClaudeDot] Added Notification hook to settings.json")
            } catch {
                print("[ClaudeDot] Failed to update settings.json: \(error)")
            }
        }
    }

    /// Check if a notification marker exists and is fresh (< 30s)
    static func hasActiveNotification() -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: markerPath),
              let attrs = try? fm.attributesOfItem(atPath: markerPath),
              let modDate = attrs[.modificationDate] as? Date
        else { return false }
        return Date().timeIntervalSince(modDate) < 30.0
    }

    /// Clear notification marker (called when status changes away from awaiting)
    static func clearMarker() {
        try? FileManager.default.removeItem(atPath: markerPath)
    }
}

// MARK: - StatusLine Auto-Setup

class StatusLineSetup {
    private static let scriptPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/claudedot-statusline.sh").path

    /// Ensure statusLine script and settings.json are configured
    static func ensureConfigured() -> Bool {
        let fm = FileManager.default

        // 1. Create script if missing
        if !fm.fileExists(atPath: scriptPath) {
            let script = """
            #!/bin/bash
            STATUS_FILE="$HOME/.claude/claudedot-status.json"
            INPUT=$(cat)
            if [ -n "$INPUT" ]; then
                echo "$INPUT" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
            fi
            """
            do {
                try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
            } catch {
                print("[ClaudeDot] Failed to create statusLine script: \(error)")
                return false
            }
        }

        // 2. Ensure settings.json has statusLine configured
        let settingsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json").path

        guard fm.fileExists(atPath: settingsPath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: settingsPath)),
              var settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }

        if settings["statusLine"] == nil {
            settings["statusLine"] = [
                "type": "command",
                "command": "~/.claude/claudedot-statusline.sh",
                "refreshInterval": 3
            ] as [String: Any]

            do {
                let newData = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
                try newData.write(to: URL(fileURLWithPath: settingsPath))
                print("[ClaudeDot] Added statusLine to settings.json")
            } catch {
                print("[ClaudeDot] Failed to update settings.json: \(error)")
                return false
            }
        }

        return true
    }
}

// MARK: - Sound Manager

class SoundManager {
    static let shared = SoundManager()
    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "soundEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "soundEnabled") }
    }
    private var previousStatus: ClaudeStatus = .disconnected

    func playStatusChange(from oldStatus: ClaudeStatus, to newStatus: ClaudeStatus) {
        guard enabled else { return }
        switch newStatus {
        case .disconnected:
            NSSound(named: "Basso")?.play()
        case .idle:
            // Only play "Pop" when transitioning from a working state
            if [.thinking, .responding, .toolActive, .awaitingPermission].contains(oldStatus) {
                NSSound(named: "Pop")?.play()
            }
        case .thinking, .responding:
            // Silent — these toggle too frequently
            break
        case .toolActive:
            NSSound(named: "Tink")?.play()
        case .awaitingPermission:
            NSSound(named: "Submarine")?.play()
        }
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var popover = NSPopover()
    private var animationTimer: Timer?
    private var monitorTimer: Timer?
    private var pulsePhase: CGFloat = 0
    private(set) var currentStatus: ClaudeStatus = .disconnected
    private(set) var allSessions: [SessionInfo] = []
    var primarySession: SessionInfo? {
        allSessions.max(by: { $0.status < $1.status })
    }
    private let monitor = ClaudeStatusMonitor()
    private var needsRestart = false

    private let dotSize: CGFloat = 10

    func colorForStatus(_ status: ClaudeStatus) -> NSColor {
        status.color
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Auto-setup statusLine hook and notification hook
        needsRestart = StatusLineSetup.ensureConfigured()
        NotificationHookSetup.ensureConfigured()

        setupStatusItem()
        setupPopover()
        startAnimationLoop()
        startMonitoring()
    }

    // MARK: - Status Bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }
        button.image = createDotImage(alpha: 0.3)
        button.action = #selector(statusBarButtonClicked(_:))
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func setupPopover() {
        popover.contentSize = NSSize(width: 300, height: 0)
        popover.behavior = .transient
        popover.delegate = self
        updatePopoverContent()
    }

    private func updatePopoverContent() {
        let hostingController = NSHostingController(
            rootView: SettingsView(appDelegate: self)
        )
        popover.contentViewController = hostingController
    }

    // MARK: - Dot Rendering

    private func createDotImage(alpha: CGFloat) -> NSImage {
        let color = colorForStatus(currentStatus)
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let dotRect = NSRect(
                x: (rect.width - self.dotSize) / 2,
                y: (rect.height - self.dotSize) / 2,
                width: self.dotSize,
                height: self.dotSize
            )
            color.withAlphaComponent(alpha).setFill()
            NSBezierPath(ovalIn: dotRect).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: - Animation

    private func startAnimationLoop() {
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self, let button = self.statusItem.button else { return }
            self.pulsePhase += 1.0 / 30

            let alpha: CGFloat
            switch self.currentStatus {
            case .disconnected:
                // Static, dim
                alpha = 0.5
            case .idle:
                // Gentle breathing, 3s cycle
                let t = self.pulsePhase * (2 * .pi) / 3.0
                alpha = 0.8 + 0.2 * CGFloat(sin(t))
            case .thinking:
                // Soft pulse, 2s cycle
                let t = self.pulsePhase * (2 * .pi) / 2.0
                alpha = 0.7 + 0.3 * CGFloat(sin(t) * 0.5 + 0.5)
            case .responding:
                // Medium pulse, 1.5s cycle
                let t = self.pulsePhase * (2 * .pi) / 1.5
                alpha = 0.7 + 0.3 * CGFloat(sin(t) * 0.5 + 0.5)
            case .toolActive:
                // Fast pulse, 1s cycle
                let t = self.pulsePhase * (2 * .pi) / 1.0
                alpha = 0.7 + 0.3 * CGFloat(sin(t) * 0.5 + 0.5)
            case .awaitingPermission:
                // Blink on/off, 0.8s cycle
                let t = self.pulsePhase.truncatingRemainder(dividingBy: 0.8)
                alpha = t < 0.4 ? 1.0 : 0.35
            }
            button.image = self.createDotImage(alpha: alpha)
        }
    }

    // MARK: - Monitoring

    private func startMonitoring() {
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkClaudeStatus()
        }
        checkClaudeStatus()
    }

    private func checkClaudeStatus() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let sessions = self.monitor.detectAllSessions()
            DispatchQueue.main.async {
                self.allSessions = sessions
                let newStatus = self.primarySession?.status ?? .disconnected
                if newStatus != self.currentStatus {
                    let oldStatus = self.currentStatus
                    self.currentStatus = newStatus
                    self.pulsePhase = 0
                    SoundManager.shared.playStatusChange(from: oldStatus, to: newStatus)
                    self.updatePopoverContent()
                    if oldStatus == .awaitingPermission && newStatus != .awaitingPermission {
                        NotificationHookSetup.clearMarker()
                    }
                }
            }
        }
    }

    // MARK: - Click

    @objc private func statusBarButtonClicked(_ sender: NSStatusBarButton) {
        togglePopover(sender)
    }

    private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            updatePopoverContent()
            NSApp.setActivationPolicy(.accessory)
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            if let window = popover.contentViewController?.view.window {
                window.level = .popUpMenu
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    func popoverDidClose(_ notification: Notification) {
    }

    private static let terminalBundleIds = [
        "com.mitchellh.ghostty",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "com.apple.Terminal",
    ]

    private static let terminalMap: [(key: String, bundleId: String)] = [
        ("ghostty", "com.mitchellh.ghostty"),
        ("iterm", "com.googlecode.iterm2"),
        ("warp", "dev.warp.Warp-Stable"),
        ("terminal", "com.apple.Terminal"),
    ]

    /// Walk up process tree from a PID to find the ancestor terminal app
    private func findTerminalApp(for pid: Int) -> NSRunningApplication? {
        var current = Int32(pid)
        for _ in 0..<20 {
            let ppid = parentPID(of: current)
            if ppid <= 1 { break }
            for bundleId in Self.terminalBundleIds {
                for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleId) {
                    if app.processIdentifier == ppid {
                        return app
                    }
                }
            }
            current = ppid
        }
        return nil
    }

    /// Get parent PID using sysctl
    private func parentPID(of pid: Int32) -> Int32 {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return -1 }
        return info.kp_eproc.e_ppid
    }

    /// Get TTY for a PID via `ps`
    private func getTTY(for pid: Int) -> String? {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", "\(pid)", "-o", "tty="]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let tty = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return tty.isEmpty ? nil : "/dev/\(tty)"
        } catch {
            return nil
        }
    }

    /// Run an AppleScript via osascript and return whether it succeeded
    private func runAppleScript(_ script: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Focus the Terminal.app window/tab that owns the given TTY
    private func focusTerminalTab(tty: String) -> Bool {
        let script = """
        tell application "Terminal"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(tty)" then
                        set selected of t to true
                        set index of w to 1
                        return
                    end if
                end repeat
            end repeat
        end tell
        """
        return runAppleScript(script)
    }

    /// Focus the iTerm2 session that owns the given TTY
    private func focusITermSession(tty: String) -> Bool {
        let script = """
        tell application "iTerm2"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(tty)" then
                            select t
                            select w
                            return
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        """
        return runAppleScript(script)
    }

    /// Activate the terminal for a specific session
    func activateTerminalForSession(_ session: SessionInfo) {
        let targetPid = session.pid
        popover.performClose(nil)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let tty = self.getTTY(for: targetPid)

            DispatchQueue.main.async {
                if let tty = tty {
                    if let app = self.findTerminalApp(for: targetPid) {
                        let bundleId = app.bundleIdentifier ?? ""

                        if bundleId == "com.apple.Terminal" {
                            if self.focusTerminalTab(tty: tty) { return }
                        } else if bundleId == "com.googlecode.iterm2" {
                            if self.focusITermSession(tty: tty) { return }
                        }
                        // For Ghostty/Warp or if AppleScript failed, just activate
                        app.activate(options: .activateIgnoringOtherApps)
                        return
                    }
                }
                self.activateClaudeCode()
            }
        }
    }

    func activateClaudeCode() {
        // If there's a primary session, try to find its terminal first
        if let primary = primarySession, let app = findTerminalApp(for: primary.pid) {
            app.activate(options: .activateIgnoringOtherApps)
            return
        }

        let selected = UserDefaults.standard.string(forKey: "selectedTerminal") ?? "auto"

        if selected != "auto",
           let match = Self.terminalMap.first(where: { $0.key == selected }),
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: match.bundleId) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: appURL, configuration: config)
            return
        }

        // Auto-detect: try running terminals in priority order
        for (_, bundleId) in Self.terminalMap {
            if NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first != nil,
               let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                NSWorkspace.shared.openApplication(at: appURL, configuration: config)
                return
            }
        }
        // Fallback
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    let appDelegate: AppDelegate
    @AppStorage("soundEnabled") private var soundEnabled = true
    @AppStorage("selectedTerminal") private var selectedTerminal = "auto"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack {
                Circle()
                    .fill(Color(nsColor: appDelegate.colorForStatus(appDelegate.currentStatus)))
                    .frame(width: 10, height: 10)
                Text("Claude Dot")
                    .font(.headline)
                Spacer()
                Text("v1.0")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            // Session info
            if appDelegate.allSessions.isEmpty {
                // Disconnected
                HStack {
                    Text("label.status")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color(nsColor: ClaudeStatus.disconnected.color))
                            .frame(width: 6, height: 6)
                        Text(ClaudeStatus.disconnected.label)
                            .font(.subheadline)
                    }
                }
            } else if appDelegate.allSessions.count == 1 {
                // Single session — flat layout (no "Session 1" header)
                Button {
                    appDelegate.activateTerminalForSession(appDelegate.allSessions[0])
                } label: {
                    sessionDetailView(appDelegate.allSessions[0])
                }
                .buttonStyle(.plain)
            } else {
                // Multiple sessions — list with headers
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(appDelegate.allSessions.enumerated()), id: \.offset) { index, session in
                        if index > 0 {
                            Divider()
                        }
                        SessionRowButton(session: session, index: index + 1) {
                            appDelegate.activateTerminalForSession(session)
                        }
                    }
                }
            }

            Divider()

            // Settings
            Toggle("setting.soundAlert", isOn: $soundEnabled)
                .font(.body)
                .onChange(of: soundEnabled) { newValue in
                    SoundManager.shared.enabled = newValue
                }

            Picker("setting.terminalApp", selection: $selectedTerminal) {
                Text("setting.autoDetect").tag("auto")
                Text("Terminal").tag("terminal")
                Text("iTerm2").tag("iterm")
                Text("Warp").tag("warp")
                Text("Ghostty").tag("ghostty")
            }
            .font(.body)

            Divider()

            HStack {
                Spacer()
                Button("action.quit") {
                    NSApp.terminate(nil)
                }
                .font(.body)
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    @ViewBuilder
    private func sessionDetailView(_ session: SessionInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("label.status")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color(nsColor: session.status.color))
                        .frame(width: 6, height: 6)
                    Text(session.status.label)
                        .font(.subheadline)
                }
            }
            HStack {
                Text("PID")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(session.pid)")
                    .font(.caption.monospaced())
            }
            HStack {
                Text("label.workingDirectory")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text(shortenPath(session.cwd))
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private func shortenPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

// MARK: - Session Row Button

struct SessionRowButton: View {
    let session: SessionInfo
    let index: Int
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text("session.title \(index)")
                    .font(.subheadline.bold())
                HStack {
                    Text("label.status")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color(nsColor: session.status.color))
                            .frame(width: 6, height: 6)
                        Text(session.status.label)
                            .font(.subheadline)
                    }
                }
                HStack {
                    Text("PID")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(session.pid)")
                        .font(.caption.monospaced())
                }
                HStack {
                    Text("label.workingDirectory")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(shortenPath(session.cwd))
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovered ? Color.primary.opacity(0.08) : Color.clear)
        )
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }

    private func shortenPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
