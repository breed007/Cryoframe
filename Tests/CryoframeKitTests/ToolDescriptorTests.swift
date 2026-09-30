//
//  ToolDescriptorTests.swift
//  CryoframeKitTests
//
//  Launching a tool leaves no file open behind it. Each launch used to leave its
//  output pipes open; the helper runs a tool for every step of every backup, and
//  once it ran out of descriptors it could launch nothing and every run failed.
//

import Testing
import Foundation
@testable import CryoframeKit

/// how many descriptors this process has open now
private func openDescriptors() -> Int {
    var limit = rlimit()
    getrlimit(RLIMIT_NOFILE, &limit)
    let top = Int32(min(limit.rlim_cur, 65_536))
    return (0..<top).filter { fcntl($0, F_GETFD) != -1 }.count
}

@Suite(.serialized) struct ToolDescriptorTests {
    // A leak is two descriptors a tool, so 100 tools leave 200 open. Other tests run
    // alongside and open files of their own, so the bound leaves room for them.
    @Test func runningToolsLeavesNoDescriptorsOpen() throws {
        let before = openDescriptors()
        for _ in 0..<100 { _ = try ProcessCommandRunner().run("/usr/bin/true", []) }
        for _ in 0..<50 { _ = try ProcessCommandRunner().run("/bin/cat", [], stdin: Data("x".utf8)) }
        #expect(openDescriptors() - before < 100)
    }

    @Test func readingAToolsProcessTreeLeavesNoDescriptorsOpen() {
        let before = openDescriptors()
        for _ in 0..<100 { _ = RunControl.subtreeProcs(of: getpid()) }
        #expect(openDescriptors() - before < 50)
    }
}
