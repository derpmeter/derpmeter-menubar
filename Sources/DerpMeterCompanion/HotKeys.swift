import Carbon.HIToolbox
import Foundation

/// Global shortcuts via Carbon RegisterEventHotKey: registered key combos only,
/// so no Accessibility or Input Monitoring permission is required.
/// ⌥⌘1 Smart · ⌥⌘2 Meh · ⌥⌘3 Dumb
final class HotKeys {
    private var refs: [EventHotKeyRef?] = []
    private var handler: EventHandlerRef?
    private let action: (Int) -> Void

    init(action: @escaping (Int) -> Void) {
        self.action = action
    }

    func register() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            if let context {
                let me = Unmanaged<HotKeys>.fromOpaque(context).takeUnretainedValue()
                DispatchQueue.main.async { me.action(Int(id.id)) }
            }
            return noErr
        }, 1, &spec, context, &handler)
        let keys = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3]
        for (i, key) in keys.enumerated() {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x4452_5059), id: UInt32(i)) // "DRPY"
            RegisterEventHotKey(UInt32(key), UInt32(optionKey | cmdKey), id, GetApplicationEventTarget(), 0, &ref)
            refs.append(ref)
        }
    }

    func unregister() {
        refs.compactMap { $0 }.forEach { UnregisterEventHotKey($0) }
        refs = []
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    deinit { unregister() }
}
