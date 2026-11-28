import Foundation
import CLiteFFmpeg

/// LiteP's audio-only FFmpeg: an in-process, stream-copy subset of the ffmpeg command line.
enum LiteFFmpeg {
    private final class Cancel {
        let check: () -> Bool
        init(_ check: @escaping () -> Bool) { self.check = check }
    }

    static func run(_ arguments: [String], cancelled: @escaping () -> Bool = { false }) -> (Bool, String) {
        NSLog("LiteP ffmpeg %@", redact(arguments).joined(separator: " "))
        let box = Cancel(cancelled)
        let strings = arguments.map { strdup($0) }
        defer { strings.forEach { free($0) } }
        var argv = strings.map { UnsafePointer<CChar>($0) }
        var message = [CChar](repeating: 0, count: 1024)
        let started = Date()
        let code = withExtendedLifetime(box) { () -> Int32 in
            lite_ffmpeg_run(Int32(argv.count), &argv, { opaque in
                Unmanaged<Cancel>.fromOpaque(opaque!).takeUnretainedValue().check() ? 1 : 0
            }, Unmanaged.passUnretained(box).toOpaque(), &message, message.count)
        }
        let text = String(cString: message)
        NSLog("LiteP ffmpeg finished code=%d in %.1fs %@", code, Date().timeIntervalSince(started), text)
        switch code {
        case 0: return (true, "")
        case -2: return (false, "cancelled")
        default: return (false, text.isEmpty ? "FFmpeg failed" : text)
        }
    }

    private static func redact(_ arguments: [String]) -> [String] {
        var out = arguments
        for i in out.indices.dropLast() where out[i] == "-decryption_key" { out[i + 1] = "[REDACTED]" }
        return out
    }
}

/// Mirrors Mornye's `ffmpeg.mov_key` strategy: decrypt an encrypted MOV/MP4 download with stream copy.
enum MovDecrypt {
    static func descriptor(_ result: [String: Any]) -> (key: String, inputFormat: String, outputExtension: String)? {
        let info = result["decryption"] as? [String: Any] ?? [:]
        let strategy = (info["strategy"] as? String ?? "ffmpeg.mov_key").lowercased()
        let key = (info["key"] as? String ?? "").isEmpty ? result.str("decryption_key") : info["key"] as? String ?? ""
        guard strategy == "ffmpeg.mov_key", !key.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return (key, info["input_format"] as? String ?? "", info["output_extension"] as? String ?? "")
    }

    static func needsDecryption(_ result: [String: Any]) -> Bool {
        !result.str("decryption_key").isEmpty || result["decryption"] != nil
    }

    /// Returns the decrypted file's path (the encrypted input is removed), or nil.
    static func run(input: String, key: String, inputFormat: String, outputExtension: String,
                    cancelled: @escaping () -> Bool) -> String? {
        let source = URL(fileURLWithPath: input)
        let base = source.deletingPathExtension()
        let format = inputFormat.isEmpty ? "mov" : inputFormat
        var preferred = outputExtension.trimmingCharacters(in: .whitespaces)
        if preferred.hasPrefix(".") { preferred.removeFirst() }
        if preferred.isEmpty {
            preferred = ["mp3", "opus", "mp4"].first { source.pathExtension.lowercased() == $0 } ?? "flac"
        }
        var attempts: [(String, Bool)] = [(preferred, false)]
        if preferred == "flac" { attempts.append(("m4a", false)) }
        // Opus streams go to Ogg so the library import converts them to AAC for iOS 12.
        if preferred != "opus" { attempts.append(("opus", false)) }
        if preferred == "flac" || preferred == "m4a" { attempts.append(("mp4", false)) }
        attempts.append(("mp4", true))
        for candidate in keyCandidates(key) {
            for (ext, forceMov) in attempts {
                if cancelled() { return nil }
                let staged = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("litep-decrypt-\(UUID().uuidString).\(ext)")
                var arguments = ["-v", "error", "-decryption_key", candidate, "-f", format, "-i", input]
                if ext == "flac" { arguments += ["-map", "0:a"] }
                arguments += ["-c", "copy"]
                if forceMov { arguments += ["-f", "mov"] } else if ext == "flac" { arguments += ["-f", "flac"] }
                arguments += [staged.path, "-y"]
                let ok = LiteFFmpeg.run(arguments, cancelled: cancelled).0
                let size = (try? FileManager.default.attributesOfItem(atPath: staged.path))?[.size] as? NSNumber
                if ok, (size?.int64Value ?? 0) > 0 {
                    var target = base.appendingPathExtension(ext)
                    var copy = 2
                    while target.path == input || FileManager.default.fileExists(atPath: target.path) {
                        target = URL(fileURLWithPath: "\(base.path) (\(copy))").appendingPathExtension(ext)
                        copy += 1
                    }
                    // Remove the encrypted file first so a rescan never sees both (and drops the Opus copy).
                    try? FileManager.default.removeItem(at: source)
                    do { try FileManager.default.moveItem(at: staged, to: target) } catch {
                        try? FileManager.default.removeItem(at: staged)
                        return nil
                    }
                    return target.path
                }
                try? FileManager.default.removeItem(at: staged)
            }
        }
        return nil
    }

