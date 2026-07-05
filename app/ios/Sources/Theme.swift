import SwiftUI
import UIKit

// Vanta Pocket's look: "vantablack dusk" — near-black violet panels with a
// soft purple accent, the same family as Vanta Studio and vcode's default theme.
enum Theme {
    static let bg = Color(red: 0.043, green: 0.043, blue: 0.072)
    static let panel = Color(red: 0.078, green: 0.075, blue: 0.121)
    static let panel2 = Color(red: 0.10, green: 0.094, blue: 0.16)
    static let line = Color(red: 0.149, green: 0.133, blue: 0.219)
    static let ink = Color(red: 0.906, green: 0.890, blue: 0.961)
    static let muted = Color(red: 0.541, green: 0.522, blue: 0.659)
    static let accent = Color(red: 0.702, green: 0.533, blue: 1.0)
    static let accentDim = Color(red: 0.424, green: 0.310, blue: 0.839)
    static let green = Color(red: 0.373, green: 0.827, blue: 0.541)
    static let red = Color(red: 1.0, green: 0.329, blue: 0.439)
    static let gold = Color(red: 0.96, green: 0.77, blue: 0.38)

    // UIColors for the editor and console text views.
    static let ubg = UIColor(red: 0.066, green: 0.063, blue: 0.102, alpha: 1)
    static let uink = UIColor(red: 0.906, green: 0.890, blue: 0.961, alpha: 1)
    static let ukw = UIColor(red: 0.78, green: 0.57, blue: 0.92, alpha: 1)
    static let ustr = UIColor(red: 0.76, green: 0.91, blue: 0.55, alpha: 1)
    static let unum = UIColor(red: 0.97, green: 0.55, blue: 0.42, alpha: 1)
    static let ucom = UIColor(red: 0.36, green: 0.33, blue: 0.47, alpha: 1)
    static let ufn = UIColor(red: 0.51, green: 0.67, blue: 1.0, alpha: 1)
    static let uop = UIColor(red: 0.54, green: 0.87, blue: 1.0, alpha: 1)
    static let uaccent = UIColor(red: 0.702, green: 0.533, blue: 1.0, alpha: 1)

    static func codeFont(_ size: CGFloat = 15) -> UIFont {
        UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

// Small, tasteful haptics so the app feels responsive.
enum Haptics {
    static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}
