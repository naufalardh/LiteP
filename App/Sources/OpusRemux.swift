import AudioToolbox
import COpus
import Foundation

/// Decodes Ogg, WebM or CAF Opus with libopus and re-encodes it as AAC (.m4a), which iOS 12 can play.
enum OpusRemux {
    static let extensions: Set<String> = ["opus", "ogg", "oga", "webm"]

    private struct Stream {
        var head: [UInt8]
        var packets: [[UInt8]]
        var endGranule: Int64
    }

    static func toM4A(_ source: URL) -> URL? {
        guard let stream = load(source) else { return nil }
        let head = stream.head
        guard head.count >= 19, head.starts(with: Array("OpusHead".utf8)), head[18] == 0 else { return nil }
        let channels = Int(head[9])
        guard channels == 1 || channels == 2 else { return nil }
        var preSkip = Int(head[10]) | Int(head[11]) << 8
        var remaining = stream.endGranule > 0 ? stream.endGranule - Int64(preSkip) : Int64.max
        var error: Int32 = 0
        guard let decoder = opus_decoder_create(48000, Int32(channels), &error), error == OPUS_OK else { return nil }
        defer { opus_decoder_destroy(decoder) }

        let target = source.deletingPathExtension().appendingPathExtension("m4a")
        let partial = source.deletingPathExtension().appendingPathExtension("m4a-part")
        var aac = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0,
                                              mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0,
                                              mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 0, mReserved: 0)
        var pcm = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
                                              mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                              mBytesPerPacket: UInt32(4 * channels), mFramesPerPacket: 1,
                                              mBytesPerFrame: UInt32(4 * channels), mChannelsPerFrame: UInt32(channels),
                                              mBitsPerChannel: 32, mReserved: 0)
        var fileRef: ExtAudioFileRef?
        var status = ExtAudioFileCreateWithURL(partial as CFURL, kAudioFileM4AType, &aac, nil,
                                               AudioFileFlags.eraseFile.rawValue, &fileRef)
        guard status == noErr, let file = fileRef else {
            NSLog("MornyeLite: could not create %@ (%d)", target.lastPathComponent, status)
            return nil
        }
        var codec = kAppleSoftwareAudioCodecManufacturer
        _ = ExtAudioFileSetProperty(file, kExtAudioFileProperty_CodecManufacturer, UInt32(MemoryLayout<UInt32>.size), &codec)
        status = ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat,
                                         UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &pcm)
        if status == noErr { setBitRate(file, channels == 2 ? 256_000 : 128_000) }

        var samples = [Float](repeating: 0, count: 5760 * channels)
        for packet in stream.packets where status == noErr && remaining > 0 && !packet.isEmpty {
            let decoded = Int(packet.withUnsafeBufferPointer { bytes in
                opus_decode_float(decoder, bytes.baseAddress, Int32(packet.count), &samples, 5760, 0)
            })
            guard decoded >= 0 else {
                status = OSStatus(decoded)
                break
            }
            let skip = min(decoded, preSkip)
            preSkip -= skip
            let frames = Int(min(Int64(decoded - skip), remaining))
            guard frames > 0 else { continue }
            remaining -= Int64(frames)
            status = samples.withUnsafeMutableBufferPointer { buffer -> OSStatus in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(channels), mDataByteSize: UInt32(frames * channels * 4),
                    mData: UnsafeMutableRawPointer(buffer.baseAddress! + skip * channels)))
                return ExtAudioFileWrite(file, UInt32(frames), &list)
            }
        }
        let closed = ExtAudioFileDispose(file)
        guard status == noErr, closed == noErr else {
            NSLog("MornyeLite: AAC encode failed for %@ (%d/%d)", source.lastPathComponent, status, closed)
            try? FileManager.default.removeItem(at: partial)
            return nil
        }
        do {
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: partial, to: target)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            return nil
        }
        return target
    }

    /// True for .caf files holding Opus, which iOS 12's player cannot decode.
    static func isOpusCAF(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "caf" else { return false }
        var fileID: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, kAudioFileCAFType, &fileID) == noErr, let file = fileID else { return false }
        defer { AudioFileClose(file) }
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        return AudioFileGetProperty(file, kAudioFilePropertyDataFormat, &size, &format) == noErr && format.mFormatID == kAudioFormatOpus
    }

    private static func setBitRate(_ file: ExtAudioFileRef, _ rate: UInt32) {
        var converter: AudioConverterRef?
        var size = UInt32(MemoryLayout<AudioConverterRef?>.size)
        guard ExtAudioFileGetProperty(file, kExtAudioFileProperty_AudioConverter, &size, &converter) == noErr,
              let audioConverter = converter else { return }
        var bitRate = rate
        guard AudioConverterSetProperty(audioConverter, kAudioConverterEncodeBitRate,
                                        UInt32(MemoryLayout<UInt32>.size), &bitRate) == noErr else { return }
        var config: CFArray?
        _ = ExtAudioFileSetProperty(file, kExtAudioFileProperty_ConverterConfig, UInt32(MemoryLayout<CFArray?>.size), &config)
    }

    private static func load(_ source: URL) -> Stream? {
        if source.pathExtension.lowercased() == "caf" { return caf(source) }
        guard let data = try? Data(contentsOf: source, options: .mappedIfSafe) else { return nil }
        let bytes = [UInt8](data)
        if let stream = ogg(bytes) ?? webm(bytes) { return stream }
        NSLog("MornyeLite: unsupported Opus container %@ (%@)", source.lastPathComponent,
              bytes.prefix(8).map { String(format: "%02x", $0) }.joined())
        return nil
    }

    private static func caf(_ url: URL) -> Stream? {
        var fileID: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, kAudioFileCAFType, &fileID) == noErr, let file = fileID else { return nil }
        defer { AudioFileClose(file) }
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioFileGetProperty(file, kAudioFilePropertyDataFormat, &size, &format) == noErr,
              format.mFormatID == kAudioFormatOpus else { return nil }
        var count: UInt64 = 0
        size = UInt32(MemoryLayout<UInt64>.size)
        guard AudioFileGetProperty(file, kAudioFilePropertyAudioDataPacketCount, &size, &count) == noErr, count > 0 else { return nil }
        var table = AudioFilePacketTableInfo()
        size = UInt32(MemoryLayout<AudioFilePacketTableInfo>.size)
        _ = AudioFileGetProperty(file, kAudioFilePropertyPacketTableInfo, &size, &table)
        var maxSize: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioFileGetProperty(file, kAudioFilePropertyMaximumPacketSize, &size, &maxSize)
        if maxSize == 0 { maxSize = 4096 }
        var buffer = [UInt8](repeating: 0, count: Int(maxSize))
        var description = AudioStreamPacketDescription()
        var packets: [[UInt8]] = []
        for index in 0..<Int64(count) {
            var bytes = maxSize
            var packetsRead: UInt32 = 1
            guard AudioFileReadPacketData(file, false, &bytes, &description, index, &packetsRead, &buffer) == noErr,
                  packetsRead == 1 else { return nil }
            packets.append(Array(buffer[0..<Int(bytes)]))
        }
        let preSkip = UInt16(clamping: max(0, table.mPrimingFrames))
        let head = Array("OpusHead".utf8) + [1, UInt8(format.mChannelsPerFrame), UInt8(preSkip & 0xFF), UInt8(preSkip >> 8),
                                             0x80, 0xBB, 0, 0, 0, 0, 0]
        let end = table.mNumberValidFrames > 0 ? table.mNumberValidFrames + Int64(preSkip) : 0
        return Stream(head: head, packets: packets, endGranule: end)
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
        func walk(_ start: Int, _ end: Int, _ depth: Int) {
            guard depth < 8 else { failed = true; return }
            var pos = start
            while pos < end && !failed {
                guard let id = vint(&pos, keepMarker: true), let size = vint(&pos, keepMarker: false) else { failed = true; return }
                if pos > end || (size != UInt64.max && size > UInt64(end - pos)) { failed = true; return }
                let bodyEnd = size == UInt64.max ? end : pos + Int(size)
                let leaf = { Array(bytes[pos..<bodyEnd]) }
                switch UInt32(truncatingIfNeeded: id) {
                case let m where masters.contains(m):
                    if m == 0xAE { trackNumber = 0; codec = "" }
                    walk(pos, bodyEnd, depth + 1)
                    // Only audio-only Opus files are converted, so videos and multi-track files keep their original.
                    if m == 0xAE { if codec == "A_OPUS" && opusTrack == nil { opusTrack = trackNumber } else { failed = true } }
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
        walk(0, bytes.count, 0)
        guard !failed, opusTrack != nil, !packets.isEmpty else { return nil }
        return Stream(head: head, packets: packets, endGranule: 0)
    }
}
