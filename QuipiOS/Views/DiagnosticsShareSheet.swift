import SwiftUI
import AVFoundation

/// Wraps `UIActivityViewController` for the Connection diagnostics sheet's
/// "Share Quip-diagnostics-*.zip" button. Items is typically a single
/// file URL pointing to the saved zip in Documents.
struct DiagnosticsShareSheet: UIViewControllerRepresentable {
    var items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// Identifiable wrapper so a staged `.quippack` URL can drive `.sheet(item:)`. (§6.1)
struct PackShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

// §6.1 — ImportablePack + ImportPackSheet moved to QuipiOS/Views/ImportPackSheet.swift
// to shrink this file. Keep the import state + apply methods in QuipApp itself
// (they're tightly coupled to @State + @AppStorage + client).
