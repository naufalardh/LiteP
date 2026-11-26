import UIKit

final class SettingsViewController: UITableViewController {
    private var musicSize = "…"
    private var cacheSize = "…"
    private let rows = [["Extensions & repositories"], ["Search with", "Download with", "Quality"], ["Crossfade", "Gapless playback"],
                        ["Music", "Cache"], ["Clear cache", "Rescan library", "Clear finished downloads"], ["Version"]]

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Settings"
        NotificationCenter.default.addObserver(tableView!, selector: #selector(UITableView.reloadData), name: Lite.extensionsChanged, object: nil)
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

    private var downloadExtension: [String: Any]? {
        Lite.shared.downloadExtensions.first { $0.str("id") == Defaults.downloadProvider }
    }

    private var qualityOptions: [[String: Any]] { downloadExtension?["quality_options"] as? [[String: Any]] ?? [] }

    private func label(_ option: [String: Any]) -> String { option.str("label").isEmpty ? option.str("id") : option.str("label") }

    private func detail(_ indexPath: IndexPath) -> String? {
        switch (indexPath.section, indexPath.row) {
        case (1, 0): return Lite.shared.searchExtensions.first { $0.str("id") == Defaults.searchSource }?.extName ?? "All sources"
        case (1, 1): return downloadExtension?.extName ?? "Ask every time"
        case (1, 2):
            guard downloadExtension != nil else { return "Pick a download extension" }
            if qualityOptions.count <= 1 { return qualityOptions.first.map(label) ?? "Default" }
            return qualityOptions.first { $0.str("id") == Defaults.quality }.map(label) ?? "Ask every time"
        case (2, 0): return Player.crossfade == 0 ? "Off" : "\(Player.crossfade) s"
        case (3, 0): return musicSize
        case (3, 1): return cacheSize
        case (5, 0): return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        default: return nil
        }
    }

    override func numberOfSections(in tableView: UITableView) -> Int { rows.count }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rows[section].count }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        [nil, "Defaults", "Playback", "Storage", nil, "About"][section]
    }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch section {
        case 1: return "With a download extension and quality set, one tap on a song starts the download."
        case 2: return "Crossfade blends the end of a song into the next. Gapless is used only when crossfade is off."
        default: return nil
        }
    }
    @objc private func gaplessChanged(_ toggle: UISwitch) { Player.gapless = toggle.isOn }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        Theme.style(cell)
        cell.backgroundColor = UIColor(white: 0.11, alpha: 1)
        cell.textLabel?.text = rows[indexPath.section][indexPath.row]
        cell.detailTextLabel?.text = detail(indexPath)
        cell.selectionStyle = [3, 5].contains(indexPath.section) ? .none : .default
        switch (indexPath.section, indexPath.row) {
        case (0, _), (1, _): cell.accessoryType = .disclosureIndicator
        case (2, 1):
            let toggle = UISwitch()
            toggle.isOn = Player.gapless
            toggle.addTarget(self, action: #selector(gaplessChanged(_:)), for: .valueChanged)
            cell.accessoryView = toggle
            cell.selectionStyle = .none
        case (4, 0): cell.textLabel?.textColor = Theme.red
        case (4, _): cell.textLabel?.textColor = Theme.green
        default: break
        }
        return cell
    }

    private func choose(_ title: String, _ options: [(String, () -> Void)], from indexPath: IndexPath) {
        let sheet = UIAlertController(title: title, message: nil, preferredStyle: .actionSheet)
        for (name, action) in options {
            sheet.addAction(UIAlertAction(title: name, style: .default) { _ in
                action()
                self.tableView.reloadData()
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(sheet, from: tableView.cellForRow(at: indexPath))
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch (indexPath.section, indexPath.row) {
        case (0, _):
            navigationController?.pushViewController(ExtensionsViewController(style: .grouped), animated: true)
        case (1, 0):
            choose("Search with", [("All sources", { Defaults.searchSource = "" })] + Lite.shared.searchExtensions.map { ext in
                (ext.extName, { Defaults.searchSource = ext.str("id") })
            }, from: indexPath)
        case (1, 1):
            choose("Download with", [("Ask every time", { Defaults.downloadProvider = ""; Defaults.quality = "" })]
                + Lite.shared.downloadExtensions.map { ext in
                    (ext.extName, { Defaults.downloadProvider = ext.str("id"); Defaults.quality = "" })
                }, from: indexPath)
        case (1, 2):
            guard qualityOptions.count > 1 else { return }
            choose("Quality", [("Ask every time", { Defaults.quality = "" })] + qualityOptions.map { option in
                (label(option), { Defaults.quality = option.str("id") })
            }, from: indexPath)
        case (2, 0):
            choose("Crossfade", [("Off", { Player.crossfade = 0 })] + (1...8).map { n in ("\(n) seconds", { Player.crossfade = n }) },
                   from: indexPath)
        case (4, 0):
            let sheet = UIAlertController(title: "Clear cache?", message: "Removes cached artwork, repository data and temporary files. Music and extensions are kept.",
                                          preferredStyle: .actionSheet)
            sheet.addAction(UIAlertAction(title: "Clear cache", style: .destructive) { _ in self.clearCache() })
            sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            present(sheet, from: tableView.cellForRow(at: indexPath))
        case (4, 1):
            LibraryStore.shared.scan { self.measure(); self.alert("Library rescanned", "\(LibraryStore.shared.items.count) songs") }
        case (4, 2):
            DownloadManager.shared.clearFinished()
        default:
            break
        }
    }
}
