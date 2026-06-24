//
//  main.swift
//  CryoframeHelper (root LaunchDaemon)
//
//  Vends the XPC service on the privileged mach service. launchd starts us on
//  demand when the app connects (MachServices in the daemon plist).
//

import Foundation
import CryoframeShared

final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // only our signed app may talk to root; the requirement is enforced at
        // call time. (setCodeSigningRequirement is non-throwing on this SDK.)
        newConnection.setCodeSigningRequirement(CryoframeHelper.clientRequirement)
        newConnection.exportedInterface = NSXPCInterface(with: CryoframeHelperXPC.self)
        newConnection.exportedObject = HelperService()
        newConnection.resume()
        return true
    }
}

let delegate = HelperListenerDelegate()
let listener = NSXPCListener(machServiceName: CryoframeHelper.machServiceName)
listener.delegate = delegate
listener.resume()
dispatchMain()
