//
//  RemoteAlert.swift
//  Cryoframe (app)
//
//  Off-machine alerts for run and health-check results, so an unattended Mac whose
//  backups are failing can actually tell you — a Notification Center banner nobody
//  sees is no use when you're away. Posts to an ntfy topic or a generic webhook
//  (Slack/Discord-shaped JSON). Fires from the same resident-GUI path as local
//  notifications, deduped by the same per-record guard.
//

import Foundation
import CryoframeKit

enum RemoteAlert {
    enum Kind: String { case off, webhook, ntfy }

    static var kind: Kind { Kind(rawValue: UserDefaults.standard.string(forKey: Prefs.remoteAlertType) ?? "off") ?? .off }
    static var endpoint: String { (UserDefaults.standard.string(forKey: Prefs.remoteAlertURL) ?? "").trimmingCharacters(in: .whitespaces) }
    static var allEvents: Bool { UserDefaults.standard.string(forKey: Prefs.remoteAlertEvents) == "all" }

    /// configured = a kind is chosen and the URL is a plausible http(s) endpoint.
    static var isConfigured: Bool {
        guard kind != .off, let scheme = URL(string: endpoint)?.scheme else { return false }
        return scheme == "http" || scheme == "https"
    }

    // MARK: events

    static func send(for record: RunRecord) {
        guard isConfigured, let p = AlertPolicy.payload(for: record, everyEvent: allEvents) else { return }
        post(title: p.title, body: p.body, high: p.high, tags: p.tags)
    }

    static func sendHealth(for record: HealthRecord) {
        guard isConfigured, let p = AlertPolicy.payload(forHealth: record, everyEvent: allEvents) else { return }
        post(title: p.title, body: p.body, high: p.high, tags: p.tags)
    }

    // MARK: delivery that outlives the caller
    //
    // `post` fires and forgets, which is fine in the app because the app is still
    // there when the request completes. The agent exits the moment its work is done,
    // so a fire-and-forget alert would be killed on the way out — the exact case
    // these alerts exist for. These wait for the send.

    /// deliver an alert for a run, awaiting the request. No-op when nothing to say.
    static func deliver(for record: RunRecord) async {
        guard isConfigured, let p = AlertPolicy.payload(for: record, everyEvent: allEvents) else { return }
        await deliver(p)
    }

    /// deliver an alert for a health check, awaiting the request.
    static func deliverHealth(for record: HealthRecord) async {
        guard isConfigured, let p = AlertPolicy.payload(forHealth: record, everyEvent: allEvents) else { return }
        await deliver(p)
    }

    private static func deliver(_ p: AlertPolicy.Payload) async {
        guard let req = request(title: p.title, body: p.body, high: p.high, tags: p.tags) else { return }
        _ = try? await URLSession.shared.data(for: req)
    }

    /// for the Settings test button — awaits the result so the UI can report success/failure.
    static func sendTest() async -> String {
        guard kind != .off else { return "Choose a webhook or ntfy first." }
        guard isConfigured else { return "That doesn't look like a valid http(s) URL." }
        guard let req = request(title: "Cryoframe — test", body: "✓ Remote alerts are working.", high: false, tags: "white_check_mark") else {
            return "Couldn't build the request."
        }
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
                return "The server returned HTTP \(h.statusCode)."
            }
            return "Test alert sent — check your phone or channel."
        } catch {
            return "Couldn't reach it: \(error.localizedDescription)"
        }
    }

    // MARK: transport

    /// HTTP header values can't contain CR/LF; collapse them to spaces.
    private static func headerSafe(_ s: String) -> String {
        s.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
    }

    private static func post(title: String, body: String, high: Bool, tags: String) {
        guard let req = request(title: title, body: body, high: high, tags: tags) else { return }
        URLSession.shared.dataTask(with: req).resume()       // fire and forget
    }

    private static func request(title: String, body: String, high: Bool, tags: String) -> URLRequest? {
        guard let url = URL(string: endpoint) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        switch kind {
        case .ntfy:
            // the title carries the user-set job name; strip CR/LF so it can't inject an
            // ntfy header (or get the whole request rejected, silently dropping the alert).
            req.setValue(headerSafe(title), forHTTPHeaderField: "Title")
            req.setValue(high ? "high" : "default", forHTTPHeaderField: "Priority")
            req.setValue(tags, forHTTPHeaderField: "Tags")
            req.httpBody = Data(body.utf8)
        case .webhook:
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let msg = "\(title)\n\(body)"
            // `text` (Slack) and `content` (Discord) cover the common chat webhooks;
            // the structured fields suit a custom endpoint.
            let payload: [String: String] = ["text": msg, "content": msg, "title": title, "body": body]
            req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        case .off:
            return nil
        }
        return req
    }
}
