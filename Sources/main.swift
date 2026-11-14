import AppKit
import Carbon
import ServiceManagement

// MARK: - Model

enum Action {
    case none                               // reference only (mouse gestures, ranges, modifiers)
    case menu(AXUIElement)                  // press the app's own menu item
    case keystroke(CGKeyCode, CGEventFlags) // replay the shortcut into the app
    case macro([Step])                      // several of the above, in order
}

enum Step {
    case menu(AXUIElement)
    case keystroke(CGKeyCode, CGEventFlags)
    case wait(Double)
}

struct Item {
    let title: String
    let category: String
    let keys: String
    let action: Action
    let enabled: Bool
    let foldedTitle: String
    let foldedKeys: String
    let foldedCategory: String
    let mainKey: String // the non-modifier key of the first combination, e.g. "t" for ⇧⌘T

    init(title: String, category: String, keys: String, action: Action, enabled: Bool = true) {
        self.title = title
        self.category = category
        self.keys = keys
        self.action = action
        self.enabled = enabled
        foldedTitle = fold(title)
        foldedCategory = fold(category)
        // Let people type "cmd shift t" as well as the symbols.
        var words = keys
        for (symbol, names) in [("⌘", " cmd command "), ("⌥", " option opt alt "), ("⇧", " shift "), ("⌃", " ctrl control "),
                                ("Enter", " enter return "), ("Delete", " delete backspace "), ("Esc", " esc escape "),
                                ("←", " left "), ("→", " right "), ("↑", " up "), ("↓", " down ")] {
            words = words.replacingOccurrences(of: symbol, with: names)
        }
        foldedKeys = fold(keys + " " + words)
        let first = keys.components(separatedBy: "  /  ").first ?? ""
        mainKey = fold(first.trimmingCharacters(in: CharacterSet(charactersIn: "⌃⌥⇧⌘ ")))
    }
}

func fold(_ s: String) -> String {
    s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
}

func isSubsequence(_ needle: String, of haystack: String) -> Bool {
    var remaining = Substring(needle)
    for character in haystack where character == remaining.first {
        remaining = remaining.dropFirst()
        if remaining.isEmpty { return true }
    }
    return remaining.isEmpty
}

/// Every whitespace-separated token must match somewhere; title matches rank highest.
func search(_ items: [Item], _ query: String) -> [Item] {
    let tokens = fold(query).split(separator: " ").map(String.init)
    guard !tokens.isEmpty else { return items }
    var scored: [(Int, Int, Item)] = []
    for (index, item) in items.enumerated() {
        var total = 0
        var matched = true
        for token in tokens {
            if item.mainKey == token { total += 120 }
            else if item.foldedTitle.hasPrefix(token) { total += 100 }
            else if item.foldedTitle.contains(" " + token) || item.foldedTitle.contains("/" + token) { total += 60 }
            else if item.foldedTitle.contains(token) { total += 40 }
            else if item.foldedKeys.contains(token) { total += 30 }
            else if item.foldedCategory.contains(token) { total += 10 }
            else if token.count > 2, item.foldedTitle.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .contains(where: { $0.first == token.first && isSubsequence(token, of: String($0)) }) { total += 5 }
            else { matched = false; break }
        }
        if matched { scored.append((total, index, item)) }
    }
    return scored.sorted { a, b in
        if a.0 != b.0 { return a.0 > b.0 }
        if a.2.keys.count != b.2.keys.count, !a.2.keys.isEmpty, !b.2.keys.isEmpty { return a.2.keys.count < b.2.keys.count }
        return a.1 < b.1
    }.map { $0.2 }
}

// MARK: - Keyboard layout

/// Character -> (key code, needs shift) for the current keyboard layout, so replayed
/// shortcuts land on the right physical key on non-US layouts too.
let charKeyMap: [String: (CGKeyCode, Bool)] = {
    var map: [String: (CGKeyCode, Bool)] = [:]
    guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
          let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return map }
    let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return }
        for shift in [false, true] {
            for code in 0...50 where ![36, 48, 49].contains(code) {
                var deadKeys: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), shift ? 2 : 0,
                                            UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask),
                                            &deadKeys, 4, &length, &chars)
                guard status == noErr, length > 0 else { continue }
                let string = String(utf16CodeUnits: chars, count: length)
                if map[string] == nil { map[string] = (CGKeyCode(code), shift) }
            }
        }
    }
    return map
}()

let namedKeys: [String: (CGKeyCode, String)] = [
    "tab": (48, "Tab"), "space": (49, "Space"), "enter": (36, "Enter"), "delete": (51, "Delete"), "esc": (53, "Esc"),
    "home": (115, "Home"), "end": (119, "End"),
    "left arrow": (123, "←"), "right arrow": (124, "→"), "down arrow": (125, "↓"), "up arrow": (126, "↑"),
    "f1": (122, "F1"), "f2": (120, "F2"), "f3": (99, "F3"), "f4": (118, "F4"), "f5": (96, "F5"), "f6": (97, "F6"),
    "f7": (98, "F7"), "f8": (100, "F8"), "f9": (101, "F9"), "f10": (109, "F10"), "f11": (103, "F11"), "f12": (111, "F12"),
]

let virtualKeyNames: [Int: String] = {
    var names = [117: "⌦", 116: "Page Up", 121: "Page Down", 76: "⌅"]
    for (_, value) in namedKeys { names[Int(value.0)] = value.1 }
    return names
}()

// MARK: - Shortcut file parsing

/// Turns the manual's spelling ("CmdShiftT", "Shift click or drag") into display text and,
/// when it is one plain key combination, a keystroke that can be replayed.
func parseCombo(_ raw: String) -> (display: String, stroke: (CGKeyCode, CGEventFlags)?) {
    let alternatives = raw.components(separatedBy: " or ")
    var displays: [String] = []
    var stroke: (CGKeyCode, CGEventFlags)?
    for (index, alternative) in alternatives.enumerated() {
        var rest = alternative.trimmingCharacters(in: .whitespaces)
        var flags: CGEventFlags = []
        var consumed = true
        while consumed {
            consumed = false
            for (word, flag) in [("Ctrl", CGEventFlags.maskControl), ("Cmd", .maskCommand), ("Option", .maskAlternate), ("Shift", .maskShift)]
            where rest.hasPrefix(word) {
                rest = String(rest.dropFirst(word.count)).trimmingCharacters(in: .whitespaces)
                flags.insert(flag)
                consumed = true
            }
        }
        var mods = ""
        if flags.contains(.maskControl) { mods += "⌃" }
        if flags.contains(.maskAlternate) { mods += "⌥" }
        if flags.contains(.maskShift) { mods += "⇧" }
        if flags.contains(.maskCommand) { mods += "⌘" }

        let keyName = rest.lowercased().replacingOccurrences(of: " key", with: "")
        var keyDisplay = rest
        var keyCode: CGKeyCode?
        if let named = namedKeys[keyName] {
            keyCode = named.0
            keyDisplay = named.1
            if (123...126).contains(Int(named.0)) { flags.insert([.maskNumericPad, .maskSecondaryFn]) }
            if named.1.hasPrefix("F") && named.1.count > 1 || named.1 == "Home" || named.1 == "End" { flags.insert(.maskSecondaryFn) }
        } else if rest.count == 1 {
            keyDisplay = rest.uppercased()
            if let mapped = charKeyMap[rest.lowercased()] ?? charKeyMap[rest] {
                keyCode = mapped.0
                if mapped.1 { flags.insert(.maskShift) }
            }
        } else {
            for (phrase, symbol) in [("up and down arrow keys", "↑ ↓"), ("right and left arrow keys", "← →"),
                                     ("left and right arrow keys", "← →"), ("arrow keys", "arrows"),
                                     ("Function left arrow key", "Fn ←"), ("Function right arrow key", "Fn →"),
                                     ("Option", "⌥"), ("Cmd", "⌘")] {
                keyDisplay = keyDisplay.replacingOccurrences(of: phrase, with: symbol)
            }
        }
        if index == 0, let keyCode { stroke = (keyCode, flags) }
        let spaced = !mods.isEmpty && keyDisplay.count > 1 && keyCode == nil
        displays.append(mods + (spaced ? " " : "") + keyDisplay)
    }
    return (displays.joined(separator: "  /  "), stroke)
}

