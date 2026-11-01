import AppKit
import ApplicationServices
import Carbon

/// 把文字插入当前输入焦点。
/// 顺序：辅助功能直接写入（能确认写进去才算成功）→ 剪贴板 + 模拟 Cmd+V（用完恢复剪贴板）→ 只放进剪贴板并提示。
final class Inserter {
    struct Target {
        let pid: pid_t
        let bundleID: String
        let appName: String
        let element: AXUIElement?
        let role: String
    }

    struct Outcome {
        let method: String   // ax / paste / clipboard / skipped
        let ok: Bool
        let detail: String
        let ms: Double
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    @discardableResult
    static func promptForTrust() -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    /// 其他应用（例如密码框、终端的“安全键盘输入”）打开了安全输入
    static var secureInputOn: Bool { IsSecureEventInputEnabled() }

    private let systemWide = AXUIElementCreateSystemWide()

    // MARK: 目标

    func captureTarget() -> Target {
        let app = NSWorkspace.shared.frontmostApplication
        let pid = app?.processIdentifier ?? 0
        if pid != 0 && pid != ProcessInfo.processInfo.processIdentifier {
            // Electron / Chromium 应用默认不暴露辅助功能树，打开后才能拿到焦点元素
            let appEl = AXUIElementCreateApplication(pid)
            AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        let el = focusedElement()
        return Target(pid: pid,
                      bundleID: app?.bundleIdentifier ?? "?",
                      appName: app?.localizedName ?? "?",
                      element: el,
                      role: el.flatMap { stringAttr($0, kAXRoleAttribute) } ?? "none")
    }

    func focusedElement() -> AXUIElement? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &v) == .success,
              let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    /// 焦点是否还在开始说话时的那个输入框（逐段填入每段前都检查）
    func focusStillOn(_ t: Target) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == t.pid else { return false }
        guard let original = t.element else { return true } // 拿不到元素时只比较应用
        guard let now = focusedElement() else { return true }
        if CFEqual(original, now) { return true }
        // 原元素已经失效（网页和 Electron 应用会重建元素）：同一应用内视为没变
        var role: CFTypeRef?
        if AXUIElementCopyAttributeValue(original, kAXRoleAttribute as CFString, &role) != .success { return true }
        // 原元素还在、但焦点换到了别的输入框
        var focused: CFTypeRef?
        if AXUIElementCopyAttributeValue(original, kAXFocusedAttribute as CFString, &focused) == .success,
           let b = focused as? Bool { return b }
        return false
    }

    // MARK: 插入

    func insert(_ text: String, into t: Target) -> Outcome {
        let t0 = nowMs()
        guard !text.isEmpty else { return Outcome(method: "skipped", ok: true, detail: "empty", ms: 0) }

        // 多行文字和终端一律走粘贴：AX 写入换行在很多应用里不可靠
        let preferPaste = text.contains("\n") || Inserter.pasteOnlyApps.contains(t.bundleID)
        if !preferPaste, let el = t.element ?? focusedElement() {
            let r = insertViaAX(text, el)
            if r.ok { return Outcome(method: "ax", ok: true, detail: r.detail, ms: nowMs() - t0) }
            if r.wroteMaybe {
                // 写入调用成功但无法确认：不再粘贴，避免重复
                return Outcome(method: "ax", ok: true, detail: "unverified: " + r.detail, ms: nowMs() - t0)
            }
            Log.shared.ev("insert_ax_fallback", ["reason": r.detail, "app": t.bundleID, "role": t.role])
        }
        if pasteViaClipboard(text) {
            return Outcome(method: "paste", ok: true, detail: "cmd+v", ms: nowMs() - t0)
        }
        copyOnly(text)
        return Outcome(method: "clipboard", ok: false, detail: "copied only", ms: nowMs() - t0)
    }

