import AppKit

@MainActor
final class SpaceBarShortcut {
    nonisolated static let spaceKeyCode: UInt16 = 49

    private var monitor: Any?

    nonisolated static func shouldHandle(
        keyCode: UInt16,
        hasModifiers: Bool,
        isRepeat: Bool,
        isEditingText: Bool,
        hasModalWindow: Bool
    ) -> Bool {
        keyCode == spaceKeyCode && !hasModifiers && !isRepeat && !isEditingText && !hasModalWindow
    }

    func install(_ action: @escaping @MainActor () -> Void) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let handle = MainActor.assumeIsolated {
                Self.shouldHandle(
                    keyCode: event.keyCode,
                    hasModifiers: !event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
                    isRepeat: event.isARepeat,
                    isEditingText: NSApp.keyWindow?.firstResponder is NSText,
                    hasModalWindow: NSApp.modalWindow != nil
                )
            }
            guard handle else { return event }
            MainActor.assumeIsolated { action() }
            return nil
        }
    }
}
