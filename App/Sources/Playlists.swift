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

private func before(_ a: String, _ b: String) -> Bool { a.localizedCaseInsensitiveCompare(b) == .orderedAscending }

private func albumOrder(_ a: LibraryItem, _ b: LibraryItem) -> Bool {
    if a.albumName.lowercased() != b.albumName.lowercased() { return before(a.albumName, b.albumName) }
    if (a.discNumber ?? 0) != (b.discNumber ?? 0) { return (a.discNumber ?? 0) < (b.discNumber ?? 0) }
    if (a.trackNumber ?? 0) != (b.trackNumber ?? 0) { return (a.trackNumber ?? 0) < (b.trackNumber ?? 0) }
    return before(a.title, b.title)
}

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
        let sheet = UIAlertController(title: "Add to playlist", message: items.count == 1 ? items[0].title : "\(items.count) songs",
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

    @objc func openNowPlaying() { navigationController?.pushViewController(PlayerViewController(), animated: true) }
}

/// Library root: Artists, Albums, Songs and Playlists.
final class LibraryViewController: UITableViewController, UISearchResultsUpdating {
    private struct Row { let title: String; let detail: String; let items: [LibraryItem]; let playlistId: String? }

    private let modes = UISegmentedControl(items: ["Artists", "Albums", "Songs", "Playlists"])
    private let search = UISearchController(searchResultsController: nil)
    private var rows: [Row] = []
    private var songs: [LibraryItem] = []
    private var mode: Int { modes.selectedSegmentIndex }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Library"
        modes.selectedSegmentIndex = 0
        modes.addTarget(self, action: #selector(reload), for: .valueChanged)
        navigationItem.titleView = modes
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Playing", style: .plain, target: self, action: #selector(openNowPlaying))
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        navigationItem.searchController = search
        definesPresentationContext = true
        tableView.rowHeight = 56
        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(rescan), for: .valueChanged)
        for name in [Lite.libraryChanged, PlaylistStore.changed] {
            NotificationCenter.default.addObserver(self, selector: #selector(reload), name: name, object: nil)
        }
        reload()
        rescan()
    }

    @objc private func rescan() {
        LibraryStore.shared.scan { [weak self] in self?.refreshControl?.endRefreshing() }
    }

    func updateSearchResults(for searchController: UISearchController) { reload() }

    @objc private func newPlaylist() { askPlaylistName("New playlist") { PlaylistStore.shared.create($0) } }

    @objc private func reload() {
        navigationItem.leftBarButtonItem = mode == 3
            ? UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(newPlaylist)) : nil
        let q = (search.searchBar.text ?? "").lowercased()
        let all = LibraryStore.shared.items.filter {
            q.isEmpty || "\($0.title) \($0.artist) \($0.album)".lowercased().contains(q)
        }
        songs = []
        rows = []
        switch mode {
        case 0:
            let groups = Dictionary(grouping: all) { $0.artistName }
            rows = groups.keys.sorted(by: before).map { name in
                let items = groups[name]!.sorted(by: albumOrder)
                let albums = Set(items.map { $0.albumName }).count
                return Row(title: name, detail: "\(albums) album\(albums == 1 ? "" : "s") · \(count(items))", items: items, playlistId: nil)
            }
        case 1:
            let groups = Dictionary(grouping: all) { "\($0.albumName.lowercased())\u{1}\($0.artistName.lowercased())" }
            rows = groups.values.map { $0.sorted(by: albumOrder) }
                .sorted { before($0[0].albumName, $1[0].albumName) }
                .map { Row(title: $0[0].albumName, detail: "\($0[0].artistName) · \(count($0))", items: $0, playlistId: nil) }
        case 2:
            songs = all.sorted { before($0.title, $1.title) }
        default:
            rows = PlaylistStore.shared.playlists
                .filter { q.isEmpty || $0.name.lowercased().contains(q) }
                .map { p in
                    let items = PlaylistStore.shared.items(p.id)
                    return Row(title: p.name, detail: count(items), items: items, playlistId: p.id)
                }
        }
        tableView.reloadData()
    }

    private func count(_ items: [LibraryItem]) -> String { "\(items.count) song\(items.count == 1 ? "" : "s")" }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        mode == 2 ? songs.count : rows.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "t") ?? UITableViewCell(style: .subtitle, reuseIdentifier: "t")
        cell.detailTextLabel?.textColor = .gray
        if mode == 2 {
            let item = songs[indexPath.row]
            cell.textLabel?.text = item.title
            cell.detailTextLabel?.text = "\(item.artistName) · \(item.albumName)"
            cell.accessoryType = .none
        } else {
            cell.textLabel?.text = rows[indexPath.row].title
            cell.detailTextLabel?.text = rows[indexPath.row].detail
            cell.accessoryType = .disclosureIndicator
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if mode == 2 {
            Player.shared.play(songs, at: indexPath.row)
            return openNowPlaying()
        }
        let row = rows[indexPath.row]
        let list: SongListViewController
        if let id = row.playlistId {
            list = SongListViewController(playlist: id)
        } else {
            let artist = mode == 0
            list = SongListViewController(title: row.title, grouped: artist) {
                let items = LibraryStore.shared.items.filter {
                    let same = { (x: String, y: String) in x.caseInsensitiveCompare(y) == .orderedSame }
                    return artist ? $0.artistName == row.title
                        : same($0.albumName, row.title) && same($0.artistName, row.items[0].artistName)
                }
                return items.sorted(by: albumOrder)
            }
        }
        navigationController?.pushViewController(list, animated: true)
    }

    override func tableView(_ tableView: UITableView,
                            trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let cell = tableView.cellForRow(at: indexPath)
        if mode == 3 {
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
        let items = mode == 2 ? [songs[indexPath.row]] : rows[indexPath.row].items
        let add = UIContextualAction(style: .normal, title: "Add to Playlist") { _, _, done in
            self.addToPlaylist(items, from: cell); done(true)
        }
        add.backgroundColor = view.tintColor
        guard mode == 2 else { return UISwipeActionsConfiguration(actions: [add]) }
        let delete = UIContextualAction(style: .destructive, title: "Delete") { _, _, done in
            LibraryStore.shared.delete(items[0])
            self.reload()
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [delete, add])
    }
}

