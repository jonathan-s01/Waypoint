import Foundation
import AVFoundation

// The pop macOS plays when the volume keys change the volume (Waypoint, Nov 2026), after each change Waypoint's own
// volume commands make, at the new volume. It follows the system's "Play feedback when volume is changed" and has its
// own switch. It plays on its own player, on the volume queue: nothing of the speech is stopped or ducked, and neither
// the main thread nor the keyboard's waits for it.

/// Plays the pop; the real one in the app, a fake in the tests.
nonisolated public protocol VolumeFeedbackPlayer: AnyObject {
    /// Starts the pop, from the beginning if it is still going.
    func play()
}

nonisolated public enum VolumeFeedbackLogic {
    /// The shortest time between two pops: a held key (15 changes a second) pops about 7 times a second, not in a buzz.
    public static let minimumInterval: TimeInterval = 0.1

    /// The volume actually changed (it was not already at its limit), or a mute was cleared.
    public static func isAudibleChange(_ outcome: VolumeLogic.Outcome) -> Bool {
        guard case .changed(let from, let to, let unmuted) = outcome else { return false }
        return unmuted || abs(from - to) > 0.0001
    }

    /// Whether to pop for this outcome: both switches on, a real change, and not too soon after the last pop.
    public static func shouldPlay(_ outcome: VolumeLogic.Outcome, feedbackOn: Bool, systemFeedbackOn: Bool, now: TimeInterval, lastPlayed: TimeInterval?) -> Bool {
        guard feedbackOn, systemFeedbackOn, isAudibleChange(outcome) else { return false }
        if let last = lastPlayed, now - last < minimumInterval { return false }
        return true
    }
}

/// Decides and plays. Used from the volume queue only (one call at a time); the lock is for the tests' sake and teardown.
nonisolated public final class VolumeFeedbackGate: @unchecked Sendable {
    // Checked isolation cannot express this: the gate is made once and then called from the volume's serial queue, and
    // `lastPlayed` is only read or written under `lock`, so any caller on any queue is safe too.
    private let lock = NSLock()
    private var lastPlayed: TimeInterval?
    private let player: VolumeFeedbackPlayer
    private let clock: @Sendable () -> TimeInterval
    private let feedbackOn: @Sendable () -> Bool
    private let systemFeedbackOn: @Sendable () -> Bool

    public init(player: VolumeFeedbackPlayer, clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                feedbackOn: @escaping @Sendable () -> Bool = { VolumeFeedback.enabled },
                systemFeedbackOn: @escaping @Sendable () -> Bool = { VolumeFeedback.systemEnabled }) {
        self.player = player; self.clock = clock; self.feedbackOn = feedbackOn; self.systemFeedbackOn = systemFeedbackOn
    }

    /// Pops when the rules say so; true when it did.
    @discardableResult
    public func changed(_ outcome: VolumeLogic.Outcome) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = clock()
        guard VolumeFeedbackLogic.shouldPlay(outcome, feedbackOn: feedbackOn(), systemFeedbackOn: systemFeedbackOn(), now: now, lastPlayed: lastPlayed) else { return false }
        lastPlayed = now
        player.play()
        return true
    }
}

/// The real pop: the system's own file, played through AVAudioPlayer on the default output device.
nonisolated public final class SystemVolumePop: VolumeFeedbackPlayer, @unchecked Sendable {
    public static let file = URL(fileURLWithPath: "/System/Library/LoginPlugins/BezelServices.loginPlugin/Contents/Resources/volume.aiff")
    // Checked isolation cannot express this: the AVAudioPlayer is not Sendable, and is made and used only inside the
    // gate's `changed`, which holds the gate's lock and runs on the volume queue; nothing else reaches it.
    private var player: AVAudioPlayer?
    private var missing = false

    nonisolated public func play() {
        if player == nil, !missing {
            guard let p = try? AVAudioPlayer(contentsOf: Self.file) else { missing = true; return }   // no file: silently none
            p.prepareToPlay()
            player = p
        }
        guard let p = player else { return }
        p.volume = 1
        p.currentTime = 0
        p.play()
    }
}

public enum VolumeFeedback {
    nonisolated static let key = "waypoint.volume.feedback"
    nonisolated static let systemKey = "com.apple.sound.beep.feedback"

    /// Waypoint's own switch for the pop; on until turned off.
    nonisolated public static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// The system's "Play feedback when volume is changed" (1 on); on when it was never set.
    nonisolated public static var systemEnabled: Bool {
        guard let v = CFPreferencesCopyAppValue(systemKey as CFString, kCFPreferencesAnyApplication) else { return true }
        if let n = v as? NSNumber { return n.boolValue }
        return true
    }

    nonisolated public static let shared = VolumeFeedbackGate(player: SystemVolumePop())

    static func toggle() {
        enabled.toggle()
        Speech.speakMessage(enabled
            ? String(localized: "Volume sound on", comment: "Spoken message: the pop played when the volume changes is on")
            : String(localized: "Volume sound off", comment: "Spoken message: the pop played when the volume changes is off"))
    }
}
