import UIKit

private struct SearchGroup { let name: String; let detail: String; let tracks: [Track] }
private struct AlbumRef { let name: String; let subtitle: String; let cover: String; let provider: String; let id: String; let tracks: [Track] }

final class SearchViewController: UITableViewController, UISearchBarDelegate {
    private let searchBar = UISearchBar()
    private let pills = PillBar(["Songs", "Artists", "Albums"])
    private var results: [Track] = []
    private var sourceId = ""
    private var message = ""
    private var recent: [String] {
        get { UserDefaults.standard.stringArray(forKey: "recentSearches") ?? [] }
        set { UserDefaults.standard.set(Array(newValue.prefix(12)), forKey: "recentSearches") }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Search"
        searchBar.placeholder = "What do you want to listen to?"
        searchBar.delegate = self
        searchBar.searchBarStyle = .minimal
        searchBar.frame = CGRect(x: 8, y: 0, width: 304, height: 52)
        searchBar.autoresizingMask = .flexibleWidth
        let header = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 104))
        header.backgroundColor = Theme.bg
        pills.frame.origin.y = 52
        header.addSubview(searchBar)
        header.addSubview(pills)
        tableView.tableHeaderView = header
        searchBar.frame.size.width = view.bounds.width - 16
        pills.frame.size.width = view.bounds.width
        pills.changed = { [weak self] _ in self?.tableView.reloadData() }
        tableView.rowHeight = 64
        tableView.separatorStyle = .none
        tableView.keyboardDismissMode = .onDrag
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Source", style: .plain, target: self, action: #selector(pickSource))
        NotificationCenter.default.addObserver(self, selector: #selector(updateSource), name: Lite.extensionsChanged, object: nil)
        updateSource()
    }

    private var mode: Int { pills.selected }

    private var groups: [SearchGroup] {
        let artists = mode == 1
        var order: [String] = []
        var map: [String: [Track]] = [:]
        for track in results {
            let k = artists ? track.primaryArtist : (track.album.isEmpty ? "" : track.albumKey)
            guard !k.isEmpty else { continue }
            if map[k] == nil { order.append(k) }
            map[k, default: []].append(track)
        }
        return order.map { k in
            let tracks = map[k] ?? []
            guard !artists, let first = tracks.first else { return SearchGroup(name: k, detail: "Artist", tracks: tracks) }
            return SearchGroup(name: first.album, detail: "Album · \(first.primaryArtist)", tracks: tracks)
        }
    }

    private var showingRecent: Bool { results.isEmpty && message.isEmpty }

    @objc private func updateSource() {
        let match = Lite.shared.searchExtensions.first { $0.str("id") == sourceId }
        if match == nil { sourceId = "" }
        navigationItem.rightBarButtonItem?.title = match?.extName ?? "All sources"
    }

    @objc private func pickSource() {
        let sheet = UIAlertController(title: "Search with", message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "All sources", style: .default) { _ in self.sourceId = ""; self.updateSource() })
        for ext in Lite.shared.searchExtensions {
            sheet.addAction(UIAlertAction(title: ext.extName, style: .default) { _ in self.sourceId = ext.str("id"); self.updateSource() })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
        present(sheet, animated: true)
    }

    func searchBar(_ bar: UISearchBar, textDidChange text: String) {
        if text.isEmpty {
            results = []
            message = ""
            tableView.reloadData()
        }
    }

    func searchBarSearchButtonClicked(_ bar: UISearchBar) {
        bar.resignFirstResponder()
        run((bar.text ?? "").trimmingCharacters(in: .whitespaces))
    }

    private func run(_ query: String) {
        guard !query.isEmpty else { return }
        recent = [query] + recent.filter { $0.lowercased() != query.lowercased() }
        if Lite.shared.searchExtensions.isEmpty {
            message = "Install a search extension first: Home › top-right button, or Settings › Extensions."
            tableView.reloadData()
            return
        }
        message = "Searching…"
        results = []
        tableView.reloadData()
        let done: (Any?, Error?) -> Void = { [weak self] value, error in
            guard let self = self else { return }
            self.results = jsonList(value).map { Track(raw: $0) }
            self.message = error?.localizedDescription ?? (self.results.isEmpty ? "No results for \"\(query)\"" : "")
            self.tableView.reloadData()
        }
        if sourceId.isEmpty {
            Lite.shared.call("searchTracksWithMetadataProviders", ["query": query, "limit": 100, "include_extensions": true], done: done)
        } else if let ext = Lite.shared.searchExtensions.first(where: { $0.str("id") == sourceId }),
                  (ext["search_behavior"] as? [String: Any])?["enabled"] as? Bool != true {
            Lite.shared.call("searchTracksWithMetadataProvider", ["extension_id": sourceId, "query": query, "limit": 100], done: done)
        } else {
            Lite.shared.call("customSearchWithExtension", ["extension_id": sourceId, "query": query, "options": "{}",
                                                           "request_id": UUID().uuidString], done: done)
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if showingRecent { return recent.isEmpty ? 0 : recent.count + 1 }
        if !message.isEmpty { return 1 }
        return mode == 0 ? results.count : max(groups.count, 1)
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if showingRecent || !message.isEmpty || (mode != 0 && groups.isEmpty) {
            let cell = tableView.dequeueReusableCell(withIdentifier: "t") ?? UITableViewCell(style: .default, reuseIdentifier: "t")
            Theme.style(cell)
            cell.textLabel?.numberOfLines = 0
            if showingRecent {
                let header = indexPath.row == 0
                cell.textLabel?.text = header ? "Recent searches" : recent[indexPath.row - 1]
                cell.textLabel?.font = header ? .systemFont(ofSize: 18, weight: .bold) : .systemFont(ofSize: 16)
                cell.selectionStyle = header ? .none : .default
            } else {
                cell.textLabel?.text = message.isEmpty ? "No results" : message
                cell.textLabel?.font = .systemFont(ofSize: 15)
                cell.textLabel?.textColor = Theme.subtext
                cell.selectionStyle = .none
            }
            return cell
        }
        let cell = tableView.dequeueReusableCell(withIdentifier: "a") as? ArtCell ?? ArtCell(style: .default, reuseIdentifier: "a")
        if mode == 0 {
            let track = results[indexPath.row]
            Art.set(cell.art, path: nil, url: track.coverURL, size: 50)
            cell.set(track.title, "Song · \(track.artist)")
            cell.onMore = { [weak self] v in self?.download([track], from: v) }
        } else {
            let group = groups[indexPath.row]
            cell.round = mode == 1
            Art.set(cell.art, path: nil, url: group.tracks.first?.coverURL, size: 50, placeholder: mode == 1 ? .person : .music)
            cell.set(group.name, group.detail)
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if showingRecent {
            guard indexPath.row > 0 else { return }
            searchBar.text = recent[indexPath.row - 1]
            return run(recent[indexPath.row - 1])
        }
        guard message.isEmpty else { return }
        if mode == 0 {
            return download([results[indexPath.row]], from: tableView.cellForRow(at: indexPath))
        }
        guard groups.indices.contains(indexPath.row) else { return }
        let group = groups[indexPath.row]
        let page: UIViewController = mode == 1 ? ArtistPageViewController(group) : RemoteTracksViewController(group, album: true)
        navigationController?.pushViewController(page, animated: true)
    }

    override func tableView(_ tableView: UITableView,
                            trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard showingRecent, indexPath.row > 0 else { return nil }
        let remove = UIContextualAction(style: .destructive, title: "Remove") { _, _, done in
            self.recent.remove(at: indexPath.row - 1)
            tableView.reloadData()
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [remove])
    }
}

/// Songs of an artist or album from search, with Download all.
private final class RemoteTracksViewController: UITableViewController {
    private var group: SearchGroup
    private let album: Bool
    private let ref: AlbumRef?
    private var header: DetailHeader!

    init(_ group: SearchGroup, album: Bool, ref: AlbumRef? = nil) {
        self.group = group
        self.album = album
        self.ref = ref
        super.init(style: .plain)
        title = group.name
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        tableView.rowHeight = 60
        tableView.separatorStyle = .none
        header = DetailHeader(width: view.bounds.width, round: !album, action: .download)
        header.shuffle.isHidden = true
        header.action.addTarget(self, action: #selector(downloadAll), for: .touchUpInside)
        Art.set(header.art, path: nil, url: group.tracks.first?.coverURL ?? ref?.cover, size: 220, placeholder: album ? .music : .person)
        tableView.tableHeaderView = header
        refresh()
        if album { loadFullAlbum() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if header.frame.width != tableView.bounds.width { refresh() }
    }

    private func refresh() {
        header.titleLabel.text = group.name
        header.subtitleLabel.text = "\(group.detail) · \(songCount(group.tracks.count)) · tap ↓ to download all"
        header.frame.size = CGSize(width: tableView.bounds.width, height: header.layout(tableView.bounds.width))
        tableView.tableHeaderView = header
        tableView.reloadData()
    }

    @objc private func downloadAll() { if !group.tracks.isEmpty { download(group.tracks, from: header.action) } }

    /// Search only returns matching songs, so fetch the album itself to list every track.
    private func loadFullAlbum() {
        let first = group.tracks.first
        let provider = ref?.provider ?? first?.source ?? "", id = ref?.id ?? first?.albumId ?? ""
        let cover = ref?.cover ?? first?.coverURL ?? ""
        guard !provider.isEmpty, !id.isEmpty else { return }
        Lite.shared.call("getProviderMetadata", ["provider_id": provider, "resource_type": "album",
                                                 "resource_id": id]) { [weak self] value, error in
            guard let self = self else { return }
            let list = jsonList(jsonMap(value)["track_list"]).map { raw -> Track in
                var raw = raw
                if raw.str("source").isEmpty && raw.str("provider_id").isEmpty { raw["provider_id"] = provider }
                if raw.str("cover_url").isEmpty && raw["images"] == nil { raw["cover_url"] = cover }
                return Track(raw: raw)
            }
            guard error == nil, list.count > self.group.tracks.count else { return }
            self.group = SearchGroup(name: self.group.name, detail: self.group.detail, tracks: list)
            self.refresh()
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { group.tracks.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "a") as? ArtCell ?? ArtCell(style: .default, reuseIdentifier: "a")
        let track = group.tracks[indexPath.row]
        cell.showsArt = !album
        if !album { Art.set(cell.art, path: nil, url: track.coverURL, size: 46) }
        cell.set(track.title, album ? track.artist : "\(track.artist) · \(track.album)")
        cell.onMore = { [weak self] v in self?.download([track], from: v) }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        download([group.tracks[indexPath.row]], from: tableView.cellForRow(at: indexPath))
    }
}

/// Spotify-style artist page: popular songs, then albums and singles, loaded from the artist's provider.
private final class ArtistPageViewController: UITableViewController {
    private let name: String
    private var top: [Track]
    private var albums: [AlbumRef]
    private var cover: String
    private var header: DetailHeader!

    init(_ group: SearchGroup) {
        name = group.name
        top = group.tracks
        cover = group.tracks.first?.coverURL ?? ""
        var order: [String] = []
        var map: [String: [Track]] = [:]
        for t in group.tracks where !t.album.isEmpty {
            if map[t.albumKey] == nil { order.append(t.albumKey) }
            map[t.albumKey, default: []].append(t)
        }
        albums = order.compactMap { k in
            guard let tracks = map[k], let f = tracks.first else { return nil }
            return AlbumRef(name: f.album, subtitle: "Album", cover: f.coverURL, provider: f.source, id: f.albumId, tracks: tracks)
        }
        super.init(style: .plain)
        title = name
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        tableView.rowHeight = 64
        tableView.separatorStyle = .none
        header = DetailHeader(width: view.bounds.width, round: true, action: .download)
        header.shuffle.isHidden = true
        header.action.addTarget(self, action: #selector(downloadTop), for: .touchUpInside)
        tableView.tableHeaderView = header
        refresh()
        loadArtist()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if header.frame.width != tableView.bounds.width { refresh() }
    }

    private func refresh() {
        header.titleLabel.text = name
        header.subtitleLabel.text = "Artist · \(albums.count) release\(albums.count == 1 ? "" : "s") · tap ↓ for popular songs"
        Art.set(header.art, path: nil, url: cover, size: 220, placeholder: .person)
        header.frame.size = CGSize(width: tableView.bounds.width, height: header.layout(tableView.bounds.width))
        tableView.tableHeaderView = header
        tableView.reloadData()
    }

    private var popular: [Track] { Array(top.prefix(10)) }

    @objc private func downloadTop() { if !popular.isEmpty { download(popular, from: header.action) } }

    private func loadArtist() {
        guard let seed = top.first(where: { $0.primaryArtist == name && !$0.raw.str("artist_id").isEmpty && !$0.source.isEmpty })
            ?? top.first(where: { !$0.raw.str("artist_id").isEmpty && !$0.source.isEmpty }) else { return }
        let provider = seed.source
        Lite.shared.call("getProviderMetadata", ["provider_id": provider, "resource_type": "artist",
                                                 "resource_id": seed.raw.str("artist_id")]) { [weak self] value, error in
            guard let self = self, error == nil else { return }
            let map = jsonMap(value)
            let info = map["artist_info"] as? [String: Any] ?? [:]
            for key in ["cover_url", "images", "header_image"] where !info.str(key).isEmpty {
                self.cover = info.str(key)
                break
            }
            let tracks = jsonList(map["top_tracks"]).map { raw -> Track in
                var raw = raw
                if raw.str("source").isEmpty && raw.str("provider_id").isEmpty { raw["provider_id"] = provider }
                return Track(raw: raw)
            }
            if !tracks.isEmpty { self.top = tracks }
            var seen = Set<String>()
            var releases: [AlbumRef] = []
            for raw in jsonList(map["albums"]) + jsonList(map["releases"]) {
                let id = raw.str("id")
                guard !id.isEmpty, seen.insert(id).inserted else { continue }
                let year = String(raw.str("release_date").prefix(4))
                let type = raw.str("album_type").isEmpty ? "Album" : raw.str("album_type").capitalized
                let cover = raw.str("cover_url").isEmpty ? raw.str("images") : raw.str("cover_url")
                releases.append(AlbumRef(name: raw.str("name"), subtitle: [year, type].filter { !$0.isEmpty }.joined(separator: " · "),
                                         cover: cover, provider: raw.str("provider_id").isEmpty ? provider : raw.str("provider_id"),
                                         id: id, tracks: []))
            }
            if !releases.isEmpty { self.albums = releases }
            self.refresh()
        }
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 2 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? popular.count : albums.count
    }

    override func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        (section == 0 ? popular.isEmpty : albums.isEmpty) ? 0 : 48
    }

    override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let v = UIView()
        v.backgroundColor = Theme.bg
        let l = Theme.label(20, .bold)
        l.text = section == 0 ? "Popular" : "Discography"
        l.frame = CGRect(x: 16, y: 14, width: tableView.bounds.width - 32, height: 28)
        v.addSubview(l)
        return v
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "a") as? ArtCell ?? ArtCell(style: .default, reuseIdentifier: "a")
        if indexPath.section == 0 {
            let track = popular[indexPath.row]
            Art.set(cell.art, path: nil, url: track.coverURL, size: 50)
            cell.set("\(indexPath.row + 1)   \(track.title)", track.album)
            cell.onMore = { [weak self] v in self?.download([track], from: v) }
        } else {
            let album = albums[indexPath.row]
            Art.set(cell.art, path: nil, url: album.cover, size: 50)
            cell.set(album.name, album.subtitle)
            cell.accessoryType = .disclosureIndicator
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 0 {
            return download([popular[indexPath.row]], from: tableView.cellForRow(at: indexPath))
        }
        let album = albums[indexPath.row]
        let group = SearchGroup(name: album.name, detail: "Album · \(name)", tracks: album.tracks)
        navigationController?.pushViewController(RemoteTracksViewController(group, album: true, ref: album), animated: true)
    }
}

extension UIViewController {
    func alert(_ title: String, _ message: String?) {
        let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default))
        present(a, animated: true)
    }

    func present(_ sheet: UIAlertController, from view: UIView?) {
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = view ?? self.view
            popover.sourceRect = (view ?? self.view).bounds
        }
        present(sheet, animated: true)
    }

    /// Asks which download extension and quality to use, then queues the tracks.
    func download(_ tracks: [Track], from view: UIView?) {
        let providers = Lite.shared.downloadExtensions
        guard !providers.isEmpty else {
            alert("No download extension", "Install and enable an extension with a download provider first.")
            return
        }
        let sheet = UIAlertController(title: "Download with", message: tracks.count == 1 ? tracks[0].title : songCount(tracks.count),
                                      preferredStyle: .actionSheet)
        for ext in providers {
            sheet.addAction(UIAlertAction(title: ext.extName, style: .default) { _ in self.pickQuality(tracks, ext, view) })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(sheet, from: view)
    }

    private func pickQuality(_ tracks: [Track], _ ext: [String: Any], _ view: UIView?) {
        let options = ext["quality_options"] as? [[String: Any]] ?? []
        let id = ext.str("id")
        let enqueue = { (quality: String) in tracks.forEach { DownloadManager.shared.enqueue($0, provider: id, quality: quality) } }
        guard options.count > 1 else { return enqueue(options.first?.str("id") ?? "LOSSLESS") }
        let sheet = UIAlertController(title: "Quality", message: nil, preferredStyle: .actionSheet)
        for option in options {
            let label = option.str("label").isEmpty ? option.str("id") : option.str("label")
            sheet.addAction(UIAlertAction(title: label, style: .default) { _ in enqueue(option.str("id")) })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(sheet, from: view)
    }
}
