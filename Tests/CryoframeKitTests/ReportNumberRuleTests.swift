//
//  ReportNumberRuleTests.swift
//  CryoframeKitTests
//
//  The problem report's rule for numbers with a unit. A number is kept if it has at
//  most six digits, or if it carries a unit and is a plausible amount of it: a size
//  up to a petabyte, a count up to a billion, a time up to about four months. A
//  long number with a unit it can't be an amount of ("4111111111111111KB",
//  "123456789s") is an identifier wearing a unit, and goes. A number and its unit
//  are kept together, however they are written ("1234567 bytes", "300 s", "12GB").
//

import Testing
import Foundation
@testable import CryoframeKit

@Suite struct ReportNumberRuleTests {
    let r = Redactor(names: [], userWords: ["jdoe"])

    @Test(arguments: [
        "copied 1234567 bytes", "copied 1234567bytes", "after 300 s", "after 300s", "12GB free", "3.5 GB free",
        "took 45 min", "1,234,567 bytes", "2,500,000 files", "1500000 ms", "8640000 s", "999999 weeks",
    ])
    func aPlausibleAmountKeepsItsNumberAndUnit(_ line: String) {
        #expect(r.redact(line) == line, "\(line) → \(r.redact(line))")
    }

    @Test(arguments: [
        ("123456789GB", "is missing"), ("4111111111111111KB", "is missing"), ("123456789s", "is missing"),
        ("4111111111111111 bytes", "is missing"), ("123456789012 files", "is missing"), ("40455512345 min", "is missing"),
    ])
    func aLongNumberWithAUnitItCantBeAnAmountOfGoes(_ number: String, _ rest: String) {
        let out = r.redact("\(number) \(rest)")
        #expect(out == "[…] \(rest)", "\(number) → \(out)")
    }

    // A number inside a file name is judged with the name, as before: kept only if
    // the whole name is words Cryoframe or macOS use.
    @Test(arguments: ["report-2026.pdf", "Invoice 2026-4111.pdf", "scan_4111.jpg", "v2"])
    func aNumberInAFileNameGoesWithTheName(_ name: String) {
        let out = r.redact("\(name) is missing")
        #expect(!out.contains("2026") && !out.contains("4111") && !out.contains("v2"), "\(name) → \(out)")
    }

    // Numbers apart by what ends a clause (";", a comma and a space) are two numbers.
    @Test func numbersInAListStayApart() {
        #expect(r.redact("exit status 23, 72,000 files; error -36") == "exit status 23, 72,000 files; error -36")
        #expect(r.redact("Sep 28, 2026 at 2:00 AM") == "Sep 28, 2026 at 2:00 AM")
        #expect(r.redact("at 14:13:20") == "at 14:13:20")
    }
}
