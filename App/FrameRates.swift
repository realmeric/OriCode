import AppKit
import IOKit.ps
import QuartzCore

/// How fast what moves by itself asks the display to draw it. A ProMotion display runs at 120 Hz
/// for anything that asks for nothing, and text appearing word by word reads the same at 60;
/// 120 stays for what the user moves, a scroll or the composer, which AppKit draws at its own
/// rate. On battery it asks for less, and in Low Power Mode less again.
@MainActor
enum FrameRates {
    enum Power: Equatable {
        case plugged, battery, low
    }

    /// What moves: a reply's words as they're shown, the fast mark's spin, the picker's bubbles.
    /// On battery 40 where the display's rate divides by it, ProMotion's 120, and 30 on one of
    /// 60: asked for 40, a 60 Hz display fired at 60, not at the 30 under it.
    static func motion(_ power: Power, display: Int = displayRate) -> CAFrameRateRange {
        switch power {
        case .plugged: CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        case .battery:
            display % 40 == 0
                ? CAFrameRateRange(minimum: 30, maximum: 40, preferred: 40)
                : CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
        case .low: CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
        }
    }

    /// The fastest the main display draws: 120 for ProMotion, 60 for most.
    static var displayRate: Int { NSScreen.main?.maximumFramesPerSecond ?? 60 }

    /// What drifts: the slow mark turning 40° a second and the dot pulsing while an ask waits.
    static func drift(_ power: Power) -> CAFrameRateRange {
        power == .low
            ? CAFrameRateRange(minimum: 10, maximum: 20, preferred: 15)
            : CAFrameRateRange(minimum: 10, maximum: 30, preferred: 20)
    }

    static func power(lowPowerMode: Bool, onBattery: Bool) -> Power {
        lowPowerMode ? .low : onBattery ? .battery : .plugged
    }
}

/// The Mac's power as the frame rates read it, told by the system when it changes: Low Power
/// Mode's notification and IOKit's for the power source, nothing polled.
@MainActor
final class PowerState {
    static let shared = PowerState()
    static let changed = Notification.Name("OriCodePowerChanged")

    private(set) var power: FrameRates.Power
    private var source: CFRunLoopSource?

    private init() {
        power = Self.read()
        NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { PowerState.shared.update() }
        }
        // The callback carries no context: the shared state is the only one there is.
        source = IOPSNotificationCreateRunLoopSource({ _ in
            MainActor.assumeIsolated { PowerState.shared.update() }
        }, nil)?.takeRetainedValue()
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode) }
    }

    private func update() {
        let now = Self.read()
        guard now != power else { return }
        power = now
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    private static func read() -> FrameRates.Power {
        let type = IOPSGetProvidingPowerSourceType(IOPSCopyPowerSourcesInfo()?.takeRetainedValue())?.takeUnretainedValue() as String?
        return FrameRates.power(lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled, onBattery: type == kIOPMBatteryPowerKey)
    }
}
