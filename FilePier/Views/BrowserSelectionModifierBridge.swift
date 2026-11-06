import AppKit
import SwiftUI

/// Keep List as the sole selection owner. Treat Control-click as additive
/// selection inside a browser, while retaining Command/Shift and right-click.
struct BrowserSelectionModifierBridge: NSViewRepresentable {
    func makeNSView(context: Context) -> ControlClickView { ControlClickView() }
    func updateNSView(_ nsView: ControlClickView, context: Context) {}

    final class ControlClickView: NSView {
        private var eventMonitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeEventMonitor()
            guard window != nil else { return }

            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged]) { [weak self] event in
                guard let self, event.window === self.window,
                      self.bounds.contains(self.convert(event.locationInWindow, from: nil)),
                      event.modifierFlags.contains(.control) else { return event }

                var modifiers = event.modifierFlags
                modifiers.remove(.control)
                modifiers.insert(.command)
                return NSEvent.mouseEvent(with: event.type, location: event.locationInWindow,
                    modifierFlags: modifiers, timestamp: event.timestamp, windowNumber: event.windowNumber,
                    context: nil, eventNumber: event.eventNumber, clickCount: event.clickCount,
                    pressure: event.pressure) ?? event
            }
        }

        private func removeEventMonitor() {
            if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
            eventMonitor = nil
        }

        deinit {
            if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        }
    }
}
