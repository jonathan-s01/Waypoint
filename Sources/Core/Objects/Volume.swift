import Foundation
import CoreAudio
import AudioToolbox

// Volume up and down for the default output device (Waypoint, Nov 2026), as the keyboard's own volume keys do it: the
// device's virtual main volume, which a USB audio device such as a dock's accepts where AppleScript's 0-100 setting
// jumps to the top and then goes silent (observed on a CalDigit TS4, 10 Nov 2026). Every press reads the volume the
// device has now (nothing is remembered), adds or takes off one step, and sets it. The Core Audio calls run on their own
// serial queue, never on the main thread or the keyboard's.

/// One of the device's volume controls, as the logic names them.
nonisolated public enum VolumeControl: Hashable, Sendable {
    /// kAudioHardwareServiceDeviceProperty_VirtualMainVolume: the whole device's volume.
    case virtualMain
    /// The left and right channels' own scalar volumes, for a device with no virtual main volume.
    case channel1, channel2
    /// The device's mute switch (1 muted, 0 not).
    case mute
}

/// What the logic asks of the audio system; Core Audio's answers in the app, a fake in the tests. Used from one queue.
nonisolated public protocol VolumeBackend: AnyObject {
    /// The default output device, nil when there is none.
    func outputDevice() -> UInt32?
    /// The control exists on the device and can be set.
    func canSet(_ control: VolumeControl, on device: UInt32) -> Bool
    func get(_ control: VolumeControl, on device: UInt32) -> Float?
    func set(_ control: VolumeControl, _ value: Float, on device: UInt32) -> Bool
}

nonisolated public enum VolumeLogic {
    public static let defaultStep: Double = 0.01
    public static let stepRange: ClosedRange<Double> = 0.005...0.25

    nonisolated public enum Outcome: Equatable, Sendable {
        /// The volume was set: what it was and what it is now, and whether the mute was cleared.
        case changed(from: Float, to: Float, unmuted: Bool)
        case noDevice
        /// The device has no volume that can be set.
        case notAdjustable
        /// A control was there but refused the new value.
        case failed
    }

    /// A step within 0.5 to 25 percent; the default for nothing usable.
    public static func clampStep(_ s: Double?) -> Double {
        guard let s, s.isFinite else { return defaultStep }
        return min(max(s, stepRange.lowerBound), stepRange.upperBound)
    }

    public static func clamp(_ v: Float) -> Float {
        guard v.isFinite else { return 0 }
        return min(max(v, 0), 1)
    }

    /// The volume after one step up or down, kept within 0 to 1.
    public static func stepped(_ current: Float, up: Bool, step: Double) -> Float {
        clamp((current.isFinite ? current : 0) + Float(up ? step : -step))
    }

    /// A device that is muted is unmuted by raising the volume (as the keyboard's volume keys do); lowering leaves it.
    public static func shouldClearMute(raising: Bool, muted: Bool) -> Bool { raising && muted }

    /// Reads the device's volume now, adds or takes off a step, sets it; with the mute cleared when raising from mute.
    public static func adjust(up: Bool, step: Double, backend: VolumeBackend) -> Outcome {
        guard let device = backend.outputDevice() else { return .noDevice }
        let step = clampStep(step)
        let outcome: Outcome
        if backend.canSet(.virtualMain, on: device), let current = backend.get(.virtualMain, on: device) {
            let new = stepped(current, up: up, step: step)
            if backend.set(.virtualMain, new, on: device) { outcome = .changed(from: current, to: new, unmuted: false) }
            else { outcome = channels(up: up, step: step, device: device, backend: backend) ?? .failed }   // refused: try the channels
        } else {
            outcome = channels(up: up, step: step, device: device, backend: backend) ?? .notAdjustable
        }
        guard case .changed(let from, let to, _) = outcome else { return outcome }
        var unmuted = false
        if backend.canSet(.mute, on: device), let m = backend.get(.mute, on: device),
           shouldClearMute(raising: up, muted: m >= 0.5), backend.set(.mute, 0, on: device) {
            unmuted = true
        }
        return .changed(from: from, to: to, unmuted: unmuted)
    }

    /// No virtual main volume to set: the two channels, both to the same level so the balance comes out even. Nil when
    /// there is no channel that can be set; .failed when every one refused.
    private static func channels(up: Bool, step: Double, device: UInt32, backend: VolumeBackend) -> Outcome? {
        let settable = [VolumeControl.channel1, .channel2].filter { backend.canSet($0, on: device) }
        let values = settable.compactMap { backend.get($0, on: device) }
        guard !settable.isEmpty, !values.isEmpty else { return nil }
        let current = values.reduce(0, +) / Float(values.count)
        let new = stepped(current, up: up, step: step)
        var anySet = false
        for c in settable where backend.set(c, new, on: device) { anySet = true }
        return anySet ? .changed(from: current, to: new, unmuted: false) : .failed
    }
}

