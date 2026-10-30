import AppKit
import CoreGraphics

/// 全局快捷键。
/// 按住说（默认）：按下开始、松开结束；按住时按空格进入锁定（空格被吞掉），锁定后再按一次快捷键结束；
///   按住时按了别的键，视为组合键（例如 Option+字母打特殊字符），取消本次录音并放行按键。
/// 按一下开始：轻按一下（且中间没按别的键）开始，再按一下结束；空格正常输入。
/// 两种方式下 Esc 都能取消（录音中和处理中）。
final class HotkeyMonitor: @unchecked Sendable {
    enum Key: String { case rightOption, fn }
    enum State { case idle, holding, locked, lockedAwaitRelease, tapArmed, toggleOn, toggleOnArmed }

    /// 本程序自己发出的按键（例如粘贴用的 Cmd+V）带这个标记，监听时跳过
    static let selfEventMarker: Int64 = 0x5341_5954 // "SAYT"

    var keyProvider: () -> Key = { .rightOption }
    var modeProvider: () -> RecordMode = { .hold }
    /// 松手后仍在处理时返回 true，此时 Esc 也会取消
    var busyProvider: () -> Bool = { false }

    private(set) var state: State = .idle
    private var downAt: Double = 0
    /// 用户最近一次按键或点鼠标的时间（不含本程序自己发出的按键）
    private(set) var lastUserInputMs: Double = 0
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?
    var onLock: (() -> Void)?
    var onCancel: ((String) -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    var isRunning: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    var isRecording: Bool {
        switch state {
        case .holding, .locked, .lockedAwaitRelease, .toggleOn, .toggleOnArmed: return true
        default: return false
        }
    }

    /// 需要辅助功能授权，否则创建失败返回 false
    func start() -> Bool {
        if let t = tap {
            if !CGEvent.tapIsEnabled(tap: t) { CGEvent.tapEnable(tap: t, enable: true) }
            return true
        }
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.rightMouseDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                        place: .headInsertEventTap,
                                        options: .defaultTap,
                                        eventsOfInterest: mask,
                                        callback: hotkeyTapCallback,
                                        userInfo: refcon) else {
            return false
        }
        tap = t
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }

    fileprivate func reenable() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
        Log.shared.ev("hotkey_tap_reenabled")
    }

    /// 返回 nil 表示吞掉这个事件
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if event.getIntegerValueField(.eventSourceUserData) == HotkeyMonitor.selfEventMarker {
            return Unmanaged.passUnretained(event)
        }
        if type == .leftMouseDown || type == .rightMouseDown {
            lastUserInputMs = nowMs()
            return Unmanaged.passUnretained(event)
        }
        if type == .keyDown { lastUserInputMs = nowMs() }
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        switch type {
        case .flagsChanged:
            guard let down = isHotkeyFlag(key: keyProvider(), keycode: keycode, flags: event.flags) else { break }
            if down { hotkeyDown() } else { hotkeyUp() }
            // 快捷键本身的按下/松开不再传给当前应用（例如微信按住 Option 会录语音消息）。
            // 其他按键照常放行；组合键的按键事件自带修饰键状态，Option+字母仍能打出特殊字符。
            return nil
        case .keyDown:
            if keycode == 53 { // Esc
                if isRecording {
                    state = .idle
                    onCancel?("esc")
                    return nil
                }
                if state == .idle && busyProvider() {
                    onCancel?("esc-processing")
                    return nil
                }
            }
            switch state {
            case .holding:
                if keycode == 49 { // Space：进入锁定，吞掉空格
                    state = .lockedAwaitRelease
                    onLock?()
                    return nil
                }
                // 组合键（例如 Option+字母打特殊字符）都发生在刚按下的瞬间；
                // 按住超过 1 秒后再收到别的按键（常见于应用或输入法发出的合成按键），放行并继续录音
                let source = event.getIntegerValueField(.eventSourceStateID)
                if nowMs() - downAt < 1000 && event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                    Log.shared.ev("hotkey_combo", ["keycode": keycode, "source": source, "heldMs": Int(nowMs() - downAt)])
                    state = .idle
                    onCancel?("combo")
                } else {
                    Log.shared.ev("hotkey_key_during_hold", ["keycode": keycode, "source": source, "heldMs": Int(nowMs() - downAt)])
                }
            case .tapArmed:
                state = .idle // 组合键，不算轻按
            case .toggleOnArmed:
                state = .toggleOn
            default:
                break
            }
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    /// 这个 flagsChanged 是否属于快捷键；是的话返回按下(true)/松开(false)
    private func isHotkeyFlag(key: Key, keycode: Int64, flags: CGEventFlags) -> Bool? {
        switch key {
        case .rightOption:
            guard keycode == 61 else { return nil }
            return (flags.rawValue & 0x40) != 0 // NX_DEVICERALTKEYMASK
        case .fn:
            guard keycode == 63 else { return nil }
            return flags.contains(.maskSecondaryFn)
        }
    }

    private func hotkeyDown() {
        switch state {
        case .idle:
            downAt = nowMs()
            if modeProvider() == .hold {
                state = .holding
                onStart?()
            } else {
                state = .tapArmed
            }
        case .locked:
            state = .idle
            onStop?()
        case .toggleOn:
            state = .toggleOnArmed
        default:
            break
        }
    }

    private func hotkeyUp() {
        switch state {
        case .holding:
            state = .idle
            onStop?()
        case .lockedAwaitRelease:
            state = .locked
        case .tapArmed:
            if nowMs() - downAt < 600 {
                state = .toggleOn
                onStart?()
            } else {
                state = .idle
            }
        case .toggleOnArmed:
            state = .idle
            onStop?()
        default:
            break
        }
    }

    /// 外部（自动结束、出错）强制回到空闲
    func reset() { state = .idle }
}

private func hotkeyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        monitor.reenable()
        return Unmanaged.passUnretained(event)
    }
    return monitor.handle(type: type, event: event)
}

enum GlobeKey {
    /// 最近一次读到的值（按键回调里只用缓存，不做系统偏好同步）
    nonisolated(unsafe) static var lastUsage: Int? = nil

    /// 系统“按下地球仪键时”的设置；读不到返回 nil，并按已占用处理。
    static func usageType() -> Int? {
        CFPreferencesAppSynchronize("com.apple.HIToolbox" as CFString)
        let v = CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, "com.apple.HIToolbox" as CFString)
        let n = (v as? NSNumber)?.intValue
        lastUsage = n
        return n
    }

    static var cachedRecommendedKey: HotkeyMonitor.Key { lastUsage == 0 ? .fn : .rightOption }

    /// 只有明确是“不执行任何操作”(0) 才推荐 Fn，否则推荐右 Option。
    static func recommendedKey() -> HotkeyMonitor.Key {
        usageType() == 0 ? .fn : .rightOption
    }

    static func describe(_ v: Int?) -> String {
        switch v {
        case 0: return "不执行任何操作"
        case 1: return "更改输入法"
        case 2: return "显示表情与符号"
        case 3: return "开始听写"
        default: return "系统默认（可能会切换输入法或显示表情）"
        }
    }
}
