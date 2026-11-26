import AudioToolbox
import Foundation

/// Repackages Ogg Opus into CAF, which iOS 11+ plays natively. Packets are copied as-is (no re-encoding).
enum OpusRemux {
    static let extensions: Set<String> = ["opus", "ogg", "oga"]

    static func toCAF(_ source: URL, tags: [String: String]) -> URL? {
        guard let data = try? Data(contentsOf: source, options: .mappedIfSafe) else { return nil }
        let bytes = [UInt8](data)
        var packets: [[UInt8]] = []
        var current: [UInt8] = []
        var serial: UInt32?
        var pos = 0
        while pos + 27 <= bytes.count {
            guard bytes[pos] == 0x4F, bytes[pos + 1] == 0x67, bytes[pos + 2] == 0x67, bytes[pos + 3] == 0x53 else { return nil }
            let pageSerial = UInt32(bytes[pos + 14]) | UInt32(bytes[pos + 15]) << 8 | UInt32(bytes[pos + 16]) << 16 | UInt32(bytes[pos + 17]) << 24
            let segments = Int(bytes[pos + 26])
            var body = pos + 27 + segments
            guard body <= bytes.count else { break }
            let own = serial == nil || serial == pageSerial
            if serial == nil { serial = pageSerial }
            for i in 0..<segments {
                let length = Int(bytes[pos + 27 + i])
                guard body + length <= bytes.count else { break }
                if own { current.append(contentsOf: bytes[body..<body + length]) }
                body += length
                if length < 255 && own { packets.append(current); current = [] }
            }
            pos = body
        }
        guard packets.count > 2, packets[0].count >= 19, packets[0].starts(with: Array("OpusHead".utf8)) else { return nil }
        let head = packets[0]
        let channels = UInt32(head[9])
        let preSkip = UInt32(head[10]) | UInt32(head[11]) << 8
        guard channels == 1 || channels == 2, head.count < 19 || head[18] == 0 else { return nil }
        let audio = packets.dropFirst(2).filter { !$0.isEmpty }

        var format = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
                                                 mBytesPerPacket: 0, mFramesPerPacket: 0, mBytesPerFrame: 0,
                                                 mChannelsPerFrame: channels, mBitsPerChannel: 0, mReserved: 0)
        let target = source.deletingPathExtension().appendingPathExtension("caf")
        var file: AudioFileID?
        guard AudioFileCreateWithURL(target as CFURL, kAudioFileCAFType, &format, .eraseFile, &file) == noErr, let out = file else { return nil }
        var ok = true
        var payload: [UInt8] = []
        var descriptions: [AudioStreamPacketDescription] = []
        var totalFrames: Int64 = 0
        for packet in audio {
            let frames = frameCount(packet)
            descriptions.append(AudioStreamPacketDescription(mStartOffset: Int64(payload.count), mVariableFramesInPacket: frames,
                                                             mDataByteSize: UInt32(packet.count)))
            payload.append(contentsOf: packet)
            totalFrames += Int64(frames)
        }
        var count = UInt32(descriptions.count)
        ok = AudioFileWritePackets(out, false, UInt32(payload.count), descriptions, 0, &count, payload) == noErr
        var table = AudioFilePacketTableInfo(mNumberValidFrames: max(0, totalFrames - Int64(preSkip)), mPrimingFrames: Int32(preSkip), mRemainderFrames: 0)
        AudioFileSetProperty(out, kAudioFilePropertyPacketTableInfo, UInt32(MemoryLayout<AudioFilePacketTableInfo>.size), &table)
        var info = tags as CFDictionary
        AudioFileSetProperty(out, kAudioFilePropertyInfoDictionary, UInt32(MemoryLayout<CFDictionary>.size), &info)
        AudioFileClose(out)
        if !ok { try? FileManager.default.removeItem(at: target); return nil }
        return target
    }

    static func tags(_ url: URL) -> [String: String] {
        var file: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, kAudioFileCAFType, &file) == noErr, let input = file else { return [:] }
        defer { AudioFileClose(input) }
        var info: Unmanaged<CFDictionary>?
        var size = UInt32(MemoryLayout<CFDictionary>.size)
        guard AudioFileGetProperty(input, kAudioFilePropertyInfoDictionary, &size, &info) == noErr,
              let dict = info?.takeRetainedValue() as? [String: Any] else { return [:] }
        return dict.compactMapValues { $0 as? String }
    }

    private static func frameCount(_ packet: [UInt8]) -> UInt32 {
        let config = Int(packet[0] >> 3)
        let tenthsMs: Int
        switch config {
        case 0..<12: tenthsMs = [100, 200, 400, 600][config % 4]
        case 12..<16: tenthsMs = [100, 200][config % 2]
        default: tenthsMs = [25, 50, 100, 200][config % 4]
        }
        let frames: Int
        switch packet[0] & 3 {
        case 0: frames = 1
        case 1, 2: frames = 2
        default: frames = packet.count > 1 ? Int(packet[1] & 0x3F) : 1
        }
        return UInt32(frames * tenthsMs * 48 / 10)
    }
}
