// iOS-side extensions for shared types
// WindowState, WindowFrame, and message types are defined in Shared/MessageProtocol.swift
// WindowAction is defined in Views/WindowRectangle.swift

import SwiftUI

extension WindowState {
    var parsedColor: Color {
        Color(hex: color)
    }
}
