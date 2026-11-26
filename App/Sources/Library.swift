import AudioToolbox
import UIKit

struct LibraryItem: Codable {
    let path: String
    var title: String
    var artist: String
    var album: String
    var coverPath: String?
    var modified: Double
    /// 0 when the file has no track number; nil for entries indexed before track numbers were read.
    var trackNumber: Int?
    var discNumber: Int?
    var url: URL { URL(fileURLWithPath: path) }
    /// Path inside Documents/Music without extension, stable across reinstalls and Opus → AAC conversion.
    var key: String {
        let music = Lite.shared.music.standardizedFileURL.path + "/"
        let stem = url.deletingPathExtension().standardizedFileURL.path
        return stem.hasPrefix(music) ? String(stem.dropFirst(music.count)) : stem
    }
    var artistName: String { artist.isEmpty ? "Unknown Artist" : artist }
    var albumName: String { album.isEmpty ? "Unknown Album" : album }
}

final class LibraryStore {
    static let shared = LibraryStore()
    static let audioExtensions: Set<String> = ["flac", "m4a", "mp3", "aac", "alac", "wav", "aiff", "aif", "caf", "mp4"]
    private(set) var items: [LibraryItem] = []
    private var indexFile: URL { Lite.shared.support.appendingPathComponent("library.json") }
    private var coverDir: URL { Lite.shared.cache.appendingPathComponent("covers", isDirectory: true) }

    private init() {
        if let data = try? Data(contentsOf: indexFile),
           let saved = try? JSONDecoder().decode([LibraryItem].self, from: data) {
            items = saved
        }
    }

    /// Serial so overlapping rescans never convert the same file twice.
    private let scanQueue = DispatchQueue(label: "mornye.library.scan", qos: .userInitiated)

    /// Converts a finished download to a playable format right away, then refreshes the library.
    func importDownload(_ path: String, done: @escaping (String?) -> Void) {
        scanQueue.async {
            var url = URL(fileURLWithPath: path)
            if OpusRemux.extensions.contains(url.pathExtension.lowercased()) || OpusRemux.isOpusCAF(url) {
                guard let converted = self.convertOpus(url) else {
                    DispatchQueue.main.async { done(nil) }
                    return
                }
                url = converted
            }
            DispatchQueue.main.async {
                done(url.path)
                self.scan {}
            }
        }
    }

