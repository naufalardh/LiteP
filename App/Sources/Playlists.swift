import UIKit

struct Playlist: Codable {
    let id: String
    var name: String
    /// LibraryItem keys (path inside Documents/Music without extension).
    var songs: [String]
}

final class PlaylistStore {
    static let shared = PlaylistStore()
    static let changed = Notification.Name("LitePlaylistsChanged")
    private(set) var playlists: [Playlist] = []
    private var file: URL { Lite.shared.support.appendingPathComponent("playlists.json") }

    private init() {
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([Playlist].self, from: data) {
            playlists = saved
        }
    }

    func playlist(_ id: String) -> Playlist? { playlists.first { $0.id == id } }

    func items(_ id: String) -> [LibraryItem] {
        let byKey = Dictionary(LibraryStore.shared.items.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        return (playlist(id)?.songs ?? []).compactMap { byKey[$0] }
    }

    @discardableResult
    func create(_ name: String) -> Playlist {
        let playlist = Playlist(id: UUID().uuidString, name: name, songs: [])
        playlists.append(playlist)
        save()
        return playlist
    }

    func delete(_ id: String) { playlists.removeAll { $0.id == id }; save() }
    func rename(_ id: String, to name: String) { edit(id) { $0.name = name } }

    func add(_ items: [LibraryItem], to id: String) {
        edit(id) { p in p.songs += items.map { $0.key }.filter { !p.songs.contains($0) } }
    }

    /// Indexes refer to `items(id)`, which skips songs no longer in the library.
    func remove(at index: Int, from id: String) {
        let shown = items(id).map { $0.key }
        guard shown.indices.contains(index) else { return }
        edit(id) { p in p.songs.removeAll { $0 == shown[index] } }
    }

    func move(from: Int, to: Int, in id: String) {
        var shown = items(id).map { $0.key }
        guard shown.indices.contains(from), shown.indices.contains(to) else { return }
        shown.insert(shown.remove(at: from), at: to)
        edit(id) { p in p.songs = shown + p.songs.filter { !shown.contains($0) } }
    }

    private func edit(_ id: String, _ change: (inout Playlist) -> Void) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        change(&playlists[i])
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(playlists) { try? data.write(to: file, options: .atomic) }
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }
}

func before(_ a: String, _ b: String) -> Bool { a.localizedCaseInsensitiveCompare(b) == .orderedAscending }

func albumOrder(_ a: LibraryItem, _ b: LibraryItem) -> Bool {
    if a.albumName.lowercased() != b.albumName.lowercased() { return before(a.albumName, b.albumName) }
    if (a.discNumber ?? 0) != (b.discNumber ?? 0) { return (a.discNumber ?? 0) < (b.discNumber ?? 0) }
    if (a.trackNumber ?? 0) != (b.trackNumber ?? 0) { return (a.trackNumber ?? 0) < (b.trackNumber ?? 0) }
    return before(a.title, b.title)
}

/// Groups songs into albums (same album and artist, ignoring case), each in disc/track order.
func albumGroups(_ items: [LibraryItem]) -> [[LibraryItem]] {
    Dictionary(grouping: items) { "\($0.albumName.lowercased())\u{1}\($0.leadArtist.lowercased())" }
        .values.map { $0.sorted(by: albumOrder) }
        .sorted { before($0[0].albumName, $1[0].albumName) }
}

func songCount(_ n: Int) -> String { "\(n) song\(n == 1 ? "" : "s")" }

