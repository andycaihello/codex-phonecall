import Foundation

public enum ManagedAudioSegmentAction {
    case play(id: String, pcm: Data)
    case end(id: String)
}

public enum ManagedAudioSegmentError: Error {
    case invalidPCM
}

/// Keeps a continuous managed-voice PCM stream below the native per-item
/// limit. A segment boundary flushes the finite resampler tail; it does not
/// end the voice session or impose a total call duration.
public struct ManagedAudioSegmenter {
    public static let maxSegmentBytes = 120 * 24_000 * 2
    private var index = 0
    private var bytesInSegment = 0

    public init() {}

    public mutating func append(_ data: Data) throws -> [ManagedAudioSegmentAction] {
        guard data.count % 2 == 0 else { throw ManagedAudioSegmentError.invalidPCM }
        var actions: [ManagedAudioSegmentAction] = []
        var offset = 0
        while offset < data.count {
            let count = min(data.count - offset, Self.maxSegmentBytes - bytesInSegment)
            let id = "codex-webrtc-\(index)"
            actions.append(.play(id: id, pcm: data.subdata(in: offset..<(offset + count))))
            offset += count
            bytesInSegment += count
            if bytesInSegment == Self.maxSegmentBytes {
                actions.append(.end(id: id))
                index += 1
                bytesInSegment = 0
            }
        }
        return actions
    }

    /// The native clear removes the open item; the next audio belongs to a
    /// fresh identity even if the previous segment was only partly filled.
    public mutating func interrupt() {
        index += 1
        bytesInSegment = 0
    }
}
