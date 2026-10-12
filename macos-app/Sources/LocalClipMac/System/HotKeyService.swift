// Carbon 注册全局快捷键，冲突时保留菜单栏入口，by AI.Coding。
import AppKit
import Carbon
import LocalClipCore
@MainActor public final class HotKeyService {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var registered: Shortcut?
    public var onInvoke: (() -> Void)?
    public init() {}
    /// 新快捷键注册失败不丢掉旧快捷键；不使用全局键盘监听替代。
    public func register(_ shortcut: Shortcut) -> Bool {
        if shortcut == registered { return true }
        if handler == nil {
            var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
                guard let context else { return OSStatus(eventNotHandledErr) }
                let owner = Unmanaged<HotKeyService>.fromOpaque(context).takeUnretainedValue()
                MainActor.assumeIsolated { owner.onInvoke?() }
                return noErr
            }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard status == noErr else { return false }
        }
        var newReference: EventHotKeyRef?
        let id = EventHotKeyID(signature: 0x4C434C50, id: 1)
        let result = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &newReference)
        guard result == noErr, let newReference else { return false }
        if let reference { UnregisterEventHotKey(reference) }
        reference = newReference; registered = shortcut
        return true
    }
    /// 应用退出时释放系统注册。
    public func stop() {
        if let reference { UnregisterEventHotKey(reference) }; reference = nil
        if let handler { RemoveEventHandler(handler) }; handler = nil
        registered = nil
    }
    /// 用户可读名称，不显示 Carbon 编码。
    public static func label(_ shortcut: Shortcut) -> String {
        let keys: [UInt32: String] = [18:"1",19:"2",20:"3",21:"4",23:"5",22:"6",26:"7",28:"8",25:"9",0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",31:"O",32:"U",34:"I",35:"P",37:"L",38:"J",40:"K",45:"N",46:"M",49:"Space"]
        return (shortcut.modifiers & UInt32(controlKey) != 0 ? "⌃" : "") + (shortcut.modifiers & UInt32(optionKey) != 0 ? "⌥" : "") +
            (shortcut.modifiers & UInt32(shiftKey) != 0 ? "⇧" : "") + (shortcut.modifiers & UInt32(cmdKey) != 0 ? "⌘" : "") + (keys[shortcut.keyCode] ?? "Key \(shortcut.keyCode)")
    }
}
