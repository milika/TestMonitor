import SwiftUI
import AppKit

// NSViewRepresentable-based tooltip that works in MenuBarExtra windows.
// SwiftUI's .help() is unreliable there because it sets toolTip on the wrong
// backing view before the view hierarchy is fully attached to a window.

private struct TooltipNSView: NSViewRepresentable {
  let text: String

  func makeNSView(context: Context) -> NSView {
    let v = NSView()
    v.toolTip = text
    return v
  }

  func updateNSView(_ v: NSView, context: Context) {
    v.toolTip = text
  }
}

extension View {
  func tooltip(_ text: String) -> some View {
    overlay(
      TooltipNSView(text: text)
        .allowsHitTesting(false)
    )
  }
}
