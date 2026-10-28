import Foundation
import AVFoundation
import Speech

@main struct ModernCaptionDuplexChecks {
    @MainActor static func main() async throws {
        guard #available(macOS 26.0, *) else { return }
        let args = CommandLine.arguments
        func read(_ path: String, rate: Double) throws -> AVAudioPCMBuffer {
            let file = try AVAudioFile(forReading: URL(fileURLWithPath:path))
            let input = AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:AVAudioFrameCount(file.length))!
            try file.read(into:input)
            let format = AVAudioFormat(standardFormatWithSampleRate:rate,channels:1)!
            let converter = AVAudioConverter(from:input.format,to:format)!
            let out = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:AVAudioFrameCount(ceil(Double(input.frameLength)*rate/input.format.sampleRate))+64)!
            var sent=false;var error:NSError?
            _ = converter.convert(to:out,error:&error) { _,state in
                if sent {state.pointee = .endOfStream;return nil};sent=true;state.pointee = .haveData;return input
            }
            if let error {throw error};return out
        }
        let first=try read(args[1],rate:8000),second=try read(args[2],rate:48000)
        let a=ModernCaptionRecognition(), b=ModernCaptionRecognition()
        var firstText="",secondText="",failures:[String]=[]
        a.onTranscript={_,text,_ in firstText += text};b.onTranscript={_,text,_ in secondText += text}
        a.onFailure={failures.append($0)};b.onFailure={failures.append($0)}
        try await a.prepare(format:first.format);try await b.prepare(format:second.format)
        for index in 0..<80 {
            for (backend,audio) in [(a,first),(b,second)] {
                let count=Int(audio.format.sampleRate/10),offset=index*count
                let chunk=AVAudioPCMBuffer(pcmFormat:audio.format,frameCapacity:AVAudioFrameCount(count))!;chunk.frameLength=AVAudioFrameCount(count)
                let samples=chunk.floatChannelData![0];samples.initialize(repeating:0,count:count)
                if offset<Int(audio.frameLength) {samples.update(from:audio.floatChannelData![0].advanced(by:offset),count:min(count,Int(audio.frameLength)-offset))}
                try backend.append(chunk)
            }
            try await Task.sleep(nanoseconds:100_000_000)
        }
        print("first",firstText);print("second",secondText);print("failures",failures)
        print("first stats",a.snapshot);print("second stats",b.snapshot)
        precondition(failures.isEmpty && firstText.contains("吃药") && secondText.contains("提醒"),"both simultaneous decoders must recognize their own source")
        await a.stopAndWait();await b.stopAndWait()
        print("PASS independent 8k and 48k simultaneous local speech recognition; synthetic audio only")
    }
}