extension UIViewController {
    func askPlaylistName(_ title: String, _ current: String = "", done: @escaping (String) -> Void) {
        let a = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        a.addTextField { $0.text = current; $0.placeholder = "Name"; $0.autocapitalizationType = .words }
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        a.addAction(UIAlertAction(title: "Save", style: .default) { _ in
            let name = (a.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { done(name) }
        })
        present(a, animated: true)
    }

    func addToPlaylist(_ items: [LibraryItem], from view: UIView?) {
        let sheet = UIAlertController(title: "Add to playlist", message: items.count == 1 ? items[0].title : songCount(items.count),
                                      preferredStyle: .actionSheet)
        for p in PlaylistStore.shared.playlists {
            sheet.addAction(UIAlertAction(title: p.name, style: .default) { _ in PlaylistStore.shared.add(items, to: p.id) })
        }
        sheet.addAction(UIAlertAction(title: "New playlist…", style: .default) { _ in
            self.askPlaylistName("New playlist") { PlaylistStore.shared.add(items, to: PlaylistStore.shared.create($0).id) }
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(sheet, from: view)
    }

    /// The "…" menu of a song.
    func songMenu(_ item: LibraryItem, from view: UIView?, playlist: String? = nil, index: Int = 0) {
        let sheet = UIAlertController(title: item.title, message: "\(item.artistName) · \(item.albumName)", preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Play next", style: .default) { _ in Player.shared.playNext([item]) })
        sheet.addAction(UIAlertAction(title: "Add to queue", style: .default) { _ in Player.shared.addToQueue([item]) })
        sheet.addAction(UIAlertAction(title: "Add to playlist", style: .default) { _ in self.addToPlaylist([item], from: view) })
        if let id = playlist {
            sheet.addAction(UIAlertAction(title: "Remove from this playlist", style: .destructive) { _ in
                PlaylistStore.shared.remove(at: index, from: id)
            })
        }
        sheet.addAction(UIAlertAction(title: "Go to artist", style: .default) { _ in
            self.navigationController?.pushViewController(SongListViewController.artist(item.leadArtist), animated: true)
        })
        sheet.addAction(UIAlertAction(title: "Go to album", style: .default) { _ in
            self.navigationController?.pushViewController(SongListViewController.album(item), animated: true)
        })
        sheet.addAction(UIAlertAction(title: "Edit song info", style: .default) { _ in self.editInfo(item) })
        sheet.addAction(UIAlertAction(title: "Delete from library", style: .destructive) { _ in
            let confirm = UIAlertController(title: "Delete \"\(item.title)\"?", message: "The file is removed from this iPad.",
                                            preferredStyle: .alert)
            confirm.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            confirm.addAction(UIAlertAction(title: "Delete", style: .destructive) { _ in
                LibraryStore.shared.delete(item)
            })
            self.present(confirm, animated: true)
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(sheet, from: view)
    }

    func editInfo(_ item: LibraryItem) {
        let a = UIAlertController(title: "Edit song info", message: "Saved into the file's tags.", preferredStyle: .alert)
        for (value, hint) in [(item.title, "Title"), (item.artist, "Artist"), (item.album, "Album")] {
            a.addTextField { $0.text = value; $0.placeholder = hint; $0.autocapitalizationType = .words; $0.clearButtonMode = .whileEditing }
        }
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        a.addAction(UIAlertAction(title: "Save", style: .default) { _ in
            let v = (a.textFields ?? []).map { ($0.text ?? "").trimmingCharacters(in: .whitespaces) }
            guard v.count == 3 else { return }
            LibraryStore.shared.editTags(item, ["title": v[0], "artist": v[1], "album": v[2]]) { ok in
                if !ok { self.alert("Couldn't save", "This file's tags can't be edited.") }
            }
        })
        present(a, animated: true)
    }

    @objc func openNowPlaying() {
        guard Player.shared.current != nil else { return }
        (tabBarController ?? self).present(PlayerViewController(), animated: true)
    }
}

/// Your Library: Playlists, Artists, Albums and Songs.
final class LibraryViewController: UITableViewController, UISearchResultsUpdating {
    private struct Row { let title: String; let detail: String; let items: [LibraryItem]; let playlistId: String? }

    private let pills = PillBar(["Playlists", "Artists", "Albums", "Songs"],
                                selected: min(3, UserDefaults.standard.integer(forKey: "libraryMode")))
    private let search = UISearchController(searchResultsController: nil)
    private var rows: [Row] = []
    private var songs: [LibraryItem] = []
    private var mode: Int { pills.selected }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Your Library"
        pills.changed = { [weak self] index in
            UserDefaults.standard.set(index, forKey: "libraryMode")
            self?.setEditing(false, animated: false)
            self?.reload()
        }
        tableView.tableHeaderView = pills
        tableView.allowsMultipleSelectionDuringEditing = true
        updateButtons()
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = "Search in Your Library"
        navigationItem.searchController = search
        definesPresentationContext = true
        tableView.rowHeight = 64
        tableView.separatorStyle = .none
        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(rescan), for: .valueChanged)
        for name in [Lite.libraryChanged, PlaylistStore.changed, Player.changed] {
            NotificationCenter.default.addObserver(self, selector: #selector(reload), name: name, object: nil)
        }
        reload()
        rescan()
    }

    @objc private func rescan() {
        LibraryStore.shared.scan { [weak self] in self?.refreshControl?.endRefreshing() }
    }

    func updateSearchResults(for searchController: UISearchController) { reload() }

    @objc private func newPlaylist() {
        askPlaylistName("New playlist") { name in
            let p = PlaylistStore.shared.create(name)
            self.navigationController?.pushViewController(SongListViewController(playlist: p.id), animated: true)
        }
    }

    private lazy var plusButton = UIBarButtonItem(image: Icon.plus.image(22), style: .plain, target: self, action: #selector(newPlaylist))

    override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(editing, animated: animated)
        updateButtons()
    }

    private var selectable: [Int] { mode == 3 ? Array(songs.indices.map { $0 + 1 }) : Array(rows.indices) }

    private var selectedRows: [Int] {
        let valid = Set(selectable)
        return (tableView.indexPathsForSelectedRows ?? []).map { $0.row }.filter { valid.contains($0) }
    }

    private func updateButtons() {
        guard isEditing else {
            navigationItem.leftBarButtonItem = editButtonItem
            navigationItem.rightBarButtonItems = [plusButton]
            return
        }
        let count = selectedRows.count
        let all = count > 0 && count == selectable.count
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: all ? "Deselect All" : "Select All", style: .plain,
                                                           target: self, action: #selector(toggleSelectAll))
        let delete = UIBarButtonItem(title: count == 0 ? "Delete" : "Delete (\(count))", style: .plain, target: self,
                                     action: #selector(deleteSelected))
        delete.tintColor = Theme.red
        delete.isEnabled = count > 0
        navigationItem.rightBarButtonItems = [editButtonItem, delete]
    }

    @objc private func toggleSelectAll() {
        let all = selectedRows.count == selectable.count
        for row in selectable {
            let path = IndexPath(row: row, section: 0)
            if all { tableView.deselectRow(at: path, animated: false) } else { tableView.selectRow(at: path, animated: false, scrollPosition: .none) }
        }
        updateButtons()
    }

    @objc private func deleteSelected() {
        let picked = selectedRows
        guard !picked.isEmpty else { return }
        if mode == 0 {
            let ids = picked.compactMap { rows[$0].playlistId }
            confirm("Delete \(ids.count) playlist\(ids.count == 1 ? "" : "s")?", "Songs stay in your library.") {
                ids.forEach { PlaylistStore.shared.delete($0) }
            }
            return
        }
        let items = mode == 3 ? picked.map { songs[$0 - 1] } : picked.flatMap { rows[$0].items }
        confirm("Delete \(songCount(items.count))?", "The files are removed from this iPad.") {
            LibraryStore.shared.delete(items)
        }
    }

    private func confirm(_ title: String, _ message: String, action: @escaping () -> Void) {
        let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        a.addAction(UIAlertAction(title: "Delete", style: .destructive) { _ in
            action()
            self.setEditing(false, animated: true)
        })
        present(a, animated: true)
    }

    @objc private func reload() {
        let shown = { self.rows.map { $0.playlistId ?? $0.title } + self.songs.map { $0.path } }
        let listed = shown()
        let keep = isEditing ? tableView.indexPathsForSelectedRows ?? [] : []
        defer {
            if isEditing {
                // Keep the selection only if the same rows are still listed in the same order.
                if shown() == listed { keep.forEach { tableView.selectRow(at: $0, animated: false, scrollPosition: .none) } }
                updateButtons()
            }
        }
        let q = (search.searchBar.text ?? "").lowercased()
        let all = LibraryStore.shared.items.filter {
            q.isEmpty || "\($0.title) \($0.artist) \($0.album)".lowercased().contains(q)
        }
        songs = []
        rows = []
        switch mode {
        case 0:
            rows = PlaylistStore.shared.playlists
                .filter { q.isEmpty || $0.name.lowercased().contains(q) }
                .sorted { before($0.name, $1.name) }
                .map { p in
                    let items = PlaylistStore.shared.items(p.id)
                    return Row(title: p.name, detail: "Playlist · \(songCount(items.count))", items: items, playlistId: p.id)
                }
        case 1:
            let groups = Dictionary(grouping: all) { $0.leadArtist }
            rows = groups.keys.sorted(by: before).map { name in
                let items = groups[name]!.sorted(by: albumOrder)
                return Row(title: name, detail: "Artist · \(songCount(items.count))", items: items, playlistId: nil)
            }
        case 2:
            rows = albumGroups(all).map { Row(title: $0[0].albumName, detail: "Album · \($0[0].leadArtist)", items: $0, playlistId: nil) }
        default:
            songs = all.sorted { before($0.title, $1.title) }
        }
        let empty = mode == 3 ? songs.isEmpty : rows.isEmpty
        tableView.backgroundView = empty ? Theme.emptyLabel(mode == 0 && q.isEmpty
            ? "Tap + to create your first playlist."
            : q.isEmpty ? "Songs you download show up here." : "No matches") : nil
        tableView.reloadData()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        mode == 3 ? (songs.isEmpty ? 0 : songs.count + 1) : rows.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "a") as? ArtCell ?? ArtCell(style: .default, reuseIdentifier: "a")
        if mode == 3 {
            if indexPath.row == 0 {
                cell.art.accessibilityIdentifier = nil
                cell.art.contentMode = .center
                cell.art.image = Icon.shuffle.image(22, .black)
                cell.art.backgroundColor = Theme.green
                cell.set("Shuffle play", songCount(songs.count))
                return cell
            }
            let item = songs[indexPath.row - 1]
            cell.art.backgroundColor = Theme.elevated
            Art.set(cell.art, path: item.coverPath, size: 50)
            cell.set(item.title, "\(item.artistName) · \(item.albumName)", playing: Player.shared.current?.path == item.path)
            cell.onMore = { [weak self] v in self?.songMenu(item, from: v) }
            return cell
        }
        let row = rows[indexPath.row]
        cell.art.backgroundColor = Theme.elevated
        cell.round = mode == 1
        Art.set(cell.art, path: row.items.first { $0.coverPath != nil }?.coverPath, size: 50,
                placeholder: mode == 0 ? .list : mode == 1 ? .person : .music)
        cell.set(row.title, row.detail)
        return cell
    }

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool { mode != 3 || indexPath.row > 0 }

    override func tableView(_ tableView: UITableView, didDeselectRowAt indexPath: IndexPath) { if isEditing { updateButtons() } }

    override func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        isEditing && mode == 3 && indexPath.row == 0 ? nil : indexPath
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if isEditing { return updateButtons() }
        tableView.deselectRow(at: indexPath, animated: true)
        if mode == 3 {
            if indexPath.row == 0 { Player.shared.shuffle(songs) } else { Player.shared.play(songs, at: indexPath.row - 1) }
            return
        }
        let row = rows[indexPath.row]
        let list: SongListViewController
        if let id = row.playlistId {
            list = SongListViewController(playlist: id)
        } else if mode == 1 {
            list = SongListViewController.artist(row.title)
        } else {
            list = SongListViewController.album(row.items[0])
        }
        navigationController?.pushViewController(list, animated: true)
    }

    override func tableView(_ tableView: UITableView,
                            trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let cell = tableView.cellForRow(at: indexPath)
        if mode == 0 {
            let id = rows[indexPath.row].playlistId ?? ""
            let delete = UIContextualAction(style: .destructive, title: "Delete") { _, _, done in
                PlaylistStore.shared.delete(id); done(true)
            }
            let rename = UIContextualAction(style: .normal, title: "Rename") { _, _, done in
                self.askPlaylistName("Rename playlist", PlaylistStore.shared.playlist(id)?.name ?? "") {
                    PlaylistStore.shared.rename(id, to: $0)
                }
                done(true)
            }
            return UISwipeActionsConfiguration(actions: [delete, rename])
        }
        if mode == 3 && indexPath.row == 0 { return nil }
        let items = mode == 3 ? [songs[indexPath.row - 1]] : rows[indexPath.row].items
        let add = UIContextualAction(style: .normal, title: "Add to Playlist") { _, _, done in
            self.addToPlaylist(items, from: cell); done(true)
        }
        add.backgroundColor = Theme.green
        return UISwipeActionsConfiguration(actions: [add])
    }
}

/// Songs of one album, artist or playlist, under a Spotify-style header.
final class SongListViewController: UITableViewController {
    enum Kind { case album, artist, playlist(String) }

    private let kind: Kind
    private let load: () -> [LibraryItem]
    private let name: String
    private var songs: [LibraryItem] = []
    private var sections: [(String, [LibraryItem])] = []
    private var header: DetailHeader!

    init(kind: Kind, title: String, load: @escaping () -> [LibraryItem]) {
        self.kind = kind
        self.load = load
        name = title
        super.init(style: .plain)
    }

    convenience init(playlist id: String) {
        self.init(kind: .playlist(id), title: "") { PlaylistStore.shared.items(id) }
    }

    required init?(coder: NSCoder) { fatalError() }

    static func album(_ item: LibraryItem) -> SongListViewController {
        let album = item.albumName.lowercased(), artist = item.leadArtist.lowercased()
        return SongListViewController(kind: .album, title: item.albumName) {
            LibraryStore.shared.items
                .filter { $0.albumName.lowercased() == album && $0.leadArtist.lowercased() == artist }
                .sorted(by: albumOrder)
        }
    }

    static func artist(_ name: String) -> SongListViewController {
        SongListViewController(kind: .artist, title: name) {
            LibraryStore.shared.items.filter { $0.leadArtist == name || $0.artistNames.contains(name) }.sorted(by: albumOrder)
        }
    }

    private var playlistId: String? {
        if case let .playlist(id) = kind { return id }
        return nil
    }

    private var isArtist: Bool {
        if case .artist = kind { return true }
        return false
    }

    private var isAlbum: Bool {
        if case .album = kind { return true }
        return false
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        tableView.rowHeight = 60
        tableView.separatorStyle = .none
        header = DetailHeader(width: view.bounds.width, round: isArtist)
        header.action.addTarget(self, action: #selector(playAll), for: .touchUpInside)
        header.shuffle.addTarget(self, action: #selector(shuffleAll), for: .touchUpInside)
        if playlistId != nil {
            header.extra.isHidden = false
            header.extra.addTarget(self, action: #selector(addSongs), for: .touchUpInside)
            navigationItem.rightBarButtonItems = [
                UIBarButtonItem(image: Icon.more.image(22), style: .plain, target: self, action: #selector(playlistMenu)),
                editButtonItem,
            ]
        }
        tableView.tableHeaderView = header
        for n in [Lite.libraryChanged, PlaylistStore.changed, Player.changed] {
            NotificationCenter.default.addObserver(self, selector: #selector(reload), name: n, object: nil)
        }
        reload()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if header.frame.width != tableView.bounds.width { resizeHeader() }
    }

    private func resizeHeader() {
        header.frame.size = CGSize(width: tableView.bounds.width, height: header.layout(tableView.bounds.width))
        tableView.tableHeaderView = header
    }

    @objc private func reload() {
        let title = playlistId.flatMap { PlaylistStore.shared.playlist($0)?.name } ?? name
        self.title = title
        songs = load()
        sections = []
        for item in songs {
            if isArtist, let last = sections.last, last.0.lowercased() == item.albumName.lowercased() {
                sections[sections.count - 1].1.append(item)
            } else if isArtist || sections.isEmpty {
                sections.append((isArtist ? item.albumName : "", [item]))
            } else {
                sections[0].1.append(item)
            }
        }
        header.titleLabel.text = title
        switch kind {
        case .album: header.subtitleLabel.text = "Album · \(songs.first?.leadArtist ?? "") · \(songCount(songs.count))"
        case .artist: header.subtitleLabel.text = "\(sections.count) album\(sections.count == 1 ? "" : "s") · \(songCount(songs.count))"
        case .playlist: header.subtitleLabel.text = "Playlist · \(songCount(songs.count))"
        }
        Art.set(header.art, path: songs.first { $0.coverPath != nil }?.coverPath, size: 220,
                placeholder: isArtist ? .person : playlistId != nil ? .list : .music)
        header.action.alpha = songs.isEmpty ? 0.4 : 1
        resizeHeader()
        if playlistId != nil && songs.isEmpty {
            let empty = Theme.emptyLabel("This playlist is empty. Tap + to add songs.")
            empty.frame = CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 80)
            tableView.tableFooterView = empty
        } else {
            tableView.tableFooterView = UIView()
        }
        tableView.reloadData()
    }

    @objc private func playAll() { if !songs.isEmpty { Player.shared.play(songs, at: 0) } }
    @objc private func shuffleAll() { if !songs.isEmpty { Player.shared.shuffle(songs) } }

    @objc private func addSongs() {
        guard let id = playlistId else { return }
        let picker = SongPickerViewController { PlaylistStore.shared.add($0, to: id) }
        present(UINavigationController(rootViewController: picker), animated: true)
    }

    @objc private func playlistMenu() {
        guard let id = playlistId else { return }
        let sheet = UIAlertController(title: title, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Add songs", style: .default) { _ in self.addSongs() })
        sheet.addAction(UIAlertAction(title: "Rename", style: .default) { _ in
            self.askPlaylistName("Rename playlist", self.title ?? "") { PlaylistStore.shared.rename(id, to: $0) }
        })
        sheet.addAction(UIAlertAction(title: "Delete playlist", style: .destructive) { _ in
            PlaylistStore.shared.delete(id)
            self.navigationController?.popViewController(animated: true)
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItems?.first
        present(sheet, animated: true)
    }

    private func flatIndex(_ indexPath: IndexPath) -> Int {
        sections[0..<indexPath.section].reduce(0) { $0 + $1.1.count } + indexPath.row
    }

    override func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].1.count }

    override func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat { isArtist ? 44 : 0 }

    override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard isArtist else { return nil }
        let v = UIView()
        v.backgroundColor = Theme.bg
        let l = Theme.label(18, .bold)
        l.text = sections[section].0
        l.frame = CGRect(x: 16, y: 12, width: tableView.bounds.width - 32, height: 26)
        v.addSubview(l)
        return v
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "a") as? ArtCell ?? ArtCell(style: .default, reuseIdentifier: "a")
        let item = sections[indexPath.section].1[indexPath.row]
        let playing = Player.shared.current?.path == item.path
        cell.showsArt = !isAlbum
        if isAlbum {
            cell.set(item.title, item.artistName, playing: playing)
        } else {
            Art.set(cell.art, path: item.coverPath, size: 46)
            cell.set(item.title, isArtist ? item.albumName : "\(item.artistName) · \(item.albumName)", playing: playing)
        }
        let index = flatIndex(indexPath)
        cell.onMore = { [weak self] v in self?.songMenu(item, from: v, playlist: self?.playlistId, index: index) }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        Player.shared.play(songs, at: flatIndex(indexPath))
    }

    override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool { playlistId != nil }

    override func tableView(_ tableView: UITableView, moveRowAt source: IndexPath, to destination: IndexPath) {
        guard let id = playlistId else { return }
        PlaylistStore.shared.move(from: source.row, to: destination.row, in: id)
    }

    override func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle {
        playlistId != nil ? .delete : .none
    }

    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete, let id = playlistId else { return }
        PlaylistStore.shared.remove(at: indexPath.row, from: id)
    }

    override func tableView(_ tableView: UITableView,
                            trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let item = sections[indexPath.section].1[indexPath.row]
        if let id = playlistId {
            let remove = UIContextualAction(style: .destructive, title: "Remove") { _, _, done in
                PlaylistStore.shared.remove(at: indexPath.row, from: id); done(true)
            }
            return UISwipeActionsConfiguration(actions: [remove])
        }
        let cell = tableView.cellForRow(at: indexPath)
        let add = UIContextualAction(style: .normal, title: "Add to Playlist") { _, _, done in
            self.addToPlaylist([item], from: cell); done(true)
        }
        add.backgroundColor = Theme.green
        return UISwipeActionsConfiguration(actions: [add])
    }
}

/// Multi-select list of every song, used to fill a playlist.
final class SongPickerViewController: UITableViewController, UISearchResultsUpdating {
    private let done: ([LibraryItem]) -> Void
    private let all = LibraryStore.shared.items.sorted { before($0.title, $1.title) }
    private var shown: [LibraryItem] = []
    private var picked = Set<String>()
    private let search = UISearchController(searchResultsController: nil)

    init(done: @escaping ([LibraryItem]) -> Void) {
        self.done = done
        super.init(style: .plain)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Add songs"
        tableView.rowHeight = 60
        tableView.separatorStyle = .none
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Add", style: .done, target: self, action: #selector(add))
        navigationItem.rightBarButtonItem?.tintColor = Theme.green
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true
        updateSearchResults(for: search)
    }

    func updateSearchResults(for searchController: UISearchController) {
        let q = (search.searchBar.text ?? "").lowercased()
        shown = q.isEmpty ? all : all.filter { "\($0.title) \($0.artist) \($0.album)".lowercased().contains(q) }
        tableView.reloadData()
    }

    @objc private func cancel() { dismiss(animated: true) }

    @objc private func add() {
        done(all.filter { picked.contains($0.path) })
        dismiss(animated: true)
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { shown.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "a") as? ArtCell ?? ArtCell(style: .default, reuseIdentifier: "a")
        let item = shown[indexPath.row]
        Art.set(cell.art, path: item.coverPath, size: 46)
        cell.set(item.title, "\(item.artistName) · \(item.albumName)")
        cell.accessoryType = picked.contains(item.path) ? .checkmark : .none
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let path = shown[indexPath.row].path
        if picked.contains(path) { picked.remove(path) } else { picked.insert(path) }
        tableView.reloadRows(at: [indexPath], with: .none)
        navigationItem.rightBarButtonItem?.title = picked.isEmpty ? "Add" : "Add (\(picked.count))"
    }
}
