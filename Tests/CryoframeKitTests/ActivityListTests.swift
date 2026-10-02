//
//  ActivityListTests.swift
//  CryoframeKitTests
//
//  Clearing the Activity list hides runs that finished before the "cleared at" time.
//  It never removes a record from the history.
//

import Testing
import Foundation
@testable import CryoframeKit

private func run(_ id: String, finished: TimeInterval) -> RunRecord {
    RunRecord(id: id, jobID: "j", jobName: "Job", startedAt: Date(timeIntervalSince1970: finished - 60),
              finishedAt: Date(timeIntervalSince1970: finished), trigger: "manual", outcome: .completed,
              summary: "done", libraries: [], bytes: 0, warning: nil)
}

@Suite struct ActivityListTests {
    private let history = [run("c", finished: 300), run("b", finished: 200), run("a", finished: 100)]   // newest first

    @Test func neverClearedShowsTheNewestUpToTheLimit() {
        #expect(ActivityList.seed(history, clearedAt: nil, limit: 8).map(\.id) == ["c", "b", "a"])
        #expect(ActivityList.seed(history, clearedAt: nil, limit: 2).map(\.id) == ["c", "b"])
    }

    @Test func runsFinishedBeforeTheClearTimeStayOut() {
        #expect(ActivityList.seed(history, clearedAt: Date(timeIntervalSince1970: 200), limit: 8).map(\.id) == ["c"])
        #expect(ActivityList.seed(history, clearedAt: Date(timeIntervalSince1970: 250), limit: 8).map(\.id) == ["c"])
        #expect(ActivityList.seed(history, clearedAt: Date(timeIntervalSince1970: 50), limit: 8).map(\.id) == ["c", "b", "a"])
    }

    @Test func clearingAfterTheNewestRunEmptiesTheListNotTheHistory() {
        #expect(ActivityList.seed(history, clearedAt: Date(timeIntervalSince1970: 400), limit: 8).isEmpty)
        #expect(history.count == 3)
    }

    @Test func aZeroOrNegativeLimitShowsNothing() {
        #expect(ActivityList.seed(history, clearedAt: nil, limit: 0).isEmpty)
        #expect(ActivityList.seed(history, clearedAt: nil, limit: -1).isEmpty)
    }
}
