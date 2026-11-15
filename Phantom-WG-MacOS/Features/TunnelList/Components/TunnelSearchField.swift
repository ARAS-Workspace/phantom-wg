import AppKit
import SwiftUI

struct TunnelSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> UserFocusSearchField {
        let field = UserFocusSearchField()
        field.placeholderString = placeholder
        field.sendsSearchStringImmediately = true
        field.target = context.coordinator
        field.action = #selector(Coordinator.changed(_:))
        field.delegate = context.coordinator
        field.setAccessibilityIdentifier(AXID.TunnelList.search)
        context.coordinator.field = field
        context.coordinator.installClickMonitor()
        return field
    }

    func updateNSView(_ field: UserFocusSearchField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text { field.stringValue = text }
        field.placeholderString = placeholder
    }

    static func dismantleNSView(_ field: UserFocusSearchField, coordinator: Coordinator) {
        coordinator.removeClickMonitor()
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        weak var field: NSSearchField?
        private var monitor: Any?

        init(text: Binding<String>) { self.text = text }

        @objc func changed(_ sender: NSSearchField) { text.wrappedValue = sender.stringValue }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.cancelOperation(_:)),
                  let field = control as? NSSearchField else { return false }
            if field.stringValue.isEmpty {
                field.window?.makeFirstResponder(nil)
            } else {
                field.stringValue = ""
                text.wrappedValue = ""
            }
            return true
        }

        func installClickMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let field = self?.field, let window = field.window, event.window === window,
                      field.currentEditor() != nil else { return event }
                if !field.bounds.contains(field.convert(event.locationInWindow, from: nil)) {
                    window.makeFirstResponder(nil)
                }
                return event
            }
        }

        func removeClickMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

final class UserFocusSearchField: NSSearchField {
    override func becomeFirstResponder() -> Bool {
        guard NSWorkspace.shared.isVoiceOverEnabled || Self.isUserRequest(NSApp.currentEvent, in: self) else {
            return false
        }
        return super.becomeFirstResponder()
    }

    static func isUserRequest(_ event: NSEvent?, in field: NSView) -> Bool {
        guard let event else { return false }
        switch event.type {
        case .keyDown:
            return event.keyCode == 48
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            guard event.window === field.window else { return false }
            return field.bounds.contains(field.convert(event.locationInWindow, from: nil))
        default:
            return false
        }
    }
}