    static func keyCandidates(_ raw: String) -> [String] {
        var candidates: [String] = []
        func add(_ key: String) {
            let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty, !candidates.contains(key) { candidates.append(key) }
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        add(trimmed)
        let noPrefix = trimmed.lowercased().hasPrefix("0x") ? String(trimmed.dropFirst(2)) : trimmed
        add(noPrefix)
        let hex = noPrefix.filter { $0.isHexDigit }
        if !hex.isEmpty, hex.count % 2 == 0 { add(hex) }
        if let data = Data(base64Encoded: noPrefix.filter { !$0.isWhitespace }), !data.isEmpty {
            add(data.map { String(format: "%02x", $0) }.joined())
        }
        return candidates
    }
}

/// Fragmented MP4 (e.g. soundcloudlite's joined HLS segments) plays in AVPlayer but not through AVAudioFile on iOS 12,
/// so it is rewritten as a regular MP4 with stream copy.
enum FragmentedMP4 {
    static func isFragmented(_ url: URL) -> Bool {
        guard ["m4a", "mp4", "aac", "alac"].contains(url.pathExtension.lowercased()),
              let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { handle.closeFile() }
        var offset: UInt64 = 0
        for _ in 0..<64 {
            handle.seek(toFileOffset: offset)
            let header = [UInt8](handle.readData(ofLength: 16))
            guard header.count >= 8 else { return false }
            var size = header[0..<4].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            let type = String(bytes: header[4..<8], encoding: .ascii) ?? ""
            if type == "moof" || type == "mvex" { return true }
            if size == 1 {
                guard header.count == 16 else { return false }
                size = header[8..<16].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            }
            if type == "moov" {
                // mvex inside moov marks a fragmented file even before the first moof.
                var child = offset + 8
                while child + 8 <= offset + size {
                    handle.seek(toFileOffset: child)
                    let box = [UInt8](handle.readData(ofLength: 8))
                    guard box.count == 8 else { return false }
                    if String(bytes: box[4..<8], encoding: .ascii) == "mvex" { return true }
                    let length = box[0..<4].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                    guard length >= 8 else { return false }
                    child += length
                }
                return false
            }
            guard size >= 8 else { return false }
            offset += size
        }
        return false
    }

    /// Rewrites the file in place; returns false (leaving it untouched) when remuxing fails.
    @discardableResult
    static func defragment(_ url: URL) -> Bool {
        let part = url.deletingPathExtension().appendingPathExtension("m4a-part")
        defer { try? FileManager.default.removeItem(at: part) }
        let (ok, message) = LiteFFmpeg.run(["-hide_banner", "-nostdin", "-v", "error", "-i", url.path,
                                            "-map", "0:a", "-c", "copy", "-f", "mp4", "-y", part.path])
        guard ok, rename(part.path, url.path) == 0 else {
            NSLog("LiteP: could not defragment %@: %@", url.lastPathComponent, message)
            return false
        }
        return true
    }
}