/// Core Audio's side: stateless, so any queue may use it.
nonisolated final class CoreAudioVolume: VolumeBackend, Sendable {
    static let shared = CoreAudioVolume()

    private func address(_ control: VolumeControl) -> AudioObjectPropertyAddress {
        switch control {
        case .virtualMain: return AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        case .channel1: return AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioObjectPropertyScopeOutput, mElement: 1)
        case .channel2: return AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioObjectPropertyScopeOutput, mElement: 2)
        case .mute: return AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        }
    }

    func outputDevice() -> UInt32? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &device) == noErr,
              device != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        return device
    }

    func canSet(_ control: VolumeControl, on device: UInt32) -> Bool {
        var a = address(control)
        guard AudioObjectHasProperty(device, &a) else { return false }
        var settable = DarwinBoolean(false)
        return AudioObjectIsPropertySettable(device, &a, &settable) == noErr && settable.boolValue
    }

    func get(_ control: VolumeControl, on device: UInt32) -> Float? {
        var a = address(control)
        guard AudioObjectHasProperty(device, &a) else { return nil }
        if control == .mute {
            var v = UInt32(0), size = UInt32(MemoryLayout<UInt32>.size)
            return AudioObjectGetPropertyData(device, &a, 0, nil, &size, &v) == noErr ? Float(v) : nil
        }
        var v = Float32(0), size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(device, &a, 0, nil, &size, &v) == noErr ? v : nil
    }

    func set(_ control: VolumeControl, _ value: Float, on device: UInt32) -> Bool {
        var a = address(control)
        if control == .mute {
            var v = UInt32(value >= 0.5 ? 1 : 0)
            return AudioObjectSetPropertyData(device, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v) == noErr
        }
        var v = Float32(value)
        return AudioObjectSetPropertyData(device, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) == noErr
    }
}

/// The runtime: the step setting, the queue, and what is said when there is nothing to adjust.
public enum Volume {
    static let stepKey = "waypoint.volume.step"

    /// The step one press makes, as a fraction of the whole range (0.01 is one in a hundred).
    public static var step: Double {
        get { VolumeLogic.clampStep(UserDefaults.standard.object(forKey: stepKey) as? Double) }
        set { UserDefaults.standard.set(VolumeLogic.clampStep(newValue), forKey: stepKey) }
    }

    private static let queue = DispatchQueue(label: "waypoint.volume", qos: .userInitiated)
    /// Presses waiting on the queue: when the audio system is slow the rest are dropped, not piled up.
    nonisolated private static let waiting = Locked(0)
    nonisolated private static let maximumWaiting = 4
    private static var lastComplaint = Date.distantPast

    /// One step up or down on the default output device, off the main thread.
    public static func adjust(up: Bool, backend: VolumeBackend? = nil, feedback: VolumeFeedbackGate? = nil) {
        let backend = backend ?? CoreAudioVolume.shared
        let gate = feedback ?? VolumeFeedback.shared
        let step = Self.step
        let accepted: Bool = {
            waiting.lock.lock(); defer { waiting.lock.unlock() }
            guard waiting.unsafeValue < maximumWaiting else { return false }
            waiting.unsafeValue += 1
            return true
        }()
        guard accepted else { return }
        let handed = Handed(backend)
        queue.async {
            let outcome = VolumeLogic.adjust(up: up, step: step, backend: handed.value)
            waiting.lock.lock(); waiting.unsafeValue -= 1; waiting.lock.unlock()
            switch outcome {
            case .changed: gate.changed(outcome)   // the pop, at the volume it is now
            case .noDevice, .notAdjustable, .failed: onMain { complain(outcome) }
            }
        }
    }

    /// Said at most once a second, so a held key does not chatter.
    private static func complain(_ outcome: VolumeLogic.Outcome) {
        let now = Date()
        guard now.timeIntervalSince(lastComplaint) >= 1 else { return }
        lastComplaint = now
        switch outcome {
        case .noDevice:
            Log.warning("volume: there is no default output device")
            Speech.speakMessage(String(localized: "No sound output device", comment: "Spoken message: the volume keys have no device to adjust"))
        case .notAdjustable:
            Log.warning("volume: the default output device has no volume that can be set")
            Speech.speakMessage(String(localized: "This sound device has no volume control", comment: "Spoken message: the volume keys cannot change this device's volume"))
        default:
            Log.warning("volume: the device refused the new volume")
            Speech.speakMessage(String(localized: "The volume could not be changed", comment: "Spoken message"))
        }
    }

    /// The step in whole percent as a list to choose from; the choice is kept.
    static func chooseStep() {
        let choices: [Double] = [0.005, 0.01, 0.02, 0.05, 0.1]
        let items = choices.map { value -> MenuItem in
            let percent = value * 100
            let text = percent == percent.rounded() ? String(Int(percent)) : String(percent)
            let title = String(localized: "\(text) percent a press", comment: "Volume step choice: %@ is a number")
            return MenuItem(verbatim: title, .action {
                step = value
                Speech.speakMessage(title)
            }, hint: abs(value - step) < 0.0001 ? String(localized: "current", comment: "A choice that is on now") : nil)
        }
        TurnOverMenu.shared.openList(verbatim: String(localized: "Volume step", comment: "A list's title"), items: items)
    }
}

/// The volume commands, in the key list under Waypoint. A launcher key can run them (command volumeUp), and repeat them.
final class VolumePlugin: GlobalPlugin {
    required init() {
        super.init()
        let category = "Waypoint"
        script("volumeUp", String(localized: "Raises the volume of the sound output device by one step", comment: "A command, as the key list and keyboard help say it"), category: category) { _ in
            Volume.adjust(up: true)
        }
        script("volumeDown", String(localized: "Lowers the volume of the sound output device by one step", comment: "A command, as the key list and keyboard help say it"), category: category) { _ in
            Volume.adjust(up: false)
        }
        script("volumeSetStep", String(localized: "Chooses how much one press of volume up or down changes the volume", comment: "A command, as the key list and keyboard help say it"), category: category) { _ in
            Volume.chooseStep()
        }
        script("volumeFeedbackEnable", String(localized: "Turns the sound played when the volume changes on or off", comment: "A command, as the key list and keyboard help say it"), category: category) { _ in
            VolumeFeedback.toggle()
        }
    }
}