    /// 已知 AX 写入会被吞掉或不稳定的应用：直接粘贴
    static let pasteOnlyApps: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
        "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", // Cursor
        "com.tencent.xinWeChat", "com.electron.lark", "com.bytedance.lark", "com.tinyspeck.slackmacgap",
    ]

    private struct AXResult { let ok: Bool; let wroteMaybe: Bool; let detail: String }

    private func insertViaAX(_ text: String, _ el: AXUIElement) -> AXResult {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(el, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue else {
            return AXResult(ok: false, wroteMaybe: false, detail: "selectedText not settable")
        }
        let beforeValue = stringAttr(el, kAXValueAttribute)
        let beforeRange = rangeAttr(el, kAXSelectedTextRangeAttribute)
        // 读不到值也读不到光标位置：写了也没法确认，直接走粘贴
        if beforeValue == nil && beforeRange == nil {
            return AXResult(ok: false, wroteMaybe: false, detail: "unverifiable element")
        }
        let err = AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, text as CFString)
        guard err == .success else {
            return AXResult(ok: false, wroteMaybe: false, detail: "set error \(err.rawValue)")
        }
        let n = (text as NSString).length
        if let b = beforeValue, let a = stringAttr(el, kAXValueAttribute) {
            let grew = (a as NSString).length - (b as NSString).length
            if a.contains(text) && grew > 0 { return AXResult(ok: true, wroteMaybe: true, detail: "value grew \(grew)") }
            if a == b { return AXResult(ok: false, wroteMaybe: false, detail: "value unchanged") }
        }
        if let br = beforeRange, let ar = rangeAttr(el, kAXSelectedTextRangeAttribute) {
            if ar.location == br.location + n { return AXResult(ok: true, wroteMaybe: true, detail: "caret moved \(n)") }
            if ar.location == br.location && ar.length == br.length {
                return AXResult(ok: false, wroteMaybe: false, detail: "caret unchanged")
            }
        }
        return AXResult(ok: false, wroteMaybe: true, detail: "set ok, change not confirmed")
    }

    // MARK: 剪贴板

    // MARK: 替换（云端结果晚到时覆盖先填入的本机文字）

    /// 辅助功能替换：先核对光标前紧挨着的文字正是 old + suffixAfter，再把 old 换成 new。核对不上就不动。
    func replaceAX(old: String, new: String, suffixAfter: String, in t: Target) -> Bool {
        guard let el = t.element ?? focusedElement(),
              let value = stringAttr(el, kAXValueAttribute),
              let sel = rangeAttr(el, kAXSelectedTextRangeAttribute), sel.length == 0 else { return false }
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(el, kAXSelectedTextRangeAttribute as CFString, &settable) == .success,
              settable.boolValue else { return false }
        let ns = value as NSString
        let tail = old + suffixAfter
        let tailLen = (tail as NSString).length
        guard sel.location >= tailLen, sel.location <= ns.length else { return false }
        let start = sel.location - tailLen
        guard ns.substring(with: NSRange(location: start, length: tailLen)) == tail else { return false }
        var r = CFRange(location: start, length: (old as NSString).length)
        guard let rv = AXValueCreate(.cfRange, &r),
              AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, rv) == .success else { return false }
        // 确认选中的确实是 old，再写入
        guard let selected = rangeAttr(el, kAXSelectedTextRangeAttribute), selected.location == start,
              selected.length == (old as NSString).length else {
            restoreCaret(el, sel.location)
            return false
        }
        guard AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, new as CFString) == .success else {
            restoreCaret(el, sel.location)
            return false
        }
        restoreCaret(el, start + (new as NSString).length + (suffixAfter as NSString).length)
        let expected = ns.replacingCharacters(in: NSRange(location: start, length: (old as NSString).length), with: new)
        guard let after = stringAttr(el, kAXValueAttribute) else { return false }
        return after == expected
    }

    private func restoreCaret(_ el: AXUIElement, _ loc: Int) {
        var r = CFRange(location: loc, length: 0)
        if let v = AXValueCreate(.cfRange, &r) {
            AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, v)
        }
    }

    /// 不支持 Shift+← 选中文字的应用（终端类）：不做“选中再粘贴”
    static let noSelectApps: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable"]

    /// 只能粘贴的应用：用 Shift+← 选中刚粘贴进去的文字，再粘贴新文字。调用方保证这是最后一次填入、期间用户没有操作。
    func replaceLastViaPaste(old: String, new: String, in t: Target) -> Bool {
        guard !Inserter.noSelectApps.contains(t.bundleID) else { return false }
        let n = old.count
        guard n > 0, n <= 300, let src = CGEventSource(stateID: .privateState) else { return false }
        for _ in 0..<n {
            guard let down = CGEvent(keyboardEventSource: src, virtualKey: 123, keyDown: true),
                  let up = CGEvent(keyboardEventSource: src, virtualKey: 123, keyDown: false) else { return false }
            down.flags = .maskShift
            up.flags = .maskShift
            down.setIntegerValueField(.eventSourceUserData, value: HotkeyMonitor.selfEventMarker)
            up.setIntegerValueField(.eventSourceUserData, value: HotkeyMonitor.selfEventMarker)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
        return pasteViaClipboard(new)
    }

    // MARK: 剪贴板（借用和恢复）

    /// 借用剪贴板期间的原始内容；逐段填入时同一时间只借用一次，最后一段用完再恢复
    private var saved: [[(NSPasteboard.PasteboardType, Data)]]?
    private var ourChange = -1
    private var restoreWork: DispatchWorkItem?

    private func pasteViaClipboard(_ text: String) -> Bool {
        let pb = NSPasteboard.general
        restoreWork?.cancel()
        if saved == nil || pb.changeCount != ourChange {
            saved = (pb.pasteboardItems ?? []).map { item in
                item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
            }
        }
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        // 约定俗成的标记：剪贴板管理工具会忽略这类临时内容
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"))
        pb.writeObjects([item])
        ourChange = pb.changeCount

        guard let src = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false) else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.setIntegerValueField(.eventSourceUserData, value: HotkeyMonitor.selfEventMarker)
        up.setIntegerValueField(.eventSourceUserData, value: HotkeyMonitor.selfEventMarker)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)

        let work = DispatchWorkItem { [weak self] in self?.restoreClipboard() }
        restoreWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
        return true
    }

    private func restoreClipboard() {
        let pb = NSPasteboard.general
        defer { saved = nil; ourChange = -1 }
        guard let saved, pb.changeCount == ourChange else { return } // 期间用户自己复制了别的，就不动
        pb.clearContents()
        let items: [NSPasteboardItem] = saved.map { pairs in
            let it = NSPasteboardItem()
            for (type, data) in pairs { it.setData(data, forType: type) }
            return it
        }
        if !items.isEmpty { pb.writeObjects(items) }
    }

    func copyOnly(_ text: String) {
        restoreWork?.cancel()
        saved = nil
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    // MARK: 工具

    private func stringAttr(_ el: AXUIElement, _ name: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v as? String
    }

    private func rangeAttr(_ el: AXUIElement, _ name: String) -> CFRange? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success, let v,
              CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CFRange()
        guard AXValueGetValue(v as! AXValue, .cfRange, &r) else { return nil }
        return r
    }
}
