import Carbon
import CoreFoundation
import Foundation

// Queries the current macOS keyboard layout via the Carbon framework
// and outputs JSON mapping key codes -> characters for each modifier state.
// Works with ANY keyboard layout the user has active (US, Dvorak, ABC, etc.)

func getKeyboardLayoutData() -> [String: Any] {
    guard let rawSource = TISCopyCurrentKeyboardInputSource() else {
        return ["error": "No keyboard input source"]
    }
    let inputSource = rawSource.takeRetainedValue()

    // Get the Unicode keyboard layout data
    let layoutDataPtr = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData)
    guard let layoutDataPtr = layoutDataPtr else {
        return ["error": "No Unicode layout data (possibly a raw ASCII layout)"]
    }
    let layoutData = Unmanaged<CFData>.fromOpaque(layoutDataPtr).takeUnretainedValue()
    let rawPtr = CFDataGetBytePtr(layoutData)!
    let keyboardLayout = rawPtr.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { $0 }

    let kbdType = LMGetKbdType()

    // Get layout name
    let namePtr = TISGetInputSourceProperty(inputSource, kTISPropertyInputSourceID)
    let layoutID = namePtr != nil
        ? Unmanaged<CFString>.fromOpaque(namePtr!).takeUnretainedValue() as String
        : "unknown"

    // Also get localized name
    let localNamePtr = TISGetInputSourceProperty(inputSource, kTISPropertyLocalizedName)
    let localName = localNamePtr != nil
        ? Unmanaged<CFString>.fromOpaque(localNamePtr!).takeUnretainedValue() as String
        : layoutID

    // Key codes for all standard keys (0-50 covers main keyboard area)
    let keyCodes = Array(0...50) + [53, 65, 67, 69, 71, 75, 76, 78, 81, 82, 83, 84, 85, 86, 87, 88, 89, 90, 91, 123, 124, 125, 126]

    // Modifier states to query
    // Bits: 0=caps(alpha), 1=shift, 2=control, 3=option, 4=command
    let modifierStates: [(String, UInt32)] = [
        ("none", 0),
        ("shift", 1 << 1),
        ("option", 1 << 3),
        ("shift_option", (1 << 1) | (1 << 3)),
        ("caps", 1 << 0),
        ("caps_shift", (1 << 0) | (1 << 1)),
        ("ctrl", 1 << 2),
        ("ctrl_shift", (1 << 2) | (1 << 1)),
        ("ctrl_option", (1 << 2) | (1 << 3)),
        ("ctrl_shift_option", (1 << 2) | (1 << 1) | (1 << 3)),
    ]

    var result: [String: Any] = [:]

    for (modName, modState) in modifierStates {
        var keyMap: [String: String] = [:]
        for keyCode in keyCodes {
            var deadKeyState: UInt32 = 0
            var actualLength: Int = 0
            var unicodeString = [UniChar](repeating: 0, count: 8)

            let status = UCKeyTranslate(
                keyboardLayout,
                UInt16(keyCode),
                UInt16(kUCKeyActionDisplay),
                modState,
                UInt32(kbdType),
                0,
                &deadKeyState,
                8,
                &actualLength,
                &unicodeString
            )

            if status == 0 && actualLength > 0 {
                let str = String(utf16CodeUnits: unicodeString, count: actualLength)
                keyMap[String(keyCode)] = str
            }
        }
        result[modName] = keyMap
    }

    return [
        "layout_id": layoutID,
        "layout_name": localName,
        "keys": result,
    ]
}

let data = getKeyboardLayoutData()
if let jsonData = try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]) {
    print(String(data: jsonData, encoding: .utf8) ?? "{}")
}
