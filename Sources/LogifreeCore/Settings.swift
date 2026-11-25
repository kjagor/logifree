import Foundation
import notify

public enum ThumbGesture: String, Codable, CaseIterable, CodingKeyRepresentable {
    case click, swipeUp, swipeDown, swipeLeft, swipeRight

    /// Hold-and-move distance (raw sensor counts) → gesture.
    public static func classify(dx: Int, dy: Int, threshold: Int) -> ThumbGesture {
        if max(abs(dx), abs(dy)) < threshold { return .click }
        if abs(dx) > abs(dy) { return dx < 0 ? .swipeLeft : .swipeRight }
        return dy < 0 ? .swipeUp : .swipeDown
    }
}

/// What turning the side (thumb) wheel does.
public enum ThumbwheelAction: String, Codable, CaseIterable {
    case horizontalScroll, smoothScroll, volume, zoom, tabs, desktops

    /// Diverted rotation counts per step. The MX Master 4 reports 120 diverted counts
    /// where it natively reports 20, so 6 counts = one native scroll increment.
    // shortcut: fixed step size, make it a setting if it feels wrong
    public var stepSize: Int { self == .volume ? 6 : 12 }
}

/// Turns diverted thumb wheel rotation into whole steps, keeping the remainder.
public struct ThumbwheelStepper {
    private var accumulated = 0
    private var lastMovement: TimeInterval = 0

    public init() {}

    /// Steps to fire now, signed like `rotation`. `now` is any monotonic clock in seconds.
    public mutating func steps(rotation: Int, stepSize: Int, now: TimeInterval) -> Int {
        // A pause or a reversal starts over, so stale leftovers never fire a step.
        if now - lastMovement > 1 || (rotation < 0) != (accumulated < 0) { accumulated = 0 }
        lastMovement = now
        accumulated += rotation
        let steps = accumulated / stepSize
        accumulated -= steps * stepSize
        return steps
    }
}

public struct KeyCombo: Codable, Hashable {
    /// macOS virtual key code; `nil` until one is recorded.
    public var key: UInt16?
    /// `CGEventFlags` / `NSEvent.ModifierFlags` raw value (same bits).
    public var modifiers: UInt64
    /// What to show in the UI, e.g. "⌘⇧4".
    public var display: String

    public init(key: UInt16?, modifiers: UInt64, display: String) {
        self.key = key
        self.modifiers = modifiers
        self.display = display
    }

    public static let unset = KeyCombo(key: nil, modifiers: 0, display: "")
}

public enum Action: Codable, Hashable {
    case missionControl
    case appExpose
    case showDesktop
    case desktopLeft
    case desktopRight
    /// A normal middle-click, e.g. when the middle button is the gesture button.
    case middleClick
    case keystroke(KeyCombo)
    case shell(String)
}

