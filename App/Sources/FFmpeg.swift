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
        if preferred == "flac" || preferred == "m4a" { attempts.append(("mp4", false)) }
        attempts.append(("mp4", true))
        for candidate in keyCandidates(key) {
            for (ext, forceMov) in attempts {
                if cancelled() { return nil }
                let staged = base.deletingLastPathComponent()
                    .appendingPathComponent(".litep-decrypt-\(UUID().uuidString).\(ext)")
                var arguments = ["-v", "error", "-decryption_key", candidate, "-f", format, "-i", input]
                if ext == "flac" { arguments += ["-map", "0:a"] }
                arguments += ["-c", "copy"]
                if forceMov { arguments += ["-f", "mov"] } else if ext == "flac" { arguments += ["-f", "flac"] }
                arguments += [staged.path, "-y"]
                let ok = LiteFFmpeg.run(arguments, cancelled: cancelled).0
                let size = (try? FileManager.default.attributesOfItem(atPath: staged.path))?[.size] as? NSNumber
                if ok, (size?.int64Value ?? 0) > 0 {
                    var target = base.appendingPathExtension(ext)
                    if target.path == input { target = URL(fileURLWithPath: base.path + " (decrypted)").appendingPathExtension(ext) }
                    try? FileManager.default.removeItem(at: target)
                    do { try FileManager.default.moveItem(at: staged, to: target) } catch {
                        try? FileManager.default.removeItem(at: staged)
                        return nil
                    }
                    try? FileManager.default.removeItem(at: source)
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