func loadShortcutFile(_ url: URL) -> [Item] {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    var items: [Item] = []
    var section = ""
    for line in text.split(separator: "\n") {
        let line = line.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("## ") { section = String(line.dropFirst(3)); continue }
        if line.hasPrefix("#") { continue }
        guard let separator = line.range(of: " | ", options: .backwards) else { continue }
        let combo = parseCombo(String(line[separator.upperBound...]))
        let action: Action = combo.stroke.map { .keystroke($0.0, $0.1) } ?? .none
        items.append(Item(title: String(line[..<separator.lowerBound]), category: section, keys: combo.display, action: action))
    }
    return items
}

// MARK: - Menu bar scanning (Accessibility)

func axValue<T>(_ element: AXUIElement, _ attribute: String) -> T? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value as? T
}

func menuShortcut(_ element: AXUIElement) -> String {
    let char: String? = axValue(element, kAXMenuItemCmdCharAttribute)
    let virtualKey: Int? = axValue(element, kAXMenuItemCmdVirtualKeyAttribute)
    var key = ""
    if let char, !char.isEmpty {
        switch char {
        case "\r", "\u{3}": key = "Enter"
        case "\t": key = "Tab"
        case " ": key = "Space"
        case "\u{8}", "\u{7F}": key = "Delete"
        case "\u{1B}": key = "Esc"
        default: key = char.uppercased()
        }
    } else if let virtualKey, let name = virtualKeyNames[virtualKey] {
        key = name
    }
    guard !key.isEmpty else { return "" }
    let modifiers: Int = axValue(element, kAXMenuItemCmdModifiersAttribute) ?? 0
    var text = ""
    if modifiers & 4 != 0 { text += "⌃" }
    if modifiers & 2 != 0 { text += "⌥" }
    if modifiers & 1 != 0 { text += "⇧" }
    if modifiers & 8 == 0 { text += "⌘" }
    return text + key
}

func walkMenu(_ menu: AXUIElement, path: [String], into items: inout [Item], depth: Int = 0) {
    guard depth < 6, let children: [AXUIElement] = axValue(menu, kAXChildrenAttribute) else { return }
    for child in children {
        guard let title: String = axValue(child, kAXTitleAttribute), !title.isEmpty else { continue }
        if let submenu = (axValue(child, kAXChildrenAttribute) as [AXUIElement]?)?.first {
            walkMenu(submenu, path: path + [title], into: &items, depth: depth + 1)
        } else {
            let enabled: Bool = axValue(child, kAXEnabledAttribute) ?? true
            items.append(Item(title: title, category: path.joined(separator: " ▸ "), keys: menuShortcut(child),
                              action: .menu(child), enabled: enabled))
        }
    }
}

func scanMenus(pid: pid_t) -> [Item] {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 1.5)
    guard let menuBar: AXUIElement = axValue(app, kAXMenuBarAttribute),
          let barItems: [AXUIElement] = axValue(menuBar, kAXChildrenAttribute) else { return [] }
    var items: [Item] = []
    for barItem in barItems.dropFirst() { // skip the Apple menu
        guard let title: String = axValue(barItem, kAXTitleAttribute),
              let menu = (axValue(barItem, kAXChildrenAttribute) as [AXUIElement]?)?.first else { continue }
        walkMenu(menu, path: [title], into: &items)
    }
    return items
}

/// A pressed key as the spelling macro steps use ("CmdShiftT", "F9", "Shift Left Arrow").
func comboSpelling(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> String? {
    var key: String?
    if let named = namedKeys.first(where: { $0.value.0 == CGKeyCode(keyCode) }) {
        key = named.key.capitalized
    } else if let character = charKeyMap.first(where: { $0.value.0 == CGKeyCode(keyCode) && !$0.value.1 })?.key {
        key = character.uppercased()
    }
    guard let key else { return nil }
    var modifiers = ""
    if flags.contains(.control) { modifiers += "Ctrl" }
    if flags.contains(.command) { modifiers += "Cmd" }
    if flags.contains(.option) { modifiers += "Option" }
    if flags.contains(.shift) { modifiers += "Shift" }
    return modifiers + (key.contains(" ") && !modifiers.isEmpty ? " " : "") + key
}

// MARK: - App icon

func drawIcon(_ s: CGFloat) {
    let tile = NSBezierPath(roundedRect: NSRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8), xRadius: s * 0.18, yRadius: s * 0.18)
    NSGradient(starting: NSColor(calibratedRed: 0.24, green: 0.24, blue: 0.28, alpha: 1),
               ending: NSColor(calibratedRed: 0.08, green: 0.08, blue: 0.10, alpha: 1))?.draw(in: tile, angle: -90)
    let cap = NSRect(x: s * 0.25, y: s * 0.28, width: s * 0.5, height: s * 0.46)
    let shadow = NSBezierPath(roundedRect: cap.offsetBy(dx: 0, dy: -s * 0.035), xRadius: s * 0.09, yRadius: s * 0.09)
    NSColor(calibratedRed: 0.62, green: 0.33, blue: 0.02, alpha: 1).setFill()
    shadow.fill()
    NSGradient(starting: NSColor(calibratedRed: 1.0, green: 0.72, blue: 0.25, alpha: 1),
               ending: NSColor(calibratedRed: 0.98, green: 0.55, blue: 0.08, alpha: 1))?
        .draw(in: NSBezierPath(roundedRect: cap, xRadius: s * 0.09, yRadius: s * 0.09), angle: -90)
    let glyph = NSAttributedString(string: "⌘", attributes: [.font: NSFont.systemFont(ofSize: s * 0.3, weight: .bold),
                                                              .foregroundColor: NSColor(white: 0.1, alpha: 1)])
    let size = glyph.size()
    glyph.draw(at: NSPoint(x: cap.midX - size.width / 2, y: cap.midY - size.height / 2))
}

// Keyseek --make-icon <file.icns>   (used by build.sh; writes the .icns container directly)
if let flag = CommandLine.arguments.firstIndex(of: "--make-icon"), CommandLine.arguments.count > flag + 1 {
    var body = Data()
    for (pixels, type) in [(16, "icp4"), (32, "icp5"), (64, "icp6"), (128, "ic07"), (256, "ic08"), (512, "ic09"), (1024, "ic10"),
                           (32, "ic11"), (64, "ic12"), (256, "ic13"), (512, "ic14")] {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        drawIcon(CGFloat(pixels))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
        body.append(type.data(using: .ascii)!)
        withUnsafeBytes(of: UInt32(png.count + 8).bigEndian) { body.append(contentsOf: $0) }
        body.append(png)
    }
    var file = "icns".data(using: .ascii)!
    withUnsafeBytes(of: UInt32(body.count + 8).bigEndian) { file.append(contentsOf: $0) }
    file.append(body)
    do { try file.write(to: URL(fileURLWithPath: CommandLine.arguments[flag + 1])) } catch { exit(1) }
    exit(0)
}

/// A shortcut spelling as a Carbon hotkey (key code, modifier mask).
func carbonHotKey(_ spelling: String) -> (code: UInt32, modifiers: UInt32)? {
    guard !spelling.contains(" or "), let stroke = parseCombo(spelling).stroke else { return nil }
    var modifiers = 0
    if stroke.1.contains(.maskCommand) { modifiers |= cmdKey }
    if stroke.1.contains(.maskAlternate) { modifiers |= optionKey }
    if stroke.1.contains(.maskControl) { modifiers |= controlKey }
    if stroke.1.contains(.maskShift) { modifiers |= shiftKey }
    return (UInt32(stroke.0), UInt32(modifiers))
}

// MARK: - Macros

struct MacroDef {
    var name: String
    var steps: [String]
    var shortcut: String? = nil // spelled like a step, e.g. "CmdOption1"
}

/// ~/Library/Application Support/Keyseek/Macros/<bundle id>.txt
func macrosURL(_ bundleID: String) -> URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Keyseek/Macros/\(bundleID).txt")
}

func macroFileText(_ macros: [MacroDef], appName: String, bundleID: String) -> String {
    var text = """
    # Keyseek macros for \(appName) (\(bundleID)).
    # Edit them in Keyseek (menu bar icon > Edit Macros), or by hand:
    # "## Name" starts a macro; each line after it is one step, which is the name of an entry
    # in the Keyseek list, a key combination (CmdShiftT, F9, C), or a pause (wait 0.5).
    # An optional "shortcut: CmdOption1" line gives the macro its own keyboard shortcut in that app.

    """
    for macro in macros {
        let name = macro.name.trimmingCharacters(in: .whitespacesAndNewlines)
        text += "\n## \(name.isEmpty ? "Untitled" : name)\n"
        if let shortcut = macro.shortcut { text += "shortcut: \(shortcut)\n" }
        text += macro.steps.map { $0 + "\n" }.joined()
    }
    return text
}

