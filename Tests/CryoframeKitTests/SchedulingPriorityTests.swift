//
//  SchedulingPriorityTests.swift
//  CryoframeKitTests
//
//  A scheduled run and the tools it launches never run at background priority: a
//  tool there gets almost no CPU while the Mac is busy, and the watchdog takes that
//  for a stall.
//

import Testing
import Foundation
@testable import CryoframeKit

@Suite struct SchedulingPriorityTests {
    @Test func theAgentIsNotLeftToLaunchdsThrottling() throws {
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Cryoframe/app.cryoframe.agent.plist")
        let dict = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any])
        let type = dict["ProcessType"] as? String
        #expect(type == "Standard" || type == "Adaptive", "ProcessType is \(type ?? "unset")")
    }

    @Test func aToolRunsAtUtilityPriorityNotBackground() throws {
        let probe = ["-c", "/bin/ps -o pri= -p $$"]
        let launched = try ProcessCommandRunner().run("/bin/sh", probe).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(ProcessCommandRunner.toolQuality == .utility)
        #expect(launched == priority(of: .utility), "a tool runs at \(launched)")
        #expect(launched != priority(of: .background), "a tool runs at background priority")
    }

    /// the priority `ps` reports for a shell launched at `quality`
    private func priority(of quality: QualityOfService) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "/bin/ps -o pri= -p $$"]
        p.qualityOfService = quality
        let out = Pipe(); p.standardOutput = out
        guard (try? p.run()) != nil else { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        try? out.fileHandleForReading.close()
        _ = p.waitForExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
