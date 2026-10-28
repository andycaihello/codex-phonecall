import Foundation

/// A telephone destination only, never an AT dial string or menu sequence.
public enum PhoneNumber {
    public static func valid(_ number: String) -> Bool {
        let digits = number.hasPrefix("+") ? number.dropFirst() : number[...]
        return (3...15).contains(digits.utf8.count) && digits.utf8.allSatisfy { (48...57).contains($0) }
    }
}