func stepResolves(_ text: String, titles: Set<String>) -> Bool {
    let lower = text.lowercased()
    if lower.hasPrefix("wait ") { return Double(lower.dropFirst(5).trimmingCharacters(in: .whitespaces)) != nil }
    if titles.contains(fold(text)) { return true }
    return !text.contains(" or ") && parseCombo(text).stroke != nil
}

func appDisplayName(_ bundleID: String) -> String {
    if let name = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName { return name }
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
    return bundleID
}

func loadMacros(_ url: URL) -> [MacroDef] {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    var macros: [MacroDef] = []
    for line in text.split(separator: "\n") {
        let line = line.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("## ") { macros.append(MacroDef(name: String(line.dropFirst(3)), steps: [])) }
        else if line.isEmpty || line.hasPrefix("#") || macros.isEmpty { continue }
        else if line.lowercased().hasPrefix("shortcut:") {
            let value = line.dropFirst(9).trimmingCharacters(in: .whitespaces)
            macros[macros.count - 1].shortcut = value.isEmpty ? nil : value
        }
        else { macros[macros.count - 1].steps.append(line) }
    }
    return macros
}

/// Turns macro definitions into list entries, resolving each step against the entries the app
/// currently offers. A macro with a step that cannot be resolved is listed but disabled.
func buildMacroItems(_ macros: [MacroDef], reference: [Item], menus: [Item]) -> [Item] {
    var lookup: [String: Item] = [:]
    for item in reference { if case .keystroke = item.action, lookup[item.foldedTitle] == nil { lookup[item.foldedTitle] = item } }
    for item in menus { lookup[item.foldedTitle] = item } // the app's own menu command wins
    return macros.map { macro in
        var steps: [Step] = []
        var missing: String?
        for text in macro.steps {
            let lower = text.lowercased()
            if lower.hasPrefix("wait "), let seconds = Double(lower.dropFirst(5).trimmingCharacters(in: .whitespaces)) {
                steps.append(.wait(seconds))
            } else if let item = lookup[fold(text)], case .menu(let element) = item.action {
                steps.append(.menu(element))
            } else if let item = lookup[fold(text)], case .keystroke(let code, let flags) = item.action {
                steps.append(.keystroke(code, flags))
            } else if !text.contains(" or "), let stroke = parseCombo(text).stroke {
                steps.append(.keystroke(stroke.0, stroke.1))
            } else {
                missing = missing ?? text
            }
        }
        if let missing {
            return Item(title: macro.name, category: "Macro  ·  step not found: \(missing)", keys: "", action: .none, enabled: false)
        }
        return Item(title: macro.name, category: "Macro  ·  " + macro.steps.joined(separator: " → "),
                    keys: macro.shortcut.map { parseCombo($0).display } ?? "",
                    action: steps.isEmpty ? .none : .macro(steps), enabled: !steps.isEmpty)
    }
}

// MARK: - Self test (no UI): Keyseek --selftest <shortcut file> [query]

if let flag = CommandLine.arguments.firstIndex(of: "--macrotest"), CommandLine.arguments.count > flag + 2 {
    let reference = loadShortcutFile(URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
    let macros = loadMacros(URL(fileURLWithPath: CommandLine.arguments[flag + 2]))
    print(macroFileText(macros, appName: "Test", bundleID: "test.app"))
    for (code, flags) in [(UInt16(17), NSEvent.ModifierFlags([.command, .shift])), (101, []), (123, [.option]), (8, []), (53, [])] {
        let spelling = comboSpelling(keyCode: code, flags: flags) ?? "nil"
        print("recorded key \(code) -> \(spelling) -> \(String(describing: parseCombo(spelling).stroke))")
    }
    for item in buildMacroItems(macros, reference: reference, menus: []) {
        var how = "disabled"
        if case .macro(let steps) = item.action { how = steps.map { "\($0)" }.joined(separator: " | ") }
        print("\(item.title)  [\(item.category)]\n    \(how)")
    }
    exit(0)
}

if let flag = CommandLine.arguments.firstIndex(of: "--selftest"), CommandLine.arguments.count > flag + 1 {
    let items = loadShortcutFile(URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
    let runnable = items.filter { if case .keystroke = $0.action { return true } else { return false } }
    print("\(items.count) shortcuts, \(runnable.count) replayable, layout map has \(charKeyMap.count) characters")
    let shown = CommandLine.arguments.count > flag + 2 ? search(items, CommandLine.arguments[flag + 2]) : items
    for item in shown {
        var how = "reference"
        if case .keystroke(let code, let flags) = item.action { how = "key \(code) flags 0x\(String(flags.rawValue, radix: 16))" }
        print("\(item.keys.padding(toLength: 16, withPad: " ", startingAt: 0)) \(item.title)  [\(item.category)]  <\(how)>")
    }
    exit(0)
}

// MARK: - UI

final class SearchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class RowView: NSTableRowView {
    override var isEmphasized: Bool { get { true } set {} }
}

final class ItemCell: NSTableCellView {
    let title = NSTextField(labelWithString: "")
    let subtitle = NSTextField(labelWithString: "")
    let keys = KeysView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = .systemFont(ofSize: 14, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        for view in [title, subtitle, keys] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        keys.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        keys.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
            keys.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            keys.centerYAnchor.constraint(equalTo: centerYAnchor),
            keys.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.6),
            title.trailingAnchor.constraint(lessThanOrEqualTo: keys.leadingAnchor, constant: -12),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: keys.leadingAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

func hotKeyDescription(_ code: UInt32, _ carbonModifiers: UInt32) -> String {
    var text = ""
    if carbonModifiers & UInt32(controlKey) != 0 { text += "⌃" }
    if carbonModifiers & UInt32(optionKey) != 0 { text += "⌥" }
    if carbonModifiers & UInt32(shiftKey) != 0 { text += "⇧" }
    if carbonModifiers & UInt32(cmdKey) != 0 { text += "⌘" }
    let name = virtualKeyNames[Int(code)]
        ?? charKeyMap.first(where: { $0.value.0 == CGKeyCode(code) && !$0.value.1 })?.key.uppercased()
        ?? "Key \(code)"
    return text + name
}

/// One key drawn as a keycap.
final class KeyCap: NSView {
    init(_ text: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.13).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: text.count == 1 ? 13 : 12, weight: .semibold)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        translatesAutoresizingMaskIntoConstraints = false
        setContentCompressionResistancePriority(.required, for: .horizontal)
        // Stay as narrow as the label allows instead of stretching to fill the row.
        let snug = widthAnchor.constraint(equalToConstant: 24)
        snug.priority = NSLayoutConstraint.Priority(900)
        snug.isActive = true
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(greaterThanOrEqualTo: label.widthAnchor, constant: 10),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 24),
            heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// A shortcut such as "⇧⌘T" or "End  /  Fn →" drawn as separate keycaps, with plain words in between.
final class KeysView: NSStackView {
    static let capWords: Set<String> = ["Space", "Tab", "Enter", "Delete", "Esc", "Home", "End", "Fn",
                                        "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12"]
    static let modifierNames: [Character: String] = ["⌃": "Ctrl", "⌥": "Option", "⇧": "Shift", "⌘": "Cmd"]
    private var current = ""

    func set(_ keys: String, dimmed: Bool) {
        alphaValue = dimmed ? 0.4 : 1
        let useNames = UserDefaults.standard.bool(forKey: "modifierNames")
        let signature = keys + (useNames ? "|names" : "|symbols")
        guard signature != current else { return }
        current = signature
        orientation = .horizontal
        spacing = 3
        setHuggingPriority(.required, for: .horizontal)
        for view in arrangedSubviews { removeArrangedSubview(view); view.removeFromSuperview() }

        func cap(_ text: String) {
            if useNames, text.count == 1, let name = KeysView.modifierNames[text.first!] { addArrangedSubview(KeyCap(name)) }
            else { addArrangedSubview(KeyCap(text)) }
        }
        func plain(_ text: String) {
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            addArrangedSubview(label)
        }
        for (index, alternative) in keys.components(separatedBy: "  /  ").enumerated() {
            if index > 0 { plain("or") }
            var rest = Substring(alternative)
            while let first = rest.first, KeysView.modifierNames[first] != nil {
                cap(String(first))
                rest = rest.dropFirst()
            }
            var words: [String] = []
            for word in rest.split(separator: " ").map(String.init) {
                let isKey = KeysView.capWords.contains(word) || (word.count == 1 && word == word.uppercased())
                if isKey {
                    if !words.isEmpty { plain(words.joined(separator: " ")); words = [] }
                    cap(word)
                } else {
                    words.append(word)
                }
            }
            if !words.isEmpty { plain(words.joined(separator: " ")) }
        }
    }
}

func iconButton(_ symbol: String, _ tip: String, _ target: AnyObject, _ action: Selector) -> NSButton {
    let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage()
    let button = NSButton(image: image, target: target, action: action)
    button.bezelStyle = .texturedRounded
    button.toolTip = tip
    button.setAccessibilityLabel(tip)
    button.widthAnchor.constraint(equalToConstant: 32).isActive = true
    return button
}

func makeButton(_ title: String, _ target: AnyObject, _ action: Selector) -> NSButton {
    let button = NSButton(title: title, target: target, action: action)
    button.bezelStyle = .rounded
    return button
}

func configureTable(_ table: NSTableView, columns: [(String, CGFloat)],
                    owner: NSTableViewDataSource & NSTableViewDelegate) -> NSScrollView {
    for (title, width) in columns {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(title))
        column.title = title
        column.width = width
        table.addTableColumn(column)
    }
    table.dataSource = owner
    table.delegate = owner
    table.rowHeight = 22
    table.usesAlternatingRowBackgroundColors = true
    table.allowsMultipleSelection = false
    table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
    let scroll = NSScrollView()
    scroll.documentView = table
    scroll.hasVerticalScroller = true
    scroll.borderType = .bezelBorder
    scroll.translatesAutoresizingMaskIntoConstraints = false
    return scroll
}

func textCell(_ table: NSTableView, _ text: String, color: NSColor = .labelColor) -> NSView {
    let id = NSUserInterfaceItemIdentifier("text")
    let cell: NSTableCellView
    if let reused = table.makeView(withIdentifier: id, owner: nil) as? NSTableCellView {
        cell = reused
    } else {
        cell = NSTableCellView()
        cell.identifier = id
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -3),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
    }
    cell.textField?.stringValue = text
    cell.textField?.textColor = color
    cell.toolTip = text
    return cell
}

