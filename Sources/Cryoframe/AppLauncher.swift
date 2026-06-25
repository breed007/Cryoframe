//
//  AppLauncher.swift
//  Cryoframe (app)
//
//  One binary, two modes. The SMAppService LaunchAgent launches us with
//  CRYOFRAME_AGENT=1 to run due jobs headlessly; otherwise we're the GUI.
//  Using the same binary means the scheduled run reuses the app's FDA grant.
//

import Foundation

@main
enum AppLauncher {
    static func main() {
        let env = ProcessInfo.processInfo.environment
        if let mode = env["CRYOFRAME_KCPROBE"] {
            KeychainProbe.run(mode)  // keychain cross-process diagnostic — never returns
        } else if env["CRYOFRAME_AGENT"] == "1" {
            AgentMain.run()          // runs due jobs, then exits — never returns
        } else {
            CryoframeApp.main()
        }
    }
}