    /// Rescans Documents/Music, reading tags only for new or modified files.
    func scan(done: @escaping () -> Void) {
        scanQueue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: self.coverDir, withIntermediateDirectories: true)
            let known = Dictionary(self.items.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
            var result: [LibraryItem] = []
            let root = Lite.shared.music
            let files = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey])
            while var url = files?.nextObject() as? URL {
                if OpusRemux.extensions.contains(url.pathExtension.lowercased()) || OpusRemux.isOpusCAF(url) {
                    guard let converted = self.convertOpus(url) else { continue }
                    url = converted
                }
                guard LibraryStore.audioExtensions.contains(url.pathExtension.lowercased()) else { continue }
                let modified = ((try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()).timeIntervalSince1970
                if let old = known[url.path], old.modified == modified, old.discNumber != nil,
                   old.coverPath.map({ fm.fileExists(atPath: $0) }) ?? true {
                    result.append(old)
                    continue
                }
                autoreleasepool { result.append(self.read(url, modified: modified)) }
            }
            result.sort { ($0.artist.lowercased(), $0.album.lowercased(), $0.title.lowercased()) < ($1.artist.lowercased(), $1.album.lowercased(), $1.title.lowercased()) }
            if let data = try? JSONEncoder().encode(result) { try? data.write(to: self.indexFile, options: .atomic) }
            DispatchQueue.main.async {
                self.items = result
                NotificationCenter.default.post(name: Lite.libraryChanged, object: nil)
                done()
            }
        }
    }

    /// Converts Opus (.opus/.webm, or an older Opus .caf) to AAC .m4a, which iOS 12 plays, keeping its tags and cover.
    private func convertOpus(_ url: URL) -> URL? {
        let fm = FileManager.default
        let target = url.deletingPathExtension().appendingPathExtension("m4a")
        if fm.fileExists(atPath: target.path) { try? fm.removeItem(at: url); return target }
        var fields: [String: String] = [:]
        if url.pathExtension.lowercased() == "caf" {
            let tags = OpusRemux.tags(url)
            fields["title"] = tags[kAFInfoDictionary_Title]
            fields["artist"] = tags[kAFInfoDictionary_Artist]
            fields["album"] = tags[kAFInfoDictionary_Album]
        } else {
            let meta = jsonMap(try? Lite.shared.backend.readFileMetadata(path: url.path, hint: url.lastPathComponent))
            for (key, names) in [("title", ["title", "track_name"]), ("artist", ["artist", "artist_name"]),
                                 ("album", ["album", "album_name"]), ("album_artist", ["album_artist"])] {
                if let value = names.map({ meta.str($0) }).first(where: { !$0.isEmpty }) { fields[key] = value }
            }
            for (key, names) in [("track_number", ["track_number", "track", "tracknumber"]),
                                 ("disc_number", ["disc_number", "disc", "discnumber"])] {
                if let value = names.map({ meta.int($0) }).first(where: { $0 > 0 }) { fields[key] = String(value) }
            }
        }
        let parts = url.deletingPathExtension().lastPathComponent.components(separatedBy: " - ")
        if fields["title"] == nil, parts.count == 2 {
            fields["title"] = parts[0]
            if fields["artist"] == nil { fields["artist"] = parts[1] }
        }
        let cover = coverDir.appendingPathComponent(sha256Hex(target.path) + ".jpg")
        _ = try? Lite.shared.backend.extractCoverToFile(audioPath: url.path, outputPath: cover.path)
        let art = url.deletingPathExtension().appendingPathExtension("jpg")
        if fm.fileExists(atPath: cover.path), !fm.fileExists(atPath: art.path) { try? fm.copyItem(at: cover, to: art) }
        guard let converted = OpusRemux.toM4A(url) else {
            NSLog("MornyeLite: could not convert %@", url.lastPathComponent)
            return nil
        }
        if fm.fileExists(atPath: cover.path) { fields["cover_path"] = cover.path }
        if !fields.isEmpty, let data = try? JSONSerialization.data(withJSONObject: fields), let json = String(data: data, encoding: .utf8) {
            do { _ = try Lite.shared.backend.editFileMetadata(path: converted.path, metadataJson: json) }
            catch { NSLog("MornyeLite: could not tag %@: %@", converted.lastPathComponent, "\(error)") }
        }
        try? fm.removeItem(at: url)
        return converted
    }

    private func read(_ url: URL, modified: Double) -> LibraryItem {
        let name = url.deletingPathExtension().lastPathComponent
        var item = LibraryItem(path: url.path, title: name, artist: "", album: "", coverPath: nil, modified: modified, trackNumber: 0, discNumber: 0)
        let meta = jsonMap(try? Lite.shared.backend.readFileMetadata(path: url.path, hint: url.lastPathComponent))
        for key in ["title", "track_name", "name"] where !meta.str(key).isEmpty { item.title = meta.str(key); break }
        for key in ["artist", "artist_name", "artists"] where !meta.str(key).isEmpty { item.artist = meta.str(key); break }
        for key in ["album", "album_name"] where !meta.str(key).isEmpty { item.album = meta.str(key); break }
        for key in ["track_number", "track", "tracknumber"] where meta.int(key) > 0 { item.trackNumber = meta.int(key); break }
        for key in ["disc_number", "disc", "discnumber"] where meta.int(key) > 0 { item.discNumber = meta.int(key); break }
        if url.pathExtension.lowercased() == "caf" {
            let tags = OpusRemux.tags(url)
            if let v = tags[kAFInfoDictionary_Title], item.title == name { item.title = v }
            if let v = tags[kAFInfoDictionary_Artist], item.artist.isEmpty { item.artist = v }
            if let v = tags[kAFInfoDictionary_Album], item.album.isEmpty { item.album = v }
        }
        let art = url.deletingPathExtension().appendingPathExtension("jpg")
        let cover = coverDir.appendingPathComponent(sha256Hex(url.path) + ".jpg")
        if FileManager.default.fileExists(atPath: cover.path) {
            item.coverPath = cover.path
        } else if (try? Lite.shared.backend.extractCoverToFile(audioPath: url.path, outputPath: cover.path)) != nil,
                  FileManager.default.fileExists(atPath: cover.path) {
            item.coverPath = cover.path
        } else if FileManager.default.fileExists(atPath: art.path) {
            item.coverPath = art.path
        }
        return item
    }

    func delete(_ item: LibraryItem) {
        try? FileManager.default.removeItem(atPath: item.path)
        items.removeAll { $0.path == item.path }
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: indexFile, options: .atomic) }
    }
}
