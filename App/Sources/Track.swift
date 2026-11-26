import Foundation

struct Track {
    let raw: [String: Any]
    var id: String { raw.str("id").isEmpty ? raw.str("spotify_id") : raw.str("id") }
    var title: String { raw.str("name").isEmpty ? raw.str("title") : raw.str("name") }
    var artist: String {
        for key in ["artists", "artist", "artist_name"] {
            if let list = raw[key] as? [String] { return list.joined(separator: ", ") }
            if let list = raw[key] as? [[String: Any]] { return list.map { $0.str("name") }.joined(separator: ", ") }
            let value = raw.str(key)
            if !value.isEmpty { return value }
        }
        return ""
    }
    var primaryArtist: String {
        for key in ["artists", "artist", "artist_name"] {
            if let list = raw[key] as? [String], let first = list.first { return first }
            if let list = raw[key] as? [[String: Any]], let first = list.first { return first.str("name") }
            let value = raw.str(key)
            if !value.isEmpty { return value }
        }
        return ""
    }
    var albumKey: String {
        if let map = raw["album"] as? [String: Any], !map.str("id").isEmpty { return map.str("id") }
        return raw.str("album_id").isEmpty ? album.lowercased() : raw.str("album_id")
    }
    var album: String {
        for key in ["album_name", "album"] {
            if let map = raw[key] as? [String: Any] { return map.str("name") }
            let value = raw.str(key)
            if !value.isEmpty { return value }
        }
        return ""
    }
    var coverURL: String {
        if !raw.str("cover_url").isEmpty { return raw.str("cover_url") }
        if let images = raw["images"] as? [[String: Any]] { return images.first?.str("url") ?? "" }
        return raw.str("images")
    }
    var source: String { raw.str("source").isEmpty ? raw.str("provider_id") : raw.str("source") }

    func providerTrackId(for provider: String) -> String {
        let id = self.id
        let p = provider.lowercased()
        if !source.isEmpty && source.lowercased() == p {
            if let r = id.range(of: ":") , r.upperBound < id.endIndex { return String(id[r.upperBound...]) }
            return id
        }
        if let r = id.range(of: ":"), id[..<r.lowerBound].lowercased() == p { return String(id[r.upperBound...]) }
        return ""
    }

    func downloadRequest(provider: String, quality: String, itemId: String, outputDir: String) -> [String: Any] {
        [
            "contract_version": 1,
            "isrc": raw.str("isrc"),
            "service": provider,
            "download_provider": provider,
            "provider_track_id": providerTrackId(for: provider),
            "spotify_id": id,
            "track_name": title,
            "artist_name": artist,
            "album_name": album,
            "album_artist": raw.str("album_artist"),
            "cover_url": coverURL,
            "cover_max_dimension": 1000,
            "output_dir": outputDir,
            "album_folder_template": "",
            "filename_format": "{title} - {artist}",
            "quality": quality,
            "embed_metadata": true,
            "artist_tag_mode": "joined",
            "embed_lyrics": false,
            "embed_replaygain": false,
            "post_processing_enabled": false,
            "auto_convert_downloads": false,
            "track_number": raw.int("track_number"),
            "playlist_position": 0,
            "disc_number": raw.int("disc_number"),
            "total_tracks": raw.int("total_tracks"),
            "total_discs": raw.int("total_discs"),
            "release_date": raw.str("release_date"),
            "item_id": itemId,
            "duration_ms": raw.int("duration_ms"),
            "source": source,
            "genre": raw.str("genre"),
            "label": raw.str("label"),
            "copyright": raw.str("copyright"),
            "composer": raw.str("composer"),
            "comment": "",
            "explicit": raw["explicit"] as? Bool ?? false,
            "album_type": raw.str("album_type"),
            "upc": raw.str("upc"),
            "tidal_id": "",
            "qobuz_id": "",
            "deezer_id": "",
            "lyrics_mode": "embed",
            "use_extensions": true,
            "use_fallback": false,
            "storage_mode": "app",
            "output_ext": "",
            "requires_container_conversion": false,
            "allow_quality_variant": false,
            "quality_variant": "",
            "songlink_region": "",
            "network_concurrency_limit": 2,
        ]
    }
}
