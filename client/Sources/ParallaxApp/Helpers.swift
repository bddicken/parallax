import ParallaxCore
import SwiftUI

extension RGBAColor {
    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }
}
