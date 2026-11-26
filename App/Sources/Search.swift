import UIKit

final class SearchViewController: UITableViewController, UISearchBarDelegate {
    private struct Group { let name: String; let detail: String; let tracks: [Track] }

    private let searchBar = UISearchBar()
    private let modes = UISegmentedControl(items: ["Songs", "Artists", "Albums"])
    private var results: [Track] = []
    private var opened: Group?
    private var sourceId = ""
    private var message = "Add a repository and install extensions in the Extensions tab, then search here."

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Search"
        searchBar.placeholder = "Songs, artists, albums"
        searchBar.delegate = self
        searchBar.sizeToFit()
        tableView.tableHeaderView = searchBar
        tableView.rowHeight = 56
        tableView.keyboardDismissMode = .onDrag
        modes.selectedSegmentIndex = 0
        modes.addTarget(self, action: #selector(modeChanged), for: .valueChanged)
        navigationItem.titleView = modes
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Source", style: .plain, target: self, action: #selector(pickSource))
        NotificationCenter.default.addObserver(self, selector: #selector(updateSource), name: Lite.extensionsChanged, object: nil)
        updateSource()
    }

    @objc private func modeChanged() { close() }

    @objc private func close() {
        opened = nil
        navigationItem.leftBarButtonItem = nil
        tableView.reloadData()
    }

    private var groups: [Group] {
        let artists = modes.selectedSegmentIndex == 1
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
            let count = "\(tracks.count) song\(tracks.count == 1 ? "" : "s")"
            guard !artists, let first = tracks.first else { return Group(name: k, detail: count, tracks: tracks) }
            return Group(name: first.album, detail: "\(first.primaryArtist) · \(count)", tracks: tracks)
        }
    }

    private var showingGroups: Bool { opened == nil && modes.selectedSegmentIndex != 0 }
    private var tracks: [Track] { opened?.tracks ?? results }

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

    func searchBarSearchButtonClicked(_ bar: UISearchBar) {
        bar.resignFirstResponder()
        let query = (bar.text ?? "").trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        message = "Searching…"
        results = []
        close()
        let done: (Any?, Error?) -> Void = { [weak self] value, error in
            guard let self = self else { return }
            self.results = jsonList(value).map { Track(raw: $0) }
            self.message = error?.localizedDescription ?? (self.results.isEmpty ? "No results" : "")
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

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { opened?.name }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if showingGroups { return max(groups.count, 1) }
        return opened != nil ? tracks.count + 1 : max(tracks.count, 1)
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "s") ?? UITableViewCell(style: .subtitle, reuseIdentifier: "s")
        cell.detailTextLabel?.textColor = .gray
        cell.textLabel?.numberOfLines = 1
        cell.textLabel?.textColor = .black
        cell.selectionStyle = .default
        cell.accessoryType = .none
        let empty = showingGroups ? groups.isEmpty : (opened == nil && tracks.isEmpty)
        if empty {
            cell.textLabel?.text = message.isEmpty ? "No results" : message
            cell.textLabel?.numberOfLines = 0
            cell.textLabel?.textColor = .gray
            cell.detailTextLabel?.text = nil
            cell.selectionStyle = .none
            return cell
        }
        if showingGroups {
            let group = groups[indexPath.row]
            cell.textLabel?.text = group.name
            cell.detailTextLabel?.text = group.detail
            cell.accessoryType = .disclosureIndicator
            return cell
        }
        if opened != nil && indexPath.row == 0 {
            cell.textLabel?.text = "Download all (\(tracks.count))"
            cell.textLabel?.textColor = view.tintColor
            cell.detailTextLabel?.text = nil
            return cell
        }
        let track = tracks[indexPath.row - (opened != nil ? 1 : 0)]
        cell.textLabel?.text = track.title
        cell.detailTextLabel?.text = [track.artist, track.album].filter { !$0.isEmpty }.joined(separator: " · ")
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let cell = tableView.cellForRow(at: indexPath)
        if showingGroups {
            guard groups.indices.contains(indexPath.row) else { return }
            opened = groups[indexPath.row]
            navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Back", style: .plain, target: self, action: #selector(close))
            tableView.reloadData()
            if modes.selectedSegmentIndex == 2, let group = opened { loadFullAlbum(group) }
            return
        }
        if opened != nil && indexPath.row == 0 { return pickProvider(tracks, cell) }
        let index = indexPath.row - (opened != nil ? 1 : 0)
        guard tracks.indices.contains(index) else { return }
        pickProvider([tracks[index]], cell)
    }

    /// Search only returns matching songs, so fetch the album itself to list every track.
    private func loadFullAlbum(_ group: Group) {
        guard let first = group.tracks.first, !first.albumId.isEmpty, !first.source.isEmpty else { return }
        Lite.shared.call("getProviderMetadata", ["provider_id": first.source, "resource_type": "album",
                                                 "resource_id": first.albumId]) { [weak self] value, error in
            guard let self = self, self.opened?.name == group.name else { return }
            let list = jsonList(jsonMap(value)["track_list"]).map { raw -> Track in
                var raw = raw
                if raw.str("source").isEmpty && raw.str("provider_id").isEmpty { raw["provider_id"] = first.source }
                return Track(raw: raw)
            }
            guard error == nil, list.count > group.tracks.count else { return }
            let count = "\(list.count) song\(list.count == 1 ? "" : "s")"
            self.opened = Group(name: group.name, detail: "\(first.primaryArtist) · \(count)", tracks: list)
            self.tableView.reloadData()
        }
    }

    private func pickProvider(_ tracks: [Track], _ cell: UITableViewCell?) {
        let providers = Lite.shared.downloadExtensions
        guard !providers.isEmpty else {
            alert("No download extension", "Install and enable an extension with a download provider first.")
            return
        }
        let sheet = UIAlertController(title: "Download with", message: tracks.count == 1 ? tracks[0].title : "\(tracks.count) songs",
                                      preferredStyle: .actionSheet)
        for ext in providers {
            sheet.addAction(UIAlertAction(title: ext.extName, style: .default) { _ in self.pickQuality(tracks, ext, cell) })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(sheet, from: cell)
    }

    private func pickQuality(_ tracks: [Track], _ ext: [String: Any], _ cell: UITableViewCell?) {
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
        present(sheet, from: cell)
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
}
