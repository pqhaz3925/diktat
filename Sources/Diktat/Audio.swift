import AVFoundation
import CoreMedia

/// Microphone → 16 kHz mono s16le chunks.
final class MicCapture {
    private let engine = AVAudioEngine()
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    var onChunk: ((Data) -> Void)?
    var onLevel: ((Float) -> Void)?

    static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func start() throws {
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, let converter = AVAudioConverter(from: inFormat, to: target) else {
            throw NSError(domain: "Diktat", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone input available"])
        }
        let ratio = target.sampleRate / inFormat.sampleRate
        input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: self.target, frameCapacity: cap) else { return }
            var fed = false
            var err: NSError?
            converter.convert(to: out, error: &err) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            let n = Int(out.frameLength)
            guard n > 0, let ch = out.int16ChannelData?[0] else { return }
            var sum: Float = 0
            for i in 0..<n { let v = Float(ch[i]) / 32768; sum += v * v }
            self.onLevel?(min(1, sqrt(sum / Float(n)) * 4))
            self.onChunk?(Data(bytes: ch, count: n * 2))
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

/// Any audio/video file → 16 kHz mono s16le. AVFoundation first, ffmpeg as fallback (ogg/opus, webm, …).
enum AudioDecoder {
    static func pcm16k(_ url: URL) async throws -> Data {
        do {
            return try await viaAVFoundation(url)
        } catch {
            if let ff = ffmpegPath() { return try viaFFmpeg(ff, url) }
            throw error
        }
    }

    private static func viaAVFoundation(_ url: URL) async throws -> Data {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw NSError(domain: "Diktat", code: 2, userInfo: [NSLocalizedDescriptionKey: "No audio track in file"])
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? NSError(domain: "Diktat", code: 3) }
        var pcm = Data()
        while let sb = output.copyNextSampleBuffer() {
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
            let len = CMBlockBufferGetDataLength(bb)
            var chunk = Data(count: len)
            chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: $0.baseAddress!) }
            pcm.append(chunk)
        }
        if reader.status == .failed { throw reader.error ?? NSError(domain: "Diktat", code: 4) }
        return pcm
    }

    private static func ffmpegPath() -> String? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func viaFFmpeg(_ ff: String, _ url: URL) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ff)
        p.arguments = ["-hide_banner", "-loglevel", "error", "-nostdin", "-i", url.path,
                       "-vn", "-ac", "1", "-ar", "16000", "-f", "s16le", "-acodec", "pcm_s16le", "pipe:1"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0, !data.isEmpty else {
            throw NSError(domain: "Diktat", code: 5, userInfo: [NSLocalizedDescriptionKey: "Could not decode audio"])
        }
        return data
    }
}