/// Songs of one artist, album or playlist.
final class SongListViewController: UITableViewController {
    private let load: () -> [LibraryItem]
    private let grouped: Bool
    private let playlistId: String?
    private var songs: [LibraryItem] = []
    private var sections: [(String, [LibraryItem])] = []

    init(title: String, grouped: Bool, load: @escaping () -> [LibraryItem]) {
        self.load = load
        self.grouped = grouped
        playlistId = nil
        super.init(style: .plain)
        self.title = title
    }

    init(playlist id: String) {
        load = { PlaylistStore.shared.items(id) }
        grouped = false
        playlistId = id
        super.init(style: .plain)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.rowHeight = 56
        var buttons = [UIBarButtonItem(title: "Playing", style: .plain, target: self, action: #selector(openNowPlaying))]
        if playlistId != nil {
            buttons.append(editButtonItem)
            buttons.append(UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(addSongs)))
        }
        navigationItem.rightBarButtonItems = buttons
        for name in [Lite.libraryChanged, PlaylistStore.changed] {
            NotificationCenter.default.addObserver(self, selector: #selector(reload), name: name, object: nil)
        }
        reload()
    }

    @objc private func reload() {
        if let id = playlistId { title = PlaylistStore.shared.playlist(id)?.name ?? "Playlist" }
        songs = load()
        sections = []
        for item in songs {
            if grouped, let last = sections.last, last.0 == item.albumName {
                sections[sections.count - 1].1.append(item)
            } else if grouped || sections.isEmpty {
                sections.append((item.albumName, [item]))
            } else {
                sections[0].1.append(item)
            }
        }
        tableView.reloadData()
    }

    @objc private func addSongs() {
        guard let id = playlistId else { return }
        let picker = SongPickerViewController { PlaylistStore.shared.add($0, to: id) }
        present(UINavigationController(rootViewController: picker), animated: true)
    }

    override func numberOfSections(in tableView: UITableView) -> Int { sections.count + 1 }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        grouped && section > 0 ? sections[section - 1].0 : nil
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? (songs.isEmpty ? 0 : 2) : sections[section - 1].1.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "t") ?? UITableViewCell(style: .subtitle, reuseIdentifier: "t")
        cell.detailTextLabel?.textColor = .gray
        if indexPath.section == 0 {
            cell.textLabel?.text = indexPath.row == 0 ? "Play" : "Shuffle"
            cell.textLabel?.textColor = view.tintColor
            cell.detailTextLabel?.text = nil
            return cell
        }
        let item = sections[indexPath.section - 1].1[indexPath.row]
        cell.textLabel?.textColor = .black
        let number = (item.trackNumber ?? 0) > 0 && grouped ? "\(item.trackNumber!). " : ""
        cell.textLabel?.text = number + item.title
        cell.detailTextLabel?.text = grouped ? item.artistName : "\(item.artistName) · \(item.albumName)"
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 0 {
            Player.shared.play(indexPath.row == 0 ? songs : songs.shuffled(), at: 0)
        } else {
            let index = sections[0..<(indexPath.section - 1)].reduce(0) { $0 + $1.1.count } + indexPath.row
            Player.shared.play(songs, at: index)
        }
        openNowPlaying()
    }

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool { indexPath.section > 0 }
    override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        playlistId != nil && indexPath.section > 0
    }

    override func tableView(_ tableView: UITableView, targetIndexPathForMoveFromRowAt source: IndexPath,
                            toProposedIndexPath proposed: IndexPath) -> IndexPath {
        proposed.section == source.section ? proposed : source
    }

    override func tableView(_ tableView: UITableView, moveRowAt source: IndexPath, to destination: IndexPath) {
        guard let id = playlistId else { return }
        PlaylistStore.shared.move(from: source.row, to: destination.row, in: id)
    }

    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete, let id = playlistId else { return }
        PlaylistStore.shared.remove(at: indexPath.row, from: id)
    }

    override func tableView(_ tableView: UITableView,
                            trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard indexPath.section > 0 else { return nil }
        let item = sections[indexPath.section - 1].1[indexPath.row]
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
        add.backgroundColor = view.tintColor
        let delete = UIContextualAction(style: .destructive, title: "Delete") { _, _, done in
            LibraryStore.shared.delete(item)
            NotificationCenter.default.post(name: Lite.libraryChanged, object: nil)
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [delete, add])
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
        tableView.rowHeight = 56
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Add", style: .done, target: self, action: #selector(add))
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
        let cell = tableView.dequeueReusableCell(withIdentifier: "t") ?? UITableViewCell(style: .subtitle, reuseIdentifier: "t")
        let item = shown[indexPath.row]
        cell.textLabel?.text = item.title
        cell.detailTextLabel?.text = "\(item.artistName) · \(item.albumName)"
        cell.detailTextLabel?.textColor = .gray
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
