import SwiftUI
import AppKit

// The Vanta palette. Every colour is *dynamic*: it resolves against the current
// appearance at draw time, so switching Dark / Light in Settings repaints the
// whole app (including attributed text in the editor) without re-highlighting.
//
//   violet  #6d3df5 / #8f6bff     night  #14101f     amber  #ffb547
//   mint    #19b38a               rose   #e5486b
enum Theme {
    static func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                blue: CGFloat(v & 0xff) / 255, alpha: a)
    }

    /// A colour that is `dark` in dark mode and `light` in light mode.
    static func dyn(_ dark: UInt32, _ light: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { app in
            app.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? hex(dark, alpha) : hex(light, alpha)
        }
    }

    // MARK: chrome (NSColor)
    static let nChrome = dyn(0x0c0a14, 0xeeebf6)       // activity bar, title row
    static let nPanel = dyn(0x100d19, 0xf6f4fb)        // sidebars, bottom panel
    static let nPanel2 = dyn(0x1f1932, 0xe6e1f4)       // hover / selected rows
    static let nLine = dyn(0x2a2340, 0xdcd6ea)         // hairlines
    static let nInk = dyn(0xe9e5f5, 0x1d1730)
    static let nMuted = dyn(0x8a85a8, 0x6e6890)
    static let nAccent = dyn(0x8f6bff, 0x6d3df5)
    static let nAccentDim = dyn(0x6d3df5, 0x6d3df5)
    static let nMint = dyn(0x19b38a, 0x0f8f6c)
    static let nRose = dyn(0xe5486b, 0xd23a5a)
    static let nAmber = dyn(0xffb547, 0xb7740a)
    static let nBlue = dyn(0x6fa8ff, 0x2f63d0)

    // MARK: chrome (SwiftUI) — names kept from Vanta Studio 1 so old views compile
    static let bg = Color(nsColor: nPanel)
    static let chrome = Color(nsColor: nChrome)
    static let panel = Color(nsColor: dyn(0x15111f, 0xfbfaff))
    static let panel2 = Color(nsColor: nPanel2)
    static let line = Color(nsColor: nLine)
    static let ink = Color(nsColor: nInk)
    static let muted = Color(nsColor: nMuted)
    static let accent = Color(nsColor: nAccent)
    static let accentDim = Color(nsColor: nAccentDim)
    static let green = Color(nsColor: nMint)
    static let red = Color(nsColor: nRose)
    static let amber = Color(nsColor: nAmber)
    static let blue = Color(nsColor: nBlue)
    static let editorBg = Color(nsColor: nbg)
    static let nbgColor = Color(nsColor: nbg)

    // MARK: editor (NSColor)
    static let nbg = dyn(0x14101f, 0xfdfcff)
    static let nink = dyn(0xe4e0f2, 0x241d38)
    static let ngutter = dyn(0x14101f, 0xfdfcff)
    static let nlineNumber = dyn(0x4a4366, 0xa9a3c0)
    static let nlineNumberActive = dyn(0xc9c2e8, 0x3a3258)
    static let ncurrentLine = dyn(0x1d1830, 0xf3f0fc)
    static let nselection = dyn(0x3a2d6e, 0xd9cffc)
    static let nbracket = dyn(0x8f6bff, 0x6d3df5, alpha: 0.55)
    static let nfindMatch = dyn(0xffb547, 0xffb547, alpha: 0.28)
    static let nfindCurrent = dyn(0xffb547, 0xf0a020, alpha: 0.6)
    static let nwordHighlight = dyn(0x8f6bff, 0x6d3df5, alpha: 0.16)
    static let ndebugLine = dyn(0xffb547, 0xffb547, alpha: 0.18)
    static let ndiffRemoved = dyn(0xe5486b, 0xe5486b, alpha: 0.20)
    static let ndiffAdded = dyn(0x19b38a, 0x19b38a, alpha: 0.20)
    static let nghost = dyn(0x7d769c, 0x9d97b5)
    static let nindentGuide = dyn(0x241e38, 0xebe7f5)

    // syntax
    static let nkw = dyn(0xa58bff, 0x6d3df5)           // keywords
    static let ndecl = dyn(0xc3abff, 0x5a2be0)         // to / type / kind / test
    static let nopword = dyn(0xc7a6ff, 0x7a4fe8)       // is at least, plus, and…
    static let nstr = dyn(0x4fd1a5, 0x0f8f6c)
    static let nescape = dyn(0xffb547, 0xb7740a)
    static let nnum = dyn(0xffb547, 0xb8650a)
    static let ncom = dyn(0x605a7d, 0x9a94b2)
    static let ndoc = dyn(0x8279ad, 0x7a72a0)
    static let nfn = dyn(0x7aa7ff, 0x2f5fd0)           // calls
    static let nfnDef = dyn(0x9cc0ff, 0x1f4fc0)        // function being defined
    static let nbuiltin = dyn(0x6fc8ff, 0x1d7db8)
    static let ntype = dyn(0xffcf7a, 0xa3560f)
    static let nconst = dyn(0xff7a93, 0xc3304f)
    static let npseudo = dyn(0xff9fb3, 0xb02a50)
    static let nop = dyn(0x9d97b8, 0x6e6890)
    static let npunct = dyn(0x857fa3, 0x7f7a98)
    static let nheading = dyn(0xc3abff, 0x5a2be0)

    // legacy names used by Vanta Studio 1 code
    static let naccent = nAccent
    static let nline = nlineNumber
}

extension Color {
    init(hex: UInt32) { self.init(nsColor: Theme.hex(hex)) }
}
