import Foundation

/// Security validators and POSIX shell quoting helpers for Android ADB commands.
public enum AndroidCommandSanitizer {
    /// Validates an ADB device serial or `host:port` target to prevent flag injection or malformed endpoints.
    public static func validateSerial(_ serial: String) -> Bool {
        let trimmed = serial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 128, !trimmed.hasPrefix("-") else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-[]")
        return trimmed.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// Validates an Android application package name (e.g. `com.whatsapp`) to prevent shell injection.
    public static func validatePackageName(_ packageName: String) -> Bool {
        let trimmed = packageName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 255, !trimmed.hasPrefix("-"), !trimmed.hasPrefix("."), !trimmed.hasSuffix(".") else {
            return false
        }
        guard trimmed.contains(".") else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._")
        return trimmed.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// Validates a `host:port` TCP/TLS endpoint for `adb connect` / `adb pair`.
    public static func validateTargetEndpoint(_ endpoint: String) -> Bool {
        guard validateSerial(endpoint) else { return false }
        let parts = endpoint.split(separator: ":")
        guard parts.count == 2, let port = Int(parts[1]), (1...65535).contains(port) else { return false }
        return !parts[0].isEmpty
    }

    /// Safely single-quotes an arbitrary string for POSIX `/system/bin/sh` (Android `adb shell`),
    /// stripping NUL bytes so no metacharacter (`;`, `|`, `&`, `$()`, backticks, redirects) can execute.
    public static func shellQuote(_ value: String) -> String {
        let sanitized = value.replacingOccurrences(of: "\0", with: "")
        return "'" + sanitized.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Builds injection-safe `adb shell` text arguments for `android_type_text`.
    /// Both ASCII (`input text`) and Unicode (`cmd clipboard set text`) paths are strictly POSIX single-quoted
    /// so Android `/system/bin/sh` never evaluates `;`, `|`, `&`, `$()`, backticks, redirects, or newlines.
    public static func buildSafeTypeTextCommand(_ rawText: String) -> (useClipboard: Bool, quotedArg: String) {
        let sanitized = rawText.replacingOccurrences(of: "\0", with: "")
        let isSimpleASCII = sanitized.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && scalar.value >= 0x20 && scalar.value != 0x7F
        }
        if isSimpleASCII {
            let spaceEncoded = sanitized.replacingOccurrences(of: " ", with: "%s")
            return (false, shellQuote(spaceEncoded))
        } else {
            return (true, shellQuote(sanitized))
        }
    }
}
