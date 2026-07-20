//
//  Theme.swift
//  Cryoframe (app)
//
//  The design system: an intentional, adaptive palette instead of raw system colors,
//  so Cryoframe reads as one product in both light and dark. The identity is a cool
//  near-black with an electric-cyan accent (the app icon's glow); light mode keeps the
//  same accent, tuned for contrast on white. Semantic good/warn/crit are separate from
//  the accent so status never collides with brand.
//

import SwiftUI
import AppKit

extension Color {
    /// a color that resolves per the view's appearance (light vs dark).
    init(lightHex: UInt, darkHex: UInt) {
        self = Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(cryoHex: isDark ? darkHex : lightHex)
        })
    }

    // brand + semantic tokens
    static let cryoAccent = Color(lightHex: 0x0A91D6, darkHex: 0x37C8FF)   // electric cyan
    static let cryoGood   = Color(lightHex: 0x12A670, darkHex: 0x34D399)
    static let cryoWarn   = Color(lightHex: 0xC9820A, darkHex: 0xFBBF24)
    static let cryoCrit   = Color(lightHex: 0xE0454E, darkHex: 0xFB7185)

    // surfaces / lines — subtle, appearance-aware
    static let cryoElevated = Color(lightHex: 0xF5F8FC, darkHex: 0x1B1F29)
    static let cryoLine     = Color.primary.opacity(0.10)
}

/// makes the brand tokens usable as `.cryoGood` in ShapeStyle contexts (foregroundStyle,
/// fill, tint), not only as `Color.cryoGood`.
extension ShapeStyle where Self == Color {
    static var cryoAccent: Color { Color.cryoAccent }
    static var cryoGood: Color { Color.cryoGood }
    static var cryoWarn: Color { Color.cryoWarn }
    static var cryoCrit: Color { Color.cryoCrit }
    static var cryoElevated: Color { Color.cryoElevated }
    static var cryoLine: Color { Color.cryoLine }
}

extension NSColor {
    convenience init(cryoHex hex: UInt) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                  green:    CGFloat((hex >> 8) & 0xff) / 255,
                  blue:     CGFloat(hex & 0xff) / 255, alpha: 1)
    }
}

// MARK: - reusable surface

private struct CryoCard: ViewModifier {
    var padding: CGFloat = 16
    var glow: Bool = false
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.cryoElevated))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.cryoLine, lineWidth: 1))
            .shadow(color: glow ? Color.cryoAccent.opacity(0.28) : .clear, radius: glow ? 14 : 0, y: 0)
    }
}

extension View {
    /// a standard elevated card surface with a hairline border.
    func cryoCard(padding: CGFloat = 16, glow: Bool = false) -> some View {
        modifier(CryoCard(padding: padding, glow: glow))
    }

    /// a subtle cyan glow for the brand mark / primary status, only where it earns it.
    func cryoGlow(_ color: Color = .cryoAccent, radius: CGFloat = 10) -> some View {
        shadow(color: color.opacity(0.55), radius: radius)
    }
}

// MARK: - Shared sheet chrome
//
// Every sheet (Restore, Storage, History, Browse) grew its own header and empty
// state, so they drifted apart. These two are the house style — use them instead
// of hand-rolling an HStack with a title and a Done button.

/// Title bar for a sheet: symbol, title, optional subtitle, and the Done button.
struct CryoSheetHeader: View {
    let title: String
    var symbol: String
    var subtitle: String?
    var doneTitle: String = "Done"
    var doneIsDefault: Bool = true
    var onDone: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.cryoAccent)
                .accessibilityHidden(true)          // the title already says it
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title3.bold()).accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(doneTitle, action: onDone)
                .keyboardShortcut(doneIsDefault ? .defaultAction : .cancelAction)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }
}

/// Centered "nothing here yet" state — a glyph, a line, and an optional action.
struct CryoEmptyState: View {
    let symbol: String
    let title: String
    var message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(title).font(.headline)
            Text(message)
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 340)
            if let actionTitle, let action {
                Button(actionTitle, action: action).controlSize(.regular).padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(message)")
    }
}
