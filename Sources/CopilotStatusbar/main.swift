import AppKit
import Foundation

struct CopilotProcess {
    let pid: Int32
    let elapsed: TimeInterval
    let cpu: Double
    let command: String
}

final class ProcessMonitor {
    private let excludedFragments = [
        "copilot-statusbar",
        "CopilotStatusbar",
        "Electron.app",
        "node_modules/electron",
        "/bin/ps -axo"
    ]

    func currentCopilotProcess() -> CopilotProcess? {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "pid=,pcpu=,etime=,command="]
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
        } catch {
            return nil
        }

        // Read the pipe BEFORE waiting for exit: `ps -axo` output for the full
        // process list on a busy Mac can exceed the pipe's kernel buffer, and
        // waiting first would deadlock (child blocks writing while we block waiting).
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        guard let output = String(data: data, encoding: .utf8) else {
            return nil
        }

        return output
            .split(separator: "\n")
            .compactMap(parseLine)
            .filter(isCopilotCLI)
            .sorted { $0.elapsed > $1.elapsed }
            .first
    }

    private func parseLine(_ line: Substring) -> CopilotProcess? {
        let parts = line
            .trimmingCharacters(in: .whitespaces)
            .split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)

        guard parts.count == 4,
              let pid = Int32(parts[0]),
              let cpu = Double(parts[1]),
              let elapsed = parseElapsed(String(parts[2])) else {
            return nil
        }

        return CopilotProcess(pid: pid, elapsed: elapsed, cpu: cpu, command: String(parts[3]))
    }

    private func isCopilotCLI(_ process: CopilotProcess) -> Bool {
        let command = process.command

        guard !excludedFragments.contains(where: { command.localizedCaseInsensitiveContains($0) }) else {
            return false
        }

        let executable = URL(fileURLWithPath: command.split(separator: " ").first.map(String.init) ?? command)
            .lastPathComponent
            .lowercased()

        if executable == "copilot" {
            return true
        }

        if command.localizedCaseInsensitiveContains("/copilot ") ||
            command.localizedCaseInsensitiveContains("/copilot-cli/") ||
            command.localizedCaseInsensitiveContains("github/copilot") {
            return true
        }

        return false
    }

    private func parseElapsed(_ value: String) -> TimeInterval? {
        let daySplit = value.split(separator: "-", maxSplits: 1).map(String.init)
        let days: Int
        let timePart: String

        if daySplit.count == 2 {
            days = Int(daySplit[0]) ?? 0
            timePart = daySplit[1]
        } else {
            days = 0
            timePart = value
        }

        let pieces = timePart.split(separator: ":").compactMap { TimeInterval($0) }
        let seconds: TimeInterval

        switch pieces.count {
        case 2:
            seconds = pieces[0] * 60 + pieces[1]
        case 3:
            seconds = pieces[0] * 3600 + pieces[1] * 60 + pieces[2]
        default:
            return nil
        }

        return TimeInterval(days * 24 * 60 * 60) + seconds
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let monitor = ProcessMonitor()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var timer: Timer?
    private var currentProcess: CopilotProcess?

    // CPU-usage based "busy" detection: the copilot process stays alive for the
    // whole CLI session, so its total elapsed time is not useful as a "working"
    // duration. Instead we watch %CPU: while Copilot is actually generating a
    // response / running tools it burns sustained CPU; typing in the prompt only
    // causes brief single-tick re-render spikes. We require a couple of
    // consecutive high-CPU samples before flipping to "working" (debounce) and
    // a couple of consecutive low-CPU samples before flipping back to idle.
    private let busyCPUThreshold = 8.0
    private let busyDebounceChecks = 2
    private let idleDebounceChecks = 2
    private var workingSince: Date?
    private var idleStreak = 0
    private var busyStreak = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        configureStatusItem()
        refresh()

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else {
            return
        }

        button.imagePosition = .imageLeft
        button.image = makeIcon(color: NSColor.systemGray)
        button.font = NSFont.systemFont(ofSize: 14, weight: .regular)
        button.title = " \(greeting())"
    }

    private func refresh() {
        currentProcess = monitor.currentCopilotProcess()

        guard let process = currentProcess else {
            workingSince = nil
            idleStreak = 0
            busyStreak = 0
            setNotRunning()
            statusItem.menu = makeMenu()
            return
        }

        if process.cpu >= busyCPUThreshold {
            idleStreak = 0
            busyStreak += 1
            if workingSince == nil && busyStreak >= busyDebounceChecks {
                workingSince = Date()
            }
        } else {
            busyStreak = 0
            idleStreak += 1
            if idleStreak >= idleDebounceChecks {
                workingSince = nil
            }
        }

        if let since = workingSince {
            setWorking(process, since: since)
        } else {
            setWaitingForInput()
        }

        statusItem.menu = makeMenu()
    }

    private func setWorking(_ process: CopilotProcess, since: Date) {
        guard let button = statusItem.button else {
            return
        }

        let duration = Date().timeIntervalSince(since)
        button.image = makeIcon(color: NSColor(calibratedRed: 0.35, green: 0.65, blue: 1.0, alpha: 1.0))
        button.title = " working \(formatDuration(duration))"
        button.toolTip = "Copilot CLI has been working for \(formatDuration(duration))"
    }

    // Copilot process is running but not burning CPU: it's sitting at the
    // prompt waiting for the next instruction from the user.
    private func setWaitingForInput() {
        guard let button = statusItem.button else {
            return
        }

        button.image = makeIcon(color: NSColor(calibratedRed: 0.96, green: 0.75, blue: 0.25, alpha: 1.0))
        button.title = " Needs your input"
        button.toolTip = "Copilot CLI is waiting for you to type a prompt"
    }

    // No copilot process found at all.
    private func setNotRunning() {
        guard let button = statusItem.button else {
            return
        }

        button.image = makeIcon(color: NSColor.systemGray)
        button.title = " \(greeting())"
        button.toolTip = "Copilot CLI is not running"
    }

    private func greeting() -> String {
        return "Waiting for a task"
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()

        if let process = currentProcess {
            let statusText = workingSince.map { "Copilot: working \(formatDuration(Date().timeIntervalSince($0)))" }
                ?? "Copilot: needs your input"
            let status = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)

            let pid = NSMenuItem(title: "PID: \(process.pid) · CPU: \(String(format: "%.0f", process.cpu))%", action: nil, keyEquivalent: "")
            pid.isEnabled = false
            menu.addItem(pid)

            let command = process.command.count > 72
                ? String(process.command.prefix(69)) + "..."
                : process.command
            let commandItem = NSMenuItem(title: command, action: nil, keyEquivalent: "")
            commandItem.isEnabled = false
            menu.addItem(commandItem)
        } else {
            let idle = NSMenuItem(title: "Copilot: not running", action: nil, keyEquivalent: "")
            idle.isEnabled = false
            menu.addItem(idle)
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Open Copilot CLI", action: #selector(openCopilotCLI), keyEquivalent: "o"))
        menu.addItem(NSMenuItem(title: "Refresh", action: #selector(refreshFromMenu), keyEquivalent: "r"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))

        return menu
    }

    @objc private func openCopilotCLI() {
        let script = """
        tell application "Terminal"
          activate
          do script "copilot"
        end tell
        """

        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
    }

    @objc private func refreshFromMenu() {
        refresh()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        let seconds = max(Int(interval), 0)
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }

        if minutes > 0 {
            return "\(minutes)m \(secs)s"
        }

        return "\(secs)s"
    }

    private static let copilotIconPNG18Base64 = "iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAAXNSR0IArs4c6QAAAERlWElmTU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAA6ABAAMAAAABAAEAAKACAAQAAAABAAAAEKADAAQAAAABAAAAEAAAAAA0VXHyAAABS0lEQVQ4Ea3SvytFYRzH8XMvKbqbuJSJQZmUECEGq/wLbslqthgMysKoZJPBQlYZGC4Gkt0o7GLQxft9Os/t6VwsfOrlfJ/v+T7HPT+S5I8p/LB/iP4c+vCJexzjBr+mi7NHcNN3POdMPcV6lSQj1Nd4QAVLeMJjVtvznDPDaMghncVcd4O14jjjbJr4F/TSucr64dBGoTjOOJumOTs2cWyH93eX9bz4LHwW1h8wzjib9tzYgk2MYwwO9mMN73jBPJydwCq8SBmnNnfgA/MJb2ESA7jEMvbRgSn4n7fRigX0IKnBn3ngIouDlbDIanshzrqn5n0onxkau1HT2l4+RTdX813Wb3iN+q6VT7q3RHcPfiTeV3htndQhofacM866p1TgT4gPaQWjOIPv26/QdMP+NC6wjnMk8QVcG1+R738QZZhn3OIEft7/ly/ZIkSUv4/C9wAAAABJRU5ErkJggg=="
    private static let copilotIconPNG36Base64 = "iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAAAXNSR0IArs4c6QAAAERlWElmTU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAA6ABAAMAAAABAAEAAKACAAQAAAABAAAAIKADAAQAAAABAAAAIAAAAACshmLzAAADFUlEQVRYCe2WO4xMURjHrecmHkEQj2yEECpEQUOxyaoUFEhEpdcoVXRKoRBCYyPRUBAi0diQEI1C2GAjK4TdQtjEY9dz/X4z882cuXtmMrtZUfBP/vd853v8v3PPvffMTJnyr6Ntghuwhjo5H47CD7AP9sM/hs0on4evoU1zfIn/LNwIJw0dKF2HuYbNfNeosXbCmEnlITgEmzVqFrNWDbWyaPQOLCX7BnTbxQh8Ct84ARtg8e58NI8MghVwPWx3Ah7CnXDQSSu4TZJ39hzugSGEWcJUrqdh3L22vhTWWKuGeWq2hO1kWeBqFzWpcAdiAcXdSMvUUMvcbWlAu7hqfV1eQDd8V7Lyl4HE/Taxi6Yaaokd5aF2zS1gZSX8pJaWteYm3nmJnTN7K87QrubkFhBv7LdqVt5Ym7hTO3FXza8VK7SrgdwCflaiC6pZeaMzcad24q6aoRXa1UDRmI0jvvuLxWAyn4X9AsZLqK2vEdQy1yPbHllMx3sMhugP7AOweFZ4/l+u5L1ilNboM5bCWjXUCt2j2Paqw3JmHhaR9Dix/YRuwSuwB36B5r2HnvmbKrY+Yz3QXGvi8zOWatrLniX4Nj+D0dxxLzwI022OuM/xJlwHA9r6jEVejGqopWb4HO1Z+pJOFQIGTQ6swuiCu2EnXAIbwZg55lpjbaC4APucNDgM05UVF2DOZCC3gGE/w/ZxqO8idwiey9ToM2ZOqyj1Lt59sx24hLJxn3UR8fzNySG3A6O5gyhXHL5pFSNXF77IiZqmo0V+Kn8Lgy5gP/T7bQX+KRExlmfla/hiTGM52572LmEL1/TP5hnmc8qhuqvb60/q4jpveaLPWO4RqKVmvG/2smcdFjLrhr+giZ50x+FqOFFYq4ZaaqptD3s1xFYid2Gs1vEePAKNjflJxRcwZo6592GqcacSY6ihrWaOsRQ6DP2u07PiO/N+6DZ+hMIjtQN68s2AgRGMq/AEfBDO8Y4+v33wAuyF8b2ndxe2MXPMtSb3HuGuodkO1LLqLUX9B7QMxm/7Z+wB2Ac/wf9oeQd+A+Gw+UJHHnckAAAAAElFTkSuQmCC"

    private static let copilotIcon: NSImage? = {
        guard let data18 = Data(base64Encoded: copilotIconPNG18Base64),
              let data36 = Data(base64Encoded: copilotIconPNG36Base64),
              let rep18 = NSBitmapImageRep(data: data18),
              let rep36 = NSBitmapImageRep(data: data36) else {
            return nil
        }
        rep18.size = NSSize(width: 16, height: 16)
        rep36.size = NSSize(width: 16, height: 16)
        let image = NSImage(size: NSSize(width: 16, height: 16))
        image.addRepresentation(rep18)
        image.addRepresentation(rep36)
        image.isTemplate = true
        return image
    }()

    private func makeIcon(color: NSColor) -> NSImage {
        if let icon = Self.copilotIcon {
            return icon
        }

        // Fallback if SVG rendering is unavailable on this macOS version.
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        let rect = NSRect(x: 1, y: 1, width: 16, height: 16)
        let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        color.setStroke()
        path.lineWidth = 1.8
        path.stroke()
        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