/// "Open folder" is stored as a plain shell action: `open '<path>'`, with `'` written as `'\''`.
public func openFolderCommand(_ path: String) -> String {
    "open '" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// The folder path if `command` is exactly what `openFolderCommand` produces, else nil.
public func openFolderPath(_ command: String) -> String? {
    guard command.hasPrefix("open '"), command.hasSuffix("'"), command.count > 7 else { return nil }
    let path = command.dropFirst(6).dropLast().replacingOccurrences(of: "'\\''", with: "\u{0}")
    return path.contains("'") ? nil : path.replacingOccurrences(of: "\u{0}", with: "'")
}

/// Lives in `~/Library/Application Support/logifree/settings.json`. The app writes
/// it and posts `reloadNotification`; the agent re-reads and re-applies.
public struct Settings: Codable, Equatable {
    public var invertWheel = true
    public var invertThumbwheel = true
    public var thumbwheelAction = ThumbwheelAction.horizontalScroll
    private static let defaultGestures: [ThumbGesture: Action] = [
        .click: .missionControl,
        .swipeUp: .missionControl,
        .swipeDown: .appExpose,
        .swipeLeft: .desktopLeft,
        .swipeRight: .desktopRight,
    ]
    /// Small gesture button (or the middle-button fallback).
    public var gestures = Settings.defaultGestures
    /// Haptic panel on mice that have one (MX Master 4).
    public var panelGestures = Settings.defaultGestures
    public var swipeThreshold = 50
    /// Slow wheel clicks scroll at least this many lines; 1 = macOS default.
    /// Faster scrolling, which macOS already accelerates past this, is untouched.
    public var minimumLinesPerClick = 2
    /// System-wide key → key remaps for every keyboard.
    public var keyRemaps: [KeyRemap] = []
    /// Pushing the scroll wheel sideways, on mice with a tilt wheel. nil = the mouse's own horizontal scroll.
    public var tiltLeft: Action?
    public var tiltRight: Action?

    public init() {}

    // Missing keys fall back to defaults, so adding a setting never breaks an old file.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Settings()
        invertWheel = try container.decodeIfPresent(Bool.self, forKey: .invertWheel) ?? defaults.invertWheel
        invertThumbwheel = try container.decodeIfPresent(Bool.self, forKey: .invertThumbwheel) ?? defaults.invertThumbwheel
        thumbwheelAction = try container.decodeIfPresent(ThumbwheelAction.self, forKey: .thumbwheelAction)
            ?? defaults.thumbwheelAction
        gestures = try container.decodeIfPresent([ThumbGesture: Action].self, forKey: .gestures) ?? defaults.gestures
        // Old files had one set for both buttons: keep that behaviour.
        panelGestures = try container.decodeIfPresent([ThumbGesture: Action].self, forKey: .panelGestures) ?? gestures
        swipeThreshold = try container.decodeIfPresent(Int.self, forKey: .swipeThreshold) ?? defaults.swipeThreshold
        minimumLinesPerClick = try container.decodeIfPresent(Int.self, forKey: .minimumLinesPerClick)
            ?? defaults.minimumLinesPerClick
        keyRemaps = try container.decodeIfPresent([KeyRemap].self, forKey: .keyRemaps) ?? defaults.keyRemaps
        tiltLeft = try container.decodeIfPresent(Action.self, forKey: .tiltLeft)
        tiltRight = try container.decodeIfPresent(Action.self, forKey: .tiltRight)
    }

    public static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/logifree")
    public static let url = directory.appendingPathComponent("settings.json")
    public static let reloadNotification = "dev.raimond.logifree.reload"

    public static func load() -> Settings {
        guard let data = try? Data(contentsOf: url) else { return Settings() }
        do {
            return try JSONDecoder().decode(Settings.self, from: data)
        } catch {
            Log.info("settings.json unreadable, using defaults: \(error)")
            return Settings()
        }
    }

    /// Write, then tell the agent.
    public func save() throws {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.url, options: .atomic)
        Self.postReload()
    }

    public static func postReload() { notify_post(reloadNotification) }

    /// Calls `handler` on main whenever someone posts `reloadNotification`.
    public static func observeReload(_ handler: @escaping () -> Void) {
        var token: Int32 = 0
        notify_register_dispatch(reloadNotification, &token, .main) { _ in handler() }
    }
}

/// What the agent reports about itself and your devices, for the app to show.
/// Rewritten by the agent whenever something changes. The agent is the only
/// process that talks to devices, so the window needs no Input Monitoring.
public struct AgentStatus: Codable {
    /// A connected device the agent has configured.
    public struct DeviceState: Codable {
        public var name: String
        public var isMouse: Bool
        /// "Bluetooth" or "Bolt receiver".
        public var route: String
        /// What went wrong applying settings, if anything did.
        public var problem: String?
        /// Easy-Switch channels; empty without Easy-Switch.
        public var slots: [HostSlot]
        public var canForget: Bool
        /// The channel it announced switching to; it's about to leave this Mac.
        public var switchedTo: UInt8?
        /// Has a tilt scroll wheel whose sides can be reassigned.
        public var hasTilt: Bool

