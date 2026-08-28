import Foundation

/// Provider strings are diagnostics and labels, not an unbounded transport for text.
/// Keep the boundary here so live decoders and restored snapshots apply the same rule.
enum ProviderMetadataText {
    static let maximumUTF8Bytes = 512
    static let maximumIdentifierUTF8Bytes = 128

    private static let forbiddenBidirectionalScalars: Set<UInt32> = [
        0x061C, 0x200E, 0x200F,
        0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
        0x2066, 0x2067, 0x2068, 0x2069,
    ]

    static func normalizedDisplay(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= maximumUTF8Bytes,
              !containsUnsafeScalar(trimmed) else { return nil }
        return trimmed
    }

    static func isSafeDisplay(_ value: String?) -> Bool {
        guard let value else { return true }
        return normalizedDisplay(value) == value
    }

    static func identifier(_ value: Any?, default defaultValue: String) throws -> String {
        guard let value, !(value is NSNull) else { return defaultValue }
        guard let value = value as? String,
              isSafeIdentifier(value) else {
            throw UsageError.schemaChanged("Codex limitId must be a safe identifier")
        }
        return value
    }

    static func isSafeIdentifier(_ value: String?) -> Bool {
        guard let value,
              !value.isEmpty,
              value.utf8.count <= maximumIdentifierUTF8Bytes else { return false }
        return value.utf8.allSatisfy { byte in
            switch byte {
            case 48...57, 65...90, 97...122, 45, 46, 95:
                true
            default:
                false
            }
        }
    }

    private static func containsUnsafeScalar(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            CharacterSet.controlCharacters.contains(scalar)
                || CharacterSet.illegalCharacters.contains(scalar)
                || forbiddenBidirectionalScalars.contains(scalar.value)
        }
    }
}
