import UIKit

final class SettingsViewController: UITableViewController {
    private var musicSize = "…"
    private var cacheSize = "…"
    private let rows = [["Music", "Cache"], ["Clear cache", "Rescan library", "Clear finished downloads"], ["Version"]]

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Settings"
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        measure()
    }

    private func measure() {
        DispatchQueue.global(qos: .utility).async {
            let music = Self.size(Lite.shared.music)
            let cache = Self.size(Lite.shared.cache) + Self.size(FileManager.default.temporaryDirectory)
            DispatchQueue.main.async {
                self.musicSize = ByteCountFormatter.string(fromByteCount: music, countStyle: .file)
                self.cacheSize = ByteCountFormatter.string(fromByteCount: cache, countStyle: .file)
                self.tableView.reloadData()
            }
        }
    }

    private static func size(_ dir: URL) -> Int64 {
        guard let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in files {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }

    private func clearCache() {
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            for dir in [Lite.shared.cache, fm.temporaryDirectory] {
                for item in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
                    try? fm.removeItem(at: item)
                }
            }
            try? fm.createDirectory(at: Lite.shared.repoCache, withIntermediateDirectories: true)
            URLCache.shared.removeAllCachedResponses()
            DispatchQueue.main.async {
                LibraryStore.shared.scan { self.measure() }
                self.alert("Cache cleared", "Your music, extensions and repositories were kept.")
            }
        }
    }

    override func numberOfSections(in tableView: UITableView) -> Int { rows.count }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rows[section].count }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        ["Storage", nil, "About"][section]
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        cell.textLabel?.text = rows[indexPath.section][indexPath.row]
        cell.selectionStyle = indexPath.section == 1 ? .default : .none
        switch (indexPath.section, indexPath.row) {
        case (0, 0): cell.detailTextLabel?.text = musicSize
        case (0, 1): cell.detailTextLabel?.text = cacheSize
        case (1, 0): cell.textLabel?.textColor = .red
        case (1, _): cell.textLabel?.textColor = view.tintColor
        default:
            cell.detailTextLabel?.text = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 1 else { return }
        switch indexPath.row {
        case 0:
            let sheet = UIAlertController(title: "Clear cache?", message: "Removes cached artwork, repository data and temporary files. Music and extensions are kept.",
                                          preferredStyle: .actionSheet)
            sheet.addAction(UIAlertAction(title: "Clear cache", style: .destructive) { _ in self.clearCache() })
            sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            present(sheet, from: tableView.cellForRow(at: indexPath))
        case 1:
            LibraryStore.shared.scan { self.measure(); self.alert("Library rescanned", "\(LibraryStore.shared.items.count) songs") }
        default:
            DownloadManager.shared.clearFinished()
        }
    }
}
