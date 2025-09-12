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