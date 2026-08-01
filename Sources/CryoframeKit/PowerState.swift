//
//  PowerState.swift
//  CryoframeKit
//
//  A scheduled backup is unattended work: it can spin disks, mount images, and
//  push gigabytes over a network for an hour. On a laptop running low on battery
//  that's the difference between "my Mac lasted the flight" and "it died at 40%
//  because something woke up at 2 AM."
//
//  So scheduled runs check the battery first. Manual runs never do — if you press
//  Run now, you meant it.
//

import Foundation
#if canImport(IOKit)
import IOKit.ps
#endif

public struct PowerState: Sendable, Equatable {
    /// running from the battery rather than the wall.
    public let onBattery: Bool
    /// charge remaining, 0–100. nil on a Mac with no battery at all (a desktop).
    public let percentRemaining: Int?

    public var hasBattery: Bool { percentRemaining != nil }

    public init(onBattery: Bool, percentRemaining: Int?) {
        self.onBattery = onBattery; self.percentRemaining = percentRemaining
    }

    /// a desktop: always plugged in, nothing to conserve.
    public static let wallPower = PowerState(onBattery: false, percentRemaining: nil)
}

/// how the system's power state is read. Injected so the policy can be tested
/// without a battery (and so a desktop build behaves predictably).
public protocol PowerSource: Sendable {
    func current() -> PowerState
}

public struct SystemPowerSource: PowerSource {
    public init() {}

    public func current() -> PowerState {
        #if canImport(IOKit)
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else { return .wallPower }

        let providing = IOPSGetProvidingPowerSourceType(snapshot)?.takeRetainedValue() as String?
        let onBattery = providing == kIOPMBatteryPowerKey

        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                  let current = desc[kIOPSCurrentCapacityKey] as? Int,
                  let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            return PowerState(onBattery: onBattery, percentRemaining: Int((Double(current) / Double(max)) * 100))
        }
        // power sources exist but none reported a capacity — treat as wall power
        // rather than blocking backups on a reading we don't understand.
        return PowerState(onBattery: onBattery, percentRemaining: nil)
        #else
        return .wallPower
        #endif
    }
}

/// Should an unattended run wait for a better moment?
///
/// Deliberately permissive: it only holds back when we're certain we're on battery
/// AND certain the charge is low. Anything unknown — no battery, unreadable level,
/// plugged in — runs. A backup that doesn't happen is the failure mode that matters.
public enum BatteryPolicy {
    /// the default floor. Below this, a scheduled run waits for the next hourly
    /// check (by which time the Mac may be plugged in again).
    public static let defaultMinimumPercent = 20

    public static func shouldDeferScheduledRun(_ power: PowerState,
                                               minimumPercent: Int = defaultMinimumPercent) -> Bool {
        guard power.onBattery, let percent = power.percentRemaining else { return false }
        return percent < minimumPercent
    }

    /// a line for the run log / history when a run is held back.
    public static func deferralReason(_ power: PowerState) -> String {
        let pct = power.percentRemaining.map { "\($0)%" } ?? "low"
        return "on battery at \(pct) — waiting for power"
    }
}
