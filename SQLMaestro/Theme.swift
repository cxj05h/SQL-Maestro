import SwiftUI

enum Theme {
    // palette from user
    static let purple  = Color(hex: "#6366F1")
    static let pink    = Color(hex: "#EF44C0")
    static let aqua    = Color(hex: "#7DD3C0")
    static let aquaLt  = Color(hex: "#5EEAD4")
    static let gold    = Color(hex: "#FBBF24")
    static let goldLt  = Color(hex: "#FDE68A")
    static let accent  = Color(hex: "#34D399")
    static let grayBG  = Color(nsColor: .windowBackgroundColor) // dark-friendly
    static let titleBarBG = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.name == .darkAqua || appearance.name == .vibrantDark
            ? NSColor(white: 0.18, alpha: 1.0)  // light gray in dark mode
            : NSColor(red: 42/255, green: 42/255, blue: 53/255, alpha: 1.0)  // #2A2A35 in light mode
    })
    static let titleBarLabel = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.name == .darkAqua || appearance.name == .vibrantDark
            ? NSColor.secondaryLabelColor  // standard secondary in dark mode
            : NSColor.white  // white in light mode
    })
    static let paneLabelColor = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.name == .darkAqua || appearance.name == .vibrantDark
            ? NSColor(red: 125/255, green: 211/255, blue: 192/255, alpha: 1.0)  // aqua (#7DD3C0) in dark mode
            : NSColor.systemBlue  // blue in light mode
    })
    static let clearSessionTint = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.name == .darkAqua || appearance.name == .vibrantDark
            ? NSColor(red: 125/255, green: 211/255, blue: 192/255, alpha: 1.0)  // aqua (#7DD3C0) in dark mode
            : NSColor(red: 52/255, green: 211/255, blue: 153/255, alpha: 1.0)  // green (#34D399) in light mode
    })
    static let clearSessionText = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.name == .darkAqua || appearance.name == .vibrantDark
            ? NSColor(red: 125/255, green: 211/255, blue: 192/255, alpha: 1.0)  // aqua (#7DD3C0) in dark mode
            : NSColor.systemBlue  // blue in light mode
    })
}

extension Color {
    init(hex: String) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        var val: UInt64 = 0
        Scanner(string: s).scanHexInt64(&val)
        let r = Double((val >> 16) & 0xff) / 255.0
        let g = Double((val >> 8) & 0xff) / 255.0
        let b = Double(val & 0xff) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}