        public init(name: String, isMouse: Bool, route: String, problem: String?,
                    slots: [HostSlot], canForget: Bool, switchedTo: UInt8?, hasTilt: Bool) {
            self.hasTilt = hasTilt
            self.name = name
            self.isMouse = isMouse
            self.route = route
            self.problem = problem
            self.slots = slots
            self.canForget = canForget
            self.switchedTo = switchedTo
        }

        // An old status file has no hasTilt.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            isMouse = try container.decode(Bool.self, forKey: .isMouse)
            route = try container.decode(String.self, forKey: .route)
            problem = try container.decodeIfPresent(String.self, forKey: .problem)
            slots = try container.decode([HostSlot].self, forKey: .slots)
            canForget = try container.decode(Bool.self, forKey: .canForget)
            switchedTo = try container.decodeIfPresent(UInt8.self, forKey: .switchedTo)
            hasTilt = try container.decodeIfPresent(Bool.self, forKey: .hasTilt) ?? false
        }
    }

    /// An `AgentCommand` the agent couldn't carry out.
    public struct Failure: Codable {
        public var command: UUID
        public var message: String

        public init(command: UUID, message: String) {
            self.command = command
            self.message = message
        }
    }

    public var pid: Int32
    public var accessibility: Bool
    public var devices: [DeviceState]
    public var failure: Failure?

    public init(accessibility: Bool, devices: [DeviceState], failure: Failure?) {
        pid = getpid()
        self.accessibility = accessibility
        self.devices = devices
        self.failure = failure
    }

    public static let url = Settings.directory.appendingPathComponent("status.json")

    public static func load() -> AgentStatus? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AgentStatus.self, from: data)
    }

    public func save() {
        try? FileManager.default.createDirectory(at: Settings.directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(self).write(to: Self.url, options: .atomic)
        notify_post(Self.changedNotification)
    }

    public static let changedNotification = "dev.raimond.logifree.status"
    /// Posted by the app to make the agent undo its changes and exit.
    public static let quitNotification = "dev.raimond.logifree.quit"

    public static func postQuit() { notify_post(quitNotification) }

    public static func observeQuit(_ handler: @escaping () -> Void) {
        var token: Int32 = 0
        notify_register_dispatch(quitNotification, &token, .main) { _ in handler() }
    }

    /// Calls `handler` on main whenever the agent rewrites its status.
    public static func observeChanges(_ handler: @escaping () -> Void) {
        var token: Int32 = 0
        notify_register_dispatch(changedNotification, &token, .main) { _ in handler() }
    }
}

/// An Easy-Switch change the app asks the agent to make on a device.
public struct AgentCommand: Codable {
    public enum Action: Codable {
        case switchHost(UInt8)
        case rename(UInt8, String)
        case forget(UInt8)
    }

    public var id = UUID()
    /// `AgentStatus.DeviceState.name`.
    public var device: String
    public var action: Action

    public init(device: String, action: Action) {
        self.device = device
        self.action = action
    }

    public static let url = Settings.directory.appendingPathComponent("command.json")
    public static let notification = "dev.raimond.logifree.command"

    /// Write, then tell the agent. Failures come back in `AgentStatus.failure`.
    public func send() throws {
        try FileManager.default.createDirectory(at: Settings.directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: Self.url, options: .atomic)
        notify_post(Self.notification)
    }

    /// The pending command, removed so it runs once.
    public static func take() -> AgentCommand? {
        defer { try? FileManager.default.removeItem(at: url) }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AgentCommand.self, from: data)
    }

    /// Calls `handler` on main whenever the app sends a command.
    public static func observe(_ handler: @escaping () -> Void) {
        var token: Int32 = 0
        notify_register_dispatch(notification, &token, .main) { _ in handler() }
    }
}
