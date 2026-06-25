//
//  EscrowCryptoTests.swift
//  CryoframeKitTests
//

import Testing
import Foundation
@testable import CryoframeKit

@Test func escrowRoundTrips() {
    let secret = Data("photos=hunter2; music=correcthorse".utf8)
    let blob = EscrowCrypto.encrypt(secret, password: "master-pw")
    let blob2 = try! #require(blob)
    #expect(blob2.prefix(9) == Data("CRYOKEYS1".utf8))     // magic header
    #expect(EscrowCrypto.decrypt(blob2, password: "master-pw") == secret)
}

@Test func escrowWrongPasswordFails() {
    let blob = EscrowCrypto.encrypt(Data("x".utf8), password: "right")!
    #expect(EscrowCrypto.decrypt(blob, password: "wrong") == nil)
    #expect(EscrowCrypto.decrypt(Data("garbage".utf8), password: "right") == nil)
}

@Test func escrowSaltMakesCiphertextUnique() {
    let a = EscrowCrypto.encrypt(Data("same".utf8), password: "pw")!
    let b = EscrowCrypto.encrypt(Data("same".utf8), password: "pw")!
    #expect(a != b)        // random salt + nonce
}
