// Carbon 注册全局快捷键，冲突时保留菜单栏入口，by AI.Coding。
import AppKit
import Carbon
import LocalClipCore
@MainActor public final class HotKeyService {
    private var references: [UInt32: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    private var registered: [UInt32: Shortcut] = [:]
    /// id 1：打开/关闭历史面板。
    public var onInvoke: (() -> Void)?
    /// id 2：粘贴队列下一项；只在队列进行中注册，by AI.Coding。
    public var onQueueInvoke: (() -> Void)?
    public init() {}
    /// 新快捷键注册失败不丢掉旧快捷键；不使用全局键盘监听替代。
    public func register(_ shortcut: Shortcut) -> Bool { register(shortcut, id: 1) }
    public func registerQueue(_ shortcut: Shortcut) -> Bool { register(shortcut, id: 2) }
    public func unregisterQueue() { unregister(id: 2) }
    private func register(_ shortcut: Shortcut, id: UInt32) -> Bool {
        if shortcut == registered[id] { return true }
        if handler == nil {
            var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let context, let event else { return OSStatus(eventNotHandledErr) }
                // 按注册时的id分派，面板与队列快捷键互不干扰。
                var key = EventHotKeyID()
                guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                        MemoryLayout<EventHotKeyID>.size, nil, &key) == noErr else { return OSStatus(eventNotHandledErr) }
                let owner = Unmanaged<HotKeyService>.fromOpaque(context).takeUnretainedValue()
                MainActor.assumeIsolated { key.id == 2 ? owner.onQueueInvoke?() : owner.onInvoke?() }
                return noErr
            }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard status == noErr else { return false }
        }
        var newReference: EventHotKeyRef?
        let key = EventHotKeyID(signature: 0x4C434C50, id: id)
        let result = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, key, GetApplicationEventTarget(), 0, &newReference)
        guard result == noErr, let newReference else { return false }
        if let old = references[id] { UnregisterEventHotKey(old) }
        references[id] = newReference; registered[id] = shortcut
        return true
    }
    private func unregister(id: UInt32) {
        if let reference = references.removeValue(forKey: id) { UnregisterEventHotKey(reference) }
        registered[id] = nil
    }
    /// 应用退出时释放系统注册。
    public func stop() {
        for reference in references.values { UnregisterEventHotKey(reference) }
        references = [:]; registered = [:]
        if let handler { RemoveEventHandler(handler) }; handler = nil
    }
    /// 用户可读名称，不显示 Carbon 编码。
    public static func label(_ shortcut: Shortcut) -> String {
        var keys: [UInt32: String] = [18:"1",19:"2",20:"3",21:"4",23:"5",22:"6",26:"7",28:"8",25:"9",0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",31:"O",32:"U",34:"I",35:"P",37:"L",38:"J",40:"K",45:"N",46:"M",49:"Space",29:"0",27:"-",24:"=",33:"[",30:"]",41:";",39:"'",42:"\\",43:",",47:".",44:"/",50:"`",36:"↩",48:"⇥"]
        // 可录入的非字符键也使用可读名称，不改变注册行为，by AI.Coding。
        for (code, label) in [(kVK_LeftArrow, "←"), (kVK_RightArrow, "→"), (kVK_UpArrow, "↑"), (kVK_DownArrow, "↓"), (kVK_Delete, "⌫"), (kVK_ForwardDelete, "⌦"), (kVK_Escape, "Esc"), (kVK_Home, "Home"), (kVK_End, "End"), (kVK_PageUp, "Page Up"), (kVK_PageDown, "Page Down")] { keys[UInt32(code)] = label }
        for (index, code) in [kVK_F1,kVK_F2,kVK_F3,kVK_F4,kVK_F5,kVK_F6,kVK_F7,kVK_F8,kVK_F9,kVK_F10,kVK_F11,kVK_F12,kVK_F13,kVK_F14,kVK_F15,kVK_F16,kVK_F17,kVK_F18,kVK_F19,kVK_F20].enumerated() { keys[UInt32(code)] = "F\(index + 1)" }
        return (shortcut.modifiers & UInt32(controlKey) != 0 ? "⌃" : "") + (shortcut.modifiers & UInt32(optionKey) != 0 ? "⌥" : "") +
            (shortcut.modifiers & UInt32(shiftKey) != 0 ? "⇧" : "") + (shortcut.modifiers & UInt32(cmdKey) != 0 ? "⌘" : "") + (keys[shortcut.keyCode] ?? "Key \(shortcut.keyCode)")
    }
}