/// The macro organizer for one app: macros on the left, the app's commands in the middle,
/// the selected macro's steps on the right. Every change is saved straight away.
final class MacroEditor: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    let recordButton = NSButton(title: "Record Keys", target: nil, action: nil)
    let shortcutButton = NSButton(title: "Record Shortcut", target: nil, action: nil)
    var recordMonitor: Any?
    var recordingShortcut = false
    var listPane: NSView?
    var starterButton: NSButton?

    unowned let app: AppDelegate
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 540),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
    let macroTable = NSTableView(), commandTable = NSTableView(), stepTable = NSTableView()
    let searchField = NSSearchField(), titleField = NSTextField(), customField = NSTextField()
    let status = NSTextField(labelWithString: "")
    var bundleID = "", appName = ""
    var macros: [MacroDef] = []
    var reference: [Item] = [], menus: [Item] = []
    var commands: [Item] = [], filtered: [Item] = []
    var titles: Set<String> = []
    var generation = 0

    init(app: AppDelegate) {
        self.app = app
        super.init()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 880, height: 420)
        window.delegate = self
        recordButton.bezelStyle = .rounded
        recordButton.target = self
        recordButton.action = #selector(toggleRecordStep)

        let macroScroll = configureTable(macroTable, columns: [("Name", 150), ("Steps", 42), ("Shortcut", 70)], owner: self)
        let commandScroll = configureTable(commandTable, columns: [("Command", 180), ("Shortcut / Menu", 130)], owner: self)
        for table in [macroTable, commandTable, stepTable] { table.sizeLastColumnToFit() }
        let stepScroll = configureTable(stepTable, columns: [("Step", 280)], owner: self)
        for scroll in [macroScroll, commandScroll, stepScroll] {
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
            scroll.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        }
        commandTable.target = self
        commandTable.doubleAction = #selector(addStep)
        searchField.placeholderString = "Filter commands"
        searchField.delegate = self
        titleField.placeholderString = "Macro name"
        titleField.delegate = self
        customField.placeholderString = "or type: CmdShiftT, wait 0.5"
        customField.target = self
        customField.action = #selector(addCustomStep)
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail

        func row(_ views: [NSView]) -> NSStackView {
            let stack = NSStackView(views: views)
            stack.orientation = .horizontal
            stack.distribution = .fill
            stack.spacing = 8
            return stack
        }
        func pane(_ title: String, _ views: [NSView]) -> NSStackView {
            let heading = NSTextField(labelWithString: title)
            heading.font = .boldSystemFont(ofSize: 12)
            let stack = NSStackView(views: [heading] + views)
            stack.orientation = .vertical
            stack.distribution = .fill
            stack.alignment = .leading
            stack.spacing = 8
            for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
            return stack
        }
        let starter = iconButton("wand.and.stars", "Add Keyseek's starter macros for this app", self, #selector(addStarterMacros))
        starterButton = starter
        let left = pane("Macros", [macroScroll, row([iconButton("plus", "New macro", self, #selector(newMacro)),
                                                     iconButton("plus.square.on.square", "Duplicate the selected macro", self, #selector(duplicateMacro)),
                                                     iconButton("trash", "Delete the selected macro", self, #selector(deleteMacro)), starter,
                                                     NSView()])])
        let middle = pane("Commands", [searchField, commandScroll])
        let help = NSButton(title: "", target: self, action: #selector(showHelp(_:)))
        help.bezelStyle = .helpButton
        shortcutButton.bezelStyle = .rounded
        shortcutButton.target = self
        shortcutButton.action = #selector(toggleRecordShortcut)
        let titleLabel = NSTextField(labelWithString: "Title"), shortcutLabel = NSTextField(labelWithString: "Shortcut")
        for label in [titleLabel, shortcutLabel] { label.widthAnchor.constraint(equalToConstant: 58).isActive = true }
        let right = pane("Macro", [row([titleLabel, titleField]),
                                   row([shortcutLabel, shortcutButton,
                                        iconButton("xmark.circle", "Remove this macro's shortcut", self, #selector(clearShortcut)), NSView()]),
                                   stepScroll,
                                   row([recordButton, customField, makeButton("Add Step", self, #selector(addCustomStep)), help]),
                                   status])
        let spacer = NSView()
        spacer.heightAnchor.constraint(equalToConstant: 96).isActive = true
        let buttons = NSStackView(views: [spacer,
                                          iconButton("arrow.right", "Add the selected command to the macro", self, #selector(addStep)),
                                          iconButton("trash", "Remove the selected step", self, #selector(removeStep)),
                                          iconButton("chevron.up", "Move the selected step up", self, #selector(moveStepUp)),
                                          iconButton("chevron.down", "Move the selected step down", self, #selector(moveStepDown))])
        buttons.orientation = .vertical
        buttons.spacing = 8
        buttons.setHuggingPriority(.required, for: .horizontal)

        let root = NSStackView(views: [left, middle, buttons, right])
        root.orientation = .horizontal
        root.distribution = .fill
        root.alignment = .top
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        for view in [left, middle, right] { view.heightAnchor.constraint(equalTo: root.heightAnchor, constant: -32).isActive = true }
        left.widthAnchor.constraint(equalToConstant: 300).isActive = true
        middle.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true
        middle.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        for view in [middle, right] { view.setHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal) }
        window.contentView = root

        // A sidebar button in the title bar hides the macro list, giving the other two columns its width.
        listPane = left
        let toggle = NSButton(image: NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Show or hide the macro list") ?? NSImage(),
                              target: self, action: #selector(toggleMacroList))
        toggle.bezelStyle = .texturedRounded
        toggle.isBordered = false
        toggle.toolTip = "Show or hide the macro list"
        toggle.frame = NSRect(x: 0, y: 0, width: 36, height: 28)
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = toggle
        accessory.layoutAttribute = .leading
        window.addTitlebarAccessoryViewController(accessory)
        left.isHidden = UserDefaults.standard.bool(forKey: "macroListCollapsed")
        commandTable.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
    }

    func open(bundleID: String, appName: String) {
        self.bundleID = bundleID
        self.appName = appName
        window.title = "Macros — \(appName)"
        macros = loadMacros(macrosURL(bundleID))
        reference = Bundle.main.url(forResource: bundleID, withExtension: "txt").map(loadShortcutFile) ?? []
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        menus = running.flatMap { app.menuCache[$0.processIdentifier] } ?? []
        searchField.stringValue = ""
        starterButton?.isHidden = starterMacros().isEmpty
        rebuildCommands()
        reloadMacros(select: 0)
        status.stringValue = running == nil ? "\(appName) is not running, so its menu commands are not listed." : ""
        NSApp.activate(ignoringOtherApps: true)
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        app.updateActivationPolicy()

        generation += 1
        let expected = generation
        guard let pid = running?.processIdentifier, AXIsProcessTrusted() else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let scanned = scanMenus(pid: pid)
            DispatchQueue.main.async {
                guard expected == self.generation, !scanned.isEmpty else { return }
                self.menus = scanned
                self.rebuildCommands()
                self.stepTable.reloadData()
            }
        }
    }

    // MARK: Data

    var current: Int? { macroTable.selectedRow >= 0 && macroTable.selectedRow < macros.count ? macroTable.selectedRow : nil }

    func rebuildCommands() {
        let menuTitles = Set(menus.map(\.foldedTitle))
        commands = (menus + reference.filter { !menuTitles.contains($0.foldedTitle) }).filter {
            if case .none = $0.action { return false } else { return true }
        }
        titles = Set(commands.map(\.foldedTitle))
        filtered = search(commands, searchField.stringValue)
        commandTable.reloadData()
    }

    func reloadMacros(select row: Int) {
        macroTable.reloadData()
        if !macros.isEmpty { macroTable.selectRowIndexes([max(0, min(macros.count - 1, row))], byExtendingSelection: false) }
        showCurrent()
    }

    func showCurrent() {
        titleField.stringValue = current.map { macros[$0].name } ?? ""
        titleField.isEnabled = current != nil
        updateTitle()
        shortcutButton.isEnabled = current != nil
        updateShortcutButton()
        stepTable.reloadData()
    }

    func save() {
        let url = macrosURL(bundleID)
        do {
            if macros.isEmpty {
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            } else {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try macroFileText(macros, appName: appName, bundleID: bundleID).write(to: url, atomically: true, encoding: .utf8)
            }
            status.stringValue = "Saved."
        } catch {
            status.stringValue = "Could not save: \(error.localizedDescription)"
        }
    }

    func stepsChanged(select row: Int? = nil) {
        guard let index = current else { return }
        stepTable.reloadData()
        if let row, !macros[index].steps.isEmpty {
            stepTable.selectRowIndexes([max(0, min(macros[index].steps.count - 1, row))], byExtendingSelection: false)
        }
        macroTable.reloadData(forRowIndexes: [index], columnIndexes: [1])
        save()
    }

    // MARK: Macro list actions

    @objc func newMacro() {
        var name = "New Macro"
        var number = 2
        while macros.contains(where: { $0.name == name }) { name = "New Macro \(number)"; number += 1 }
        macros.append(MacroDef(name: name, steps: []))
        reloadMacros(select: macros.count - 1)
        save()
        window.makeFirstResponder(titleField)
    }

    /// Ready-made macros shipped inside Keyseek for this app, if any.
    func starterMacros() -> [MacroDef] {
        Bundle.main.url(forResource: bundleID + ".macros", withExtension: "txt").map(loadMacros) ?? []
    }

    @objc func addStarterMacros() {
        let fresh = starterMacros().filter { starter in !macros.contains { $0.name == starter.name } }
        guard !fresh.isEmpty else { status.stringValue = "All starter macros are already in your list."; return }
        macros.append(contentsOf: fresh)
        reloadMacros(select: macros.count - fresh.count)
        save()
        status.stringValue = "Added \(fresh.count) starter macro\(fresh.count == 1 ? "" : "s")."
    }

    @objc func duplicateMacro() {
        guard let index = current else { NSSound.beep(); return }
        macros.insert(MacroDef(name: macros[index].name + " copy", steps: macros[index].steps), at: index + 1)
        reloadMacros(select: index + 1)
        save()
    }

    @objc func deleteMacro() {
        guard let index = current else { NSSound.beep(); return }
        let alert = NSAlert()
        alert.messageText = "Delete the macro “\(macros[index].name)”?"
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        macros.remove(at: index)
        reloadMacros(select: index)
        save()
    }

    // MARK: Step actions

    @objc func addStep() {
        guard let index = current else { status.stringValue = "Create or select a macro first."; NSSound.beep(); return }
        let row = commandTable.clickedRow >= 0 ? commandTable.clickedRow : commandTable.selectedRow
        guard row >= 0, row < filtered.count else { NSSound.beep(); return }
        macros[index].steps.append(filtered[row].title)
        stepsChanged(select: macros[index].steps.count - 1)
    }

    @objc func addCustomStep() {
        let text = customField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        guard let index = current else { status.stringValue = "Create or select a macro first."; NSSound.beep(); return }
        guard !text.hasPrefix("#"), stepResolves(text, titles: titles) else {
            status.stringValue = "“\(text)” is not a command name, a key combination or “wait <seconds>”."
            NSSound.beep()
            return
        }
        macros[index].steps.append(text)
        customField.stringValue = ""
        stepsChanged(select: macros[index].steps.count - 1)
    }

    @objc func toggleMacroList() {
        guard let listPane else { return }
        listPane.isHidden.toggle()
        UserDefaults.standard.set(listPane.isHidden, forKey: "macroListCollapsed")
        updateTitle()
    }

    /// With the list hidden, the window title is the only place that says which macro is being edited.
    func updateTitle() {
        let macro = listPane?.isHidden == true ? current.map { "  ·  " + macros[$0].name } ?? "" : ""
        window.title = "Macros — \(appName)\(macro)"
    }

    @objc func toggleRecordStep() { toggleRecording(shortcut: false) }
    @objc func toggleRecordShortcut() { toggleRecording(shortcut: true) }

    /// Captures the next key combination pressed, either as a new step or as the macro's own shortcut.
    /// For a step every key counts (Esc and Enter included), so it is cancelled with the button.
    func toggleRecording(shortcut: Bool) {
        let cancelling = recordMonitor != nil && recordingShortcut == shortcut
        stopRecordingStep()
        status.stringValue = ""
        if cancelling { return }
        guard current != nil else { status.stringValue = "Create or select a macro first."; NSSound.beep(); return }
        recordingShortcut = shortcut
        if shortcut { shortcutButton.title = "Press shortcut… (Esc cancels)" } else { recordButton.title = "Cancel Recording" }
        status.stringValue = shortcut ? "Press the shortcut that should run this macro." : "Press the key combination to add as a step."
        window.makeFirstResponder(nil)
        recordMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [unowned self] event in
            guard self.window.isKeyWindow, let index = self.current else { return event }
            func refuse(_ message: String) -> NSEvent? { NSSound.beep(); self.status.stringValue = message; return nil }
            if shortcut, event.keyCode == 53 { self.stopRecordingStep(); self.status.stringValue = ""; return nil }
            guard let text = comboSpelling(keyCode: event.keyCode, flags: event.modifierFlags) else {
                return refuse("That key can't be used. Try another, or cancel.")
            }
            if shortcut {
                let flags = event.modifierFlags
                let isFunctionKey = text.hasPrefix("F") && Int(text.dropFirst()) != nil
                guard flags.contains(.command) || flags.contains(.option) || flags.contains(.control) || isFunctionKey else {
                    return refuse("A macro shortcut needs ⌘, ⌥ or ⌃, or a function key.")
                }
                if let key = carbonHotKey(text), key.code == self.app.hotKey.code, key.modifiers == self.app.hotKey.modifiers {
                    return refuse("That is Keyseek's own hotkey.")
                }
                if let other = self.macros.enumerated().first(where: { $0.offset != index && $0.element.shortcut == text }) {
                    return refuse("Already the shortcut for “\(other.element.name)”.")
                }
                self.macros[index].shortcut = text
                self.stopRecordingStep()
                self.shortcutChanged()
            } else {
                self.stopRecordingStep()
                self.macros[index].steps.append(text)
                self.stepsChanged(select: self.macros[index].steps.count - 1)
            }
            return nil
        }
    }

    func stopRecordingStep() {
        if let recordMonitor { NSEvent.removeMonitor(recordMonitor) }
        recordMonitor = nil
        recordButton.title = "Record Keys"
        updateShortcutButton()
    }

    func updateShortcutButton() {
        shortcutButton.title = current.flatMap { macros[$0].shortcut }.map { parseCombo($0).display } ?? "Record Shortcut"
    }

    func shortcutChanged() {
        updateShortcutButton()
        if let index = current { macroTable.reloadData(forRowIndexes: [index], columnIndexes: [2]) }
        save()
    }

    @objc func clearShortcut() {
        guard let index = current, macros[index].shortcut != nil else { return }
        stopRecordingStep()
        macros[index].shortcut = nil
        shortcutChanged()
    }

    @objc func showHelp(_ sender: NSButton) {
        let label = NSTextField(wrappingLabelWithString: """
        A step is one of three things:

        Command name. Exactly as shown in the Commands list, for example: Insert Audio Track. Double-clicking a command in the list adds it for you.

        Key combination. Modifiers written as Cmd, Shift, Option, Ctrl, followed by one key, with no spaces: CmdShiftT, OptionU, C. Named keys are Space, Tab, Enter, Delete, Esc, Home, End, F1 to F12, Left Arrow, Right Arrow, Up Arrow, Down Arrow (for example: Cmd Left Arrow). Record Keys writes this for you.

        Pause. The word wait and a number of seconds, up to 30: wait 0.5

        Steps run top to bottom, 0.15 seconds apart. Add a pause when the app needs longer, for example after a step that opens a dialog. A step shown in red was not found in the app's current commands.
        """)
        label.font = .systemFont(ofSize: 12)
        label.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(label)
        NSLayoutConstraint.activate([
            label.widthAnchor.constraint(equalToConstant: 380),
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            label.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
        let controller = NSViewController()
        controller.view = content
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    func windowWillClose(_ notification: Notification) {
        stopRecordingStep()
        app.updateActivationPolicy(closing: window)
    }

    @objc func removeStep() {
        guard let index = current, stepTable.selectedRow >= 0, stepTable.selectedRow < macros[index].steps.count else { NSSound.beep(); return }
        let row = stepTable.selectedRow
        macros[index].steps.remove(at: row)
        stepsChanged(select: row)
    }

    @objc func moveStepUp() { moveStep(by: -1) }
    @objc func moveStepDown() { moveStep(by: 1) }

    func moveStep(by offset: Int) {
        guard let index = current else { return }
        let row = stepTable.selectedRow, destination = row + offset
        guard row >= 0, destination >= 0, destination < macros[index].steps.count else { NSSound.beep(); return }
        macros[index].steps.swapAt(row, destination)
        stepsChanged(select: destination)
    }

    // MARK: Table and text plumbing

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === searchField {
            filtered = search(commands, searchField.stringValue)
            commandTable.reloadData()
        } else if field === titleField, let index = current {
            macros[index].name = titleField.stringValue.replacingOccurrences(of: "\n", with: " ")
            macroTable.reloadData(forRowIndexes: [index], columnIndexes: [0])
            updateTitle()
            save()
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === macroTable { return macros.count }
        if tableView === commandTable { return filtered.count }
        return current.map { macros[$0].steps.count } ?? 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let column = tableColumn?.identifier.rawValue
        if tableView === macroTable {
            if column == "Name" { return textCell(tableView, macros[row].name) }
            if column == "Steps" { return textCell(tableView, "\(macros[row].steps.count)") }
            return textCell(tableView, macros[row].shortcut.map { parseCombo($0).display } ?? "", color: .secondaryLabelColor)
        }
        if tableView === commandTable {
            let item = filtered[row]
            if column == "Command" { return textCell(tableView, item.title) }
            return textCell(tableView, item.keys.isEmpty ? item.category : "\(item.keys)   \(item.category)", color: .secondaryLabelColor)
        }
        guard let index = current, row < macros[index].steps.count else { return nil }
        let step = macros[index].steps[row]
        let found = stepResolves(step, titles: titles)
        return textCell(tableView, found ? "\(row + 1).  \(step)" : "\(row + 1).  \(step)   (not found)", color: found ? .labelColor : .systemRed)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if (notification.object as? NSTableView) === macroTable { showCurrent() }
    }
}

final class SettingsController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    let appsTable = NSTableView()
    var appButtonRow: NSView?
    var apps: [(id: String, name: String, count: Int)] = []

    unowned let app: AppDelegate
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 160),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
    let recordButton = NSButton(title: "", target: nil, action: nil)
    let note = NSTextField(labelWithString: "")
    var monitor: Any?

    init(app: AppDelegate) {
        self.app = app
        super.init()
        window.title = "Keyseek Settings"
        window.isReleasedWhenClosed = false
        window.delegate = self

        recordButton.bezelStyle = .rounded
        recordButton.target = self
        recordButton.action = #selector(toggleRecording)
        recordButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 170).isActive = true
        let reset = NSButton(title: "Reset", target: self, action: #selector(resetHotKey))
        let row = NSStackView(views: [NSTextField(labelWithString: "Show or hide the search panel:"), recordButton, reset])
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        let names = NSButton(checkboxWithTitle: "Show modifier keys as names (Cmd, Shift) instead of symbols",
                             target: self, action: #selector(toggleNames(_:)))
        names.state = UserDefaults.standard.bool(forKey: "modifierNames") ? .on : .off

        let login = NSButton(checkboxWithTitle: "Open Keyseek at login", target: self, action: #selector(toggleLogin(_:)))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        let appsHeading = NSTextField(labelWithString: "Apps with macros")
        appsHeading.font = .boldSystemFont(ofSize: 12)
        let appsScroll = configureTable(appsTable, columns: [("App", 330), ("Macros", 80)], owner: self)
        appsScroll.heightAnchor.constraint(equalToConstant: 130).isActive = true
        appsScroll.widthAnchor.constraint(equalToConstant: 440).isActive = true
        appsTable.target = self
        appsTable.doubleAction = #selector(editAppMacros)
        appsTable.rowHeight = 26
        let appButtons = NSStackView(views: [makeButton("Edit Macros…", self, #selector(editAppMacros)),
                                             makeButton("Show in Finder", self, #selector(revealAppMacros)),
                                             makeButton("Delete…", self, #selector(deleteAppMacros))])
        appButtonRow = appButtons
        let stack = NSStackView(views: [row, note, names, login, appsHeading, appsScroll, appButtons])
        stack.detachesHiddenViews = false // the buttons keep their space while hidden, so the window does not jump
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 22, bottom: 22, right: 22)
        window.contentView = stack
        window.setContentSize(NSSize(width: max(480, stack.fittingSize.width), height: stack.fittingSize.height))
        refresh()
    }

    func reloadApps() {
        let folder = macrosURL("x").deletingLastPathComponent()
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        apps = files.filter { $0.pathExtension == "txt" }.compactMap { url in
            let count = loadMacros(url).count
            let id = url.deletingPathExtension().lastPathComponent
            return count > 0 ? (id, appDisplayName(id), count) : nil
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        appsTable.reloadData()
        appButtonRow?.isHidden = selectedApp == nil
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        appButtonRow?.isHidden = selectedApp == nil
    }

    var selectedApp: (id: String, name: String, count: Int)? {
        appsTable.selectedRow >= 0 && appsTable.selectedRow < apps.count ? apps[appsTable.selectedRow] : nil
    }

    @objc func editAppMacros() {
        guard let selected = selectedApp else { NSSound.beep(); return }
        app.macroEditor.open(bundleID: selected.id, appName: selected.name)
    }

    @objc func revealAppMacros() {
        guard let selected = selectedApp else { NSSound.beep(); return }
        NSWorkspace.shared.activateFileViewerSelecting([macrosURL(selected.id)])
    }

    @objc func deleteAppMacros() {
        guard let selected = selectedApp else { NSSound.beep(); return }
        let alert = NSAlert()
        alert.messageText = "Delete all macros for \(selected.name)?"
        alert.informativeText = "\(selected.count) macro\(selected.count == 1 ? "" : "s") will be moved to the Trash."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if app.macroEditor.bundleID == selected.id { app.macroEditor.window.close() }
        try? FileManager.default.trashItem(at: macrosURL(selected.id), resultingItemURL: nil)
        reloadApps()
    }

    func windowDidBecomeKey(_ notification: Notification) { reloadApps() }

    func numberOfRows(in tableView: NSTableView) -> Int { apps.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard tableColumn?.identifier.rawValue == "App" else { return textCell(tableView, "\(apps[row].count)") }
        let id = NSUserInterfaceItemIdentifier("app")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = id
            let image = NSImageView()
            let field = NSTextField(labelWithString: "")
            field.lineBreakMode = .byTruncatingTail
            for view in [image, field] as [NSView] {
                view.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(view)
            }
            cell.imageView = image
            cell.textField = field
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 20),
                image.heightAnchor.constraint(equalToConstant: 20),
                field.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 7),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -3),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        cell.textField?.stringValue = apps[row].name
        cell.imageView?.image = NSWorkspace.shared.urlForApplication(withBundleIdentifier: apps[row].id)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)
        return cell
    }

    func show() {
        refresh()
        reloadApps()
        NSApp.activate(ignoringOtherApps: true)
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        app.updateActivationPolicy()
    }

    func refresh(_ message: String? = nil) {
        recordButton.title = monitor == nil ? app.hotKeyLabel : "Press new shortcut…"
        note.stringValue = message ?? "Click the shortcut, then press the new combination. Esc cancels."
    }

    @objc func toggleRecording() {
        if monitor != nil { stopRecording(); return }
        app.unregisterHotKey() // so the current hotkey can be pressed again without toggling the panel
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [unowned self] event in
            if event.keyCode == 53 { self.stopRecording(); return nil }
            let flags = event.modifierFlags
            let name = virtualKeyNames[Int(event.keyCode)] ?? ""
            let isFunctionKey = name.count > 1 && name.hasPrefix("F")
            guard flags.contains(.command) || flags.contains(.option) || flags.contains(.control) || isFunctionKey else {
                NSSound.beep()
                self.refresh("Include ⌘, ⌥ or ⌃ in the combination, or use a function key.")
                return nil
            }
            var carbon = 0
            if flags.contains(.command) { carbon |= cmdKey }
            if flags.contains(.option) { carbon |= optionKey }
            if flags.contains(.control) { carbon |= controlKey }
            if flags.contains(.shift) { carbon |= shiftKey }
            UserDefaults.standard.set(Int(event.keyCode), forKey: "hotKeyCode")
            UserDefaults.standard.set(carbon, forKey: "hotKeyModifiers")
            self.stopRecording()
            return nil
        }
        refresh()
    }

    func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        let ok = app.registerHotKey()
        app.rebuildStatusMenu()
        refresh(ok ? nil : "macOS refused that combination (another app may own it). Pick a different one.")
    }

    @objc func resetHotKey() {
        UserDefaults.standard.removeObject(forKey: "hotKeyCode")
        UserDefaults.standard.removeObject(forKey: "hotKeyModifiers")
        stopRecording()
    }

    @objc func toggleLogin(_ sender: NSButton) {
        do {
            if sender.state == .on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            refresh()
        } catch {
            sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
            refresh("Could not change the login item: \(error.localizedDescription)")
        }
    }

    @objc func toggleNames(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "modifierNames")
    }

    func windowWillClose(_ notification: Notification) {
        if monitor != nil { stopRecording() }
        app.updateActivationPolicy(closing: window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate,
                         NSTextFieldDelegate, NSWindowDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var panel: SearchPanel!
    let field = NSTextField()
    let table = NSTableView()
    let footer = NSTextField(labelWithString: "")
    var hotKeyRef: EventHotKeyRef?
    var hotKeyLabel = "⌃⌥Space"
    var handlerInstalled = false
    lazy var settings = SettingsController(app: self)
    lazy var macroEditor = MacroEditor(app: self)

    var allItems: [Item] = []
    var shown: [Item] = []
    var target: NSRunningApplication?
    var menuCache: [pid_t: [Item]] = [:]
    var macroDefs: [MacroDef] = []
    var macroHotKeyRefs: [EventHotKeyRef] = []
    var hotKeyMacros: [MacroDef] = []
    var hotKeyBundleID = ""
    var macroRunning = false
    var generation = 0

    // MARK: Setup

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Keyseek")
        let menu = NSMenu()
        menu.delegate = self // rebuilt on open, so "Edit Macros for …" names the app in front
        statusItem.menu = menu
        registerHotKey()
        rebuildStatusMenu()
        buildPanel()
        buildMainMenu()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(frontAppChanged(_:)),
                                                          name: NSWorkspace.didActivateApplicationNotification, object: nil)
        refreshMacroHotKeys(for: NSWorkspace.shared.frontmostApplication)
        if !AXIsProcessTrusted() { promptForAccessibility() }
    }

    func menuNeedsUpdate(_ menu: NSMenu) { rebuildStatusMenu() }

    /// Keyseek lives in the menu bar, but while Settings or the macro editor is open it becomes a
    /// regular app with a Dock icon, so those windows can be found again with the Dock or Cmd-Tab.
    func updateActivationPolicy(closing: NSWindow? = nil) {
        let open = [settings.window, macroEditor.window].contains { $0 !== closing && $0.isVisible }
        let wanted: NSApplication.ActivationPolicy = open ? .regular : .accessory
        if NSApp.activationPolicy() != wanted { NSApp.setActivationPolicy(wanted) }
        if open { NSApp.activate(ignoringOtherApps: true) }
    }

    /// The menu bar shown while Keyseek is a regular app; also what makes Cmd-C/V/W work in its windows.
    func buildMainMenu() {
        let main = NSMenu()
        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem()
            let menu = NSMenu(title: title)
            item.submenu = menu
            main.addItem(item)
            return menu
        }
        let appMenu = submenu("Keyseek")
        appMenu.addItem(withTitle: "About Keyseek", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Keyseek", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Keyseek", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = submenu("Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let windowMenu = submenu("Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }

    @objc func editMacros(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String], info.count == 2 else { return }
        macroEditor.open(bundleID: info[0], appName: info[1])
    }

    func rebuildStatusMenu() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()
        menu.addItem(withTitle: "Search Shortcuts   \(hotKeyLabel)", action: #selector(toggle), keyEquivalent: "").target = self
        menu.addItem(.separator())
        if AXIsProcessTrusted() {
            menu.addItem(withTitle: "Accessibility access: granted", action: nil, keyEquivalent: "")
        } else {
            menu.addItem(withTitle: "Grant Accessibility Access…", action: #selector(promptForAccessibility), keyEquivalent: "").target = self
        }
        if let front = NSWorkspace.shared.frontmostApplication, let bundleID = front.bundleIdentifier,
           front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            let name = front.localizedName ?? bundleID
            let item = menu.addItem(withTitle: "Edit Macros for \(name)…", action: #selector(editMacros(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = [bundleID, name]
        }
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Keyseek", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc func promptForAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// The global hotkey, ⌃⌥Space unless changed in Settings.
    var hotKey: (code: UInt32, modifiers: UInt32) {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "hotKeyCode") != nil else { return (UInt32(kVK_Space), UInt32(controlKey | optionKey)) }
        return (UInt32(defaults.integer(forKey: "hotKeyCode")), UInt32(defaults.integer(forKey: "hotKeyModifiers")))
    }

    @discardableResult
    func registerHotKey() -> Bool {
        if !handlerInstalled {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var pressed = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                  MemoryLayout<EventHotKeyID>.size, nil, &pressed)
                let number = Int(pressed.id)
                DispatchQueue.main.async {
                    guard let delegate = NSApp.delegate as? AppDelegate else { return }
                    if number == 1 { delegate.toggle() } else { delegate.runMacroHotKey(number - 100) }
                }
                return noErr
            }, 1, &spec, nil, nil)
            handlerInstalled = true
        }
        unregisterHotKey()
        let key = hotKey
        hotKeyLabel = hotKeyDescription(key.code, key.modifiers)
        let id = EventHotKeyID(signature: OSType(0x4B53454B), id: 1)
        let ok = RegisterEventHotKey(key.code, key.modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef) == noErr
        if !ok { hotKeyRef = nil }
        return ok
    }

    func unregisterHotKey() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    @objc func showSettings() { settings.show() }

    @objc func frontAppChanged(_ notification: Notification) {
        refreshMacroHotKeys(for: notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
    }

    /// Macro shortcuts only exist while their app is in front, so they never shadow keys elsewhere.
    func refreshMacroHotKeys(for front: NSRunningApplication?) {
        for ref in macroHotKeyRefs { UnregisterEventHotKey(ref) }
        macroHotKeyRefs = []
        hotKeyMacros = []
        hotKeyBundleID = ""
        guard let front, let bundleID = front.bundleIdentifier,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        hotKeyBundleID = bundleID
        for macro in loadMacros(macrosURL(bundleID)) {
            guard let spelling = macro.shortcut, let key = carbonHotKey(spelling) else { continue }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x4B53454B), id: UInt32(100 + hotKeyMacros.count))
            if RegisterEventHotKey(key.code, key.modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
                macroHotKeyRefs.append(ref)
                hotKeyMacros.append(macro)
            }
        }
        // Read the app's menus now, so the first shortcut press does not have to wait for it.
        let pid = front.processIdentifier
        guard !hotKeyMacros.isEmpty, menuCache[pid] == nil, AXIsProcessTrusted() else { return }
        DispatchQueue.global(qos: .utility).async {
            let menus = scanMenus(pid: pid)
            DispatchQueue.main.async { if !menus.isEmpty { self.menuCache = [pid: menus] } }
        }
    }

    func runMacroHotKey(_ index: Int) {
        guard index >= 0, index < hotKeyMacros.count, !macroRunning,
              let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier == hotKeyBundleID else { return }
        guard AXIsProcessTrusted() else { promptForAccessibility(); return }
        let macro = hotKeyMacros[index]
        let pid = front.processIdentifier
        let reference = Bundle.main.url(forResource: hotKeyBundleID, withExtension: "txt").map(loadShortcutFile) ?? []
        func resolve(_ menus: [Item]) -> [Step]? {
            if case .macro(let steps)? = buildMacroItems([macro], reference: reference, menus: menus).first?.action { return steps }
            return nil
        }
        if let steps = resolve(menuCache[pid] ?? []) { run(steps); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let menus = scanMenus(pid: pid)
            DispatchQueue.main.async {
                if !menus.isEmpty { self.menuCache = [pid: menus] }
                if let steps = resolve(menus) { self.run(steps) } else { NSSound.beep() }
            }
        }
    }

    func buildPanel() {
        let size = NSSize(width: 700, height: 460)
        panel = SearchPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.delegate = self
        panel.appearance = NSAppearance(named: .darkAqua)

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.masksToBounds = true
        panel.contentView = background

        field.frame = NSRect(x: 18, y: size.height - 50, width: size.width - 36, height: 32)
        field.font = .systemFont(ofSize: 22, weight: .regular)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.autoresizingMask = [.width, .minYMargin]
        background.addSubview(field)

        let separator = NSBox(frame: NSRect(x: 0, y: size.height - 61, width: size.width, height: 1))
        separator.boxType = .separator
        background.addSubview(separator)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        column.resizingMask = .autoresizingMask
        column.width = size.width - 40 // the default 100pt column squeezed every row
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 42
        table.style = .inset
        table.backgroundColor = .clear
        table.refusesFirstResponder = true
        table.allowsEmptySelection = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(runSelected)

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 28, width: size.width, height: size.height - 90))
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        background.addSubview(scroll)

        footer.frame = NSRect(x: 18, y: 7, width: size.width - 36, height: 16)
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .secondaryLabelColor
        background.addSubview(footer)
    }

    // MARK: Showing and hiding

    @objc func toggle() {
        if panel.isVisible { hide() } else { show() }
    }

    func show() {
        let front = NSWorkspace.shared.frontmostApplication
        target = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        rebuildStatusMenu()

        var reference: [Item] = []
        if let bundleID = target?.bundleIdentifier,
           let url = Bundle.main.url(forResource: bundleID, withExtension: "txt") {
            reference = loadShortcutFile(url)
        }
        macroDefs = (target?.bundleIdentifier).map { loadMacros(macrosURL($0)) } ?? []
        field.stringValue = ""
        field.placeholderString = "Search \(target?.localizedName ?? "app") shortcuts and commands…"
        merge(reference: reference, menus: target.flatMap { menuCache[$0.processIdentifier] } ?? [])

        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let area = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: area.midX - panel.frame.width / 2,
                                         y: area.minY + area.height * 0.62 - panel.frame.height / 2))
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)

        // Refresh the app's menu commands in the background; they change with context.
        guard let pid = target?.processIdentifier, AXIsProcessTrusted() else { return }
        generation += 1
        let expected = generation
        DispatchQueue.global(qos: .userInitiated).async {
            let menus = scanMenus(pid: pid)
            DispatchQueue.main.async {
                guard expected == self.generation, self.panel.isVisible else { return }
                self.menuCache = [pid: menus]
                self.merge(reference: reference, menus: menus)
            }
        }
    }

    func merge(reference: [Item], menus: [Item]) {
        let menuTitles = Set(menus.map(\.foldedTitle))
        allItems = buildMacroItems(macroDefs, reference: reference, menus: menus)
            + menus + reference.filter { !menuTitles.contains($0.foldedTitle) }
        refilter()
    }

    func hide() {
        generation += 1
        panel.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        if panel.isVisible { hide() }
    }

    // MARK: Search and list

    func refilter() {
        let selectedTitle = table.selectedRow >= 0 && table.selectedRow < shown.count ? shown[table.selectedRow].title : nil
        let keepSelection = !field.stringValue.isEmpty
        shown = search(allItems, field.stringValue)
        table.reloadData()
        var row = 0
        if keepSelection, let selectedTitle, let index = shown.firstIndex(where: { $0.title == selectedTitle }) { row = index }
        select(row)
    }

    func select(_ row: Int) {
        guard !shown.isEmpty else { updateFooter(); return }
        let row = max(0, min(shown.count - 1, row))
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
        updateFooter()
    }

    func updateFooter() {
        var hint = "No matches"
        if table.selectedRow >= 0, table.selectedRow < shown.count {
            let item = shown[table.selectedRow]
            switch item.action {
            case .menu: hint = item.enabled ? "↩ run menu command" : "unavailable right now"
            case .keystroke: hint = "↩ send keystroke"
            case .macro(let steps): hint = "↩ run macro (\(steps.count) steps)"
            case .none: hint = item.enabled ? "reference only" : "unavailable"
            }
        }
        var text = "\(hint)   ·   ↑↓ select   ·   esc close   ·   \(shown.count) of \(allItems.count)"
        if !AXIsProcessTrusted() { text += "   ·   grant Accessibility access to list and run commands" }
        footer.stringValue = text
    }

    func controlTextDidChange(_ obj: Notification) { refilter() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): select(table.selectedRow + 1)
        case #selector(NSResponder.moveUp(_:)): select(table.selectedRow - 1)
        case #selector(NSResponder.scrollPageDown(_:)), #selector(NSResponder.pageDown(_:)): select(table.selectedRow + 9)
        case #selector(NSResponder.scrollPageUp(_:)), #selector(NSResponder.pageUp(_:)): select(table.selectedRow - 9)
        case #selector(NSResponder.insertNewline(_:)): runSelected()
        case #selector(NSResponder.cancelOperation(_:)): hide()
        default: return false
        }
        return true
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { RowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? ItemCell ?? ItemCell(frame: .zero)
        cell.identifier = id
        let item = shown[row]
        cell.title.stringValue = item.title
        cell.subtitle.stringValue = item.category
        cell.keys.set(item.keys, dimmed: !item.enabled)
        cell.title.textColor = item.enabled ? .labelColor : .tertiaryLabelColor
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateFooter() }

    // MARK: Running

    @objc func runSelected() {
        guard table.selectedRow >= 0, table.selectedRow < shown.count else { return }
        let item = shown[table.selectedRow]
        var steps: [Step] = []
        switch item.action {
        case .none: break
        case .menu(let element): steps = [.menu(element)]
        case .keystroke(let code, let flags): steps = [.keystroke(code, flags)]
        case .macro(let macroSteps): steps = macroSteps
        }
        guard item.enabled, !steps.isEmpty else { NSSound.beep(); return }
        guard AXIsProcessTrusted() else { hide(); promptForAccessibility(); return }
        hide()
        run(steps)
    }

    func run(_ steps: [Step]) {
        guard !macroRunning else { return } // also stops a macro from re-triggering itself through its own shortcut
        macroRunning = true
        DispatchQueue.global(qos: .userInitiated).async {
            // Give the app a moment to take keyboard focus back, and to settle between steps.
            for step in steps {
                Thread.sleep(forTimeInterval: 0.15)
                switch step {
                case .wait(let seconds):
                    Thread.sleep(forTimeInterval: max(0, min(seconds, 30)))
                case .menu(let element):
                    AXUIElementPerformAction(element, kAXPressAction as CFString)
                case .keystroke(let code, let flags):
                    let source = CGEventSource(stateID: .combinedSessionState)
                    for down in [true, false] {
                        let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
                        event?.flags = flags
                        event?.post(tap: .cghidEventTap)
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.macroRunning = false }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
