import UIKit

final class SearchViewController: UITableViewController, UISearchBarDelegate {
    private let searchBar = UISearchBar()
    private var results: [Track] = []
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
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Source", style: .plain, target: self, action: #selector(pickSource))
        NotificationCenter.default.addObserver(self, selector: #selector(updateSource), name: Lite.extensionsChanged, object: nil)
        updateSource()
    }

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
        tableView.reloadData()
        let done: (Any?, Error?) -> Void = { [weak self] value, error in
            guard let self = self else { return }
            self.results = jsonList(value).map { Track(raw: $0) }
            self.message = error?.localizedDescription ?? (self.results.isEmpty ? "No results" : "")
            self.tableView.reloadData()
        }
        if sourceId.isEmpty {
            Lite.shared.call("searchTracksWithMetadataProviders", ["query": query, "limit": 30, "include_extensions": true], done: done)
        } else if let ext = Lite.shared.searchExtensions.first(where: { $0.str("id") == sourceId }),
                  (ext["search_behavior"] as? [String: Any])?["enabled"] as? Bool != true {
            Lite.shared.call("searchTracksWithMetadataProvider", ["extension_id": sourceId, "query": query, "limit": 30], done: done)
        } else {
            Lite.shared.call("customSearchWithExtension", ["extension_id": sourceId, "query": query, "options": "{}",
                                                           "request_id": UUID().uuidString], done: done)
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { max(results.count, 1) }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "s") ?? UITableViewCell(style: .subtitle, reuseIdentifier: "s")
        cell.detailTextLabel?.textColor = .gray
        if results.isEmpty {
            cell.textLabel?.text = message
            cell.textLabel?.numberOfLines = 0
            cell.textLabel?.textColor = .gray
            cell.detailTextLabel?.text = nil
            cell.selectionStyle = .none
            return cell
        }
        let track = results[indexPath.row]
        cell.textLabel?.text = track.title
        cell.textLabel?.numberOfLines = 1
        cell.textLabel?.textColor = .black
        cell.detailTextLabel?.text = [track.artist, track.album].filter { !$0.isEmpty }.joined(separator: " · ")
        cell.selectionStyle = .default
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard results.indices.contains(indexPath.row) else { return }
        let track = results[indexPath.row]
        let providers = Lite.shared.downloadExtensions
        let cell = tableView.cellForRow(at: indexPath)
        guard !providers.isEmpty else {
            alert("No download extension", "Install and enable an extension with a download provider first.")
            return
        }
        let sheet = UIAlertController(title: "Download with", message: track.title, preferredStyle: .actionSheet)
        for ext in providers {
            sheet.addAction(UIAlertAction(title: ext.extName, style: .default) { _ in self.pickQuality(track, ext, cell) })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(sheet, from: cell)
    }

    private func pickQuality(_ track: Track, _ ext: [String: Any], _ cell: UITableViewCell?) {
        let options = ext["quality_options"] as? [[String: Any]] ?? []
        let id = ext.str("id")
        guard options.count > 1 else {
            DownloadManager.shared.enqueue(track, provider: id, quality: options.first?.str("id") ?? "LOSSLESS")
            return
        }
        let sheet = UIAlertController(title: "Quality", message: nil, preferredStyle: .actionSheet)
        for option in options {
            let label = option.str("label").isEmpty ? option.str("id") : option.str("label")
            sheet.addAction(UIAlertAction(title: label, style: .default) { _ in
                DownloadManager.shared.enqueue(track, provider: id, quality: option.str("id"))
            })
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
