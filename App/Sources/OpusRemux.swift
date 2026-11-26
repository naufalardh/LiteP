import AudioToolbox
import Foundation

/// Repackages Ogg or WebM Opus into CAF, which iOS 11+ plays natively. Packets are copied as-is (no re-encoding).
enum OpusRemux {
    static let extensions: Set<String> = ["opus", "ogg", "oga", "webm"]

    private struct Stream { var head: [UInt8]; var packets: [[UInt8]]; var endGranule: Int64 }

    static func toCAF(_ source: URL, tags: [String: String]) -> URL? {
        guard let data = try? Data(contentsOf: source, options: .mappedIfSafe) else { return nil }
        let bytes = [UInt8](data)
        guard let stream = ogg(bytes) ?? webm(bytes) else {
            NSLog("MornyeLite: unsupported Opus container %@ (%@)", source.lastPathComponent,
                  bytes.prefix(8).map { String(format: "%02x", $0) }.joined())
            return nil
        }
        let head = stream.head
        guard head.count >= 19, head.starts(with: Array("OpusHead".utf8)) else { return nil }
        let channels = UInt32(head[9])
        let preSkip = UInt32(head[10]) | UInt32(head[11]) << 8
        guard channels == 1 || channels == 2, head[18] == 0 else { return nil }
        let granule = stream.endGranule
        let audio = stream.packets.filter { !$0.isEmpty }
        guard !audio.isEmpty else { return nil }

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
        ok = ok && count == UInt32(descriptions.count)
        let valid = max(0, (granule > 0 ? min(totalFrames, granule) : totalFrames) - Int64(preSkip))
        var table = AudioFilePacketTableInfo(mNumberValidFrames: valid, mPrimingFrames: Int32(preSkip),
                                             mRemainderFrames: Int32(min(Int64(Int32.max), max(0, totalFrames - Int64(preSkip) - valid))))
        AudioFileSetProperty(out, kAudioFilePropertyPacketTableInfo, UInt32(MemoryLayout<AudioFilePacketTableInfo>.size), &table)
        var info = tags as CFDictionary
        AudioFileSetProperty(out, kAudioFilePropertyInfoDictionary, UInt32(MemoryLayout<CFDictionary>.size), &info)
        ok = AudioFileClose(out) == noErr && ok
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

    private static func ogg(_ bytes: [UInt8]) -> Stream? {
        var packets: [[UInt8]] = []
        var current: [UInt8] = []
        var serial: UInt32?
        var granule: Int64 = 0
        var pos = 0
        while pos + 27 <= bytes.count {
            guard bytes[pos] == 0x4F, bytes[pos + 1] == 0x67, bytes[pos + 2] == 0x67, bytes[pos + 3] == 0x53 else { return nil }
            let pageSerial = UInt32(bytes[pos + 14]) | UInt32(bytes[pos + 15]) << 8 | UInt32(bytes[pos + 16]) << 16 | UInt32(bytes[pos + 17]) << 24
            let segments = Int(bytes[pos + 26])
            var body = pos + 27 + segments
            guard body <= bytes.count else { return nil }
            // Chained or multiplexed streams are left as-is rather than partially converted.
            if serial != nil && serial != pageSerial { return nil }
            serial = pageSerial
            var g: Int64 = 0
            for i in 0..<8 { g |= Int64(bytes[pos + 6 + i]) << (8 * Int64(i)) }
            if g >= 0 { granule = g }
            for i in 0..<segments {
                let length = Int(bytes[pos + 27 + i])
                guard body + length <= bytes.count else { return nil }
                current.append(contentsOf: bytes[body..<body + length])
                body += length
                if length < 255 { packets.append(current); current = [] }
            }
            pos = body
        }
        guard pos == bytes.count, current.isEmpty, packets.count > 2 else { return nil }
        return Stream(head: packets[0], packets: Array(packets.dropFirst(2)), endGranule: granule)
    }

    /// WebM/Matroska (YouTube's Opus): CodecPrivate holds OpusHead, SimpleBlocks/Blocks hold packets.
    private static func webm(_ bytes: [UInt8]) -> Stream? {
        guard bytes.count > 4, bytes[0] == 0x1A, bytes[1] == 0x45, bytes[2] == 0xDF, bytes[3] == 0xA3 else { return nil }
        let masters: Set<UInt32> = [0x18538067, 0x1654AE6B, 0xAE, 0x1F43B675, 0xA0]
        var head: [UInt8] = []
        var opusTrack: UInt64?
        var trackNumber: UInt64 = 0
        var codec = ""
        var packets: [[UInt8]] = []
        var failed = false

        func vint(_ pos: inout Int, keepMarker: Bool) -> UInt64? {
            guard pos < bytes.count, bytes[pos] != 0 else { return nil }
            let first = bytes[pos]
            var length = 1
            while length <= 8 && first & (0x80 >> (length - 1)) == 0 { length += 1 }
            guard length <= 8, pos + length <= bytes.count else { return nil }
            var value = UInt64(keepMarker ? first : first & (0xFF >> length))
            var allOnes = value == UInt64(0xFF >> length)
            for i in 1..<length {
                value = value << 8 | UInt64(bytes[pos + i])
                allOnes = allOnes && bytes[pos + i] == 0xFF
            }
            pos += length
            return (!keepMarker && allOnes) ? UInt64.max : value
        }

        func vintIn(_ data: [UInt8], _ pos: inout Int) -> UInt64? {
            guard pos < data.count, data[pos] != 0 else { return nil }
            var length = 1
            while data[pos] & (0x80 >> (length - 1)) == 0 { length += 1 }
            guard pos + length <= data.count else { return nil }
            var value = UInt64(data[pos] & (0xFF >> length))
            for i in 1..<length { value = value << 8 | UInt64(data[pos + i]) }
            pos += length
            return value
        }
        func walk(_ start: Int, _ end: Int) {
            var pos = start
            while pos < end && !failed {
                guard let id = vint(&pos, keepMarker: true), let size = vint(&pos, keepMarker: false) else { failed = true; return }
                if pos > end || (size != UInt64.max && size > UInt64(end - pos)) { failed = true; return }
                let bodyEnd = size == UInt64.max ? end : pos + Int(size)
                let leaf = { Array(bytes[pos..<bodyEnd]) }
                switch UInt32(truncatingIfNeeded: id) {
                case let m where masters.contains(m):
                    if m == 0xAE { trackNumber = 0; codec = "" }
                    walk(pos, bodyEnd)
                    if m == 0xAE && codec == "A_OPUS" { opusTrack = trackNumber }
                case 0xD7: trackNumber = leaf().reduce(0) { $0 << 8 | UInt64($1) }
                case 0x86: codec = String(bytes: leaf(), encoding: .ascii) ?? ""
                case 0x63A2: if codec.isEmpty || codec == "A_OPUS" { head = leaf() }
                case 0xA3, 0xA1:
                    let body = leaf()
                    var p = 0
                    guard let track = vintIn(body, &p), p + 3 <= body.count else { failed = true; return }
                    if track == opusTrack {
                        guard body[p + 2] & 0x06 == 0 else { failed = true; return }
                        packets.append(Array(body[(p + 3)...]))
                    }
                default: break
                }
                pos = bodyEnd
            }
        }
        walk(0, bytes.count)
        guard !failed, opusTrack != nil, !packets.isEmpty else { return nil }
        return Stream(head: head, packets: packets, endGranule: 0)
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
