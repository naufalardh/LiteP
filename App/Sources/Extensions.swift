import UIKit

final class ExtensionsViewController: UITableViewController {
    private var catalog: [[String: Any]] = []
    private var status = ""

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Extensions"
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.rightBarButtonItems = [UIBarButtonItem(title: "Refresh", style: .plain, target: self, action: #selector(refreshCatalog)),
                                              editButtonItem]
        NotificationCenter.default.addObserver(tableView!, selector: #selector(UITableView.reloadData), name: Lite.extensionsChanged, object: nil)
        refreshCatalog()
    }

    @objc private func refreshCatalog() {
        guard !Lite.shared.repoURLs.isEmpty else { catalog = []; tableView.reloadData(); return }
        status = "Loading…"
        tableView.reloadData()
        Lite.shared.call("getRepoCatalog", ["force_refresh": true]) { [weak self] value, error in
            guard let self = self else { return }
            let map = jsonMap(value)
            self.catalog = map["extensions"] as? [[String: Any]] ?? []
            let errors = (map["sources"] as? [[String: Any]] ?? []).map { $0.str("error") }.filter { !$0.isEmpty }
            self.status = error?.localizedDescription ?? errors.joined(separator: "\n")
            self.tableView.reloadData()
        }
    }

    private func addRepo() {
        let a = UIAlertController(title: "Add repository", message: "Repository URL", preferredStyle: .alert)
        a.addTextField { $0.keyboardType = .URL; $0.autocapitalizationType = .none; $0.placeholder = "https://…" }
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        a.addAction(UIAlertAction(title: "Add", style: .default) { _ in
            let url = (a.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty else { return }
            Lite.shared.call("resolveRepoRegistryUrl", ["registry_url": url]) { value, error in
                if let error = error { self.alert("Invalid repository", error.localizedDescription); return }
                let resolved = (value as? String ?? url).trimmingCharacters(in: .whitespaces)
                self.setRepos(Lite.shared.repoURLs.filter { $0 != resolved } + [resolved])
            }
        })
        present(a, animated: true)
    }

    private func setRepos(_ urls: [String]) {
        Lite.shared.repoURLs = urls
        Lite.shared.call("setRepoRegistryUrls", ["registry_urls": urls]) { _, error in
            if let error = error { self.alert("Repository error", error.localizedDescription) }
            self.refreshCatalog()
        }
    }

    private func install(_ entry: [String: Any]) {
        let id = entry.str("id")
        let dest = Lite.shared.cache.appendingPathComponent("packages", isDirectory: true)
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let upgrade = entry["is_installed"] as? Bool ?? false
        status = "Installing \(entry.extName)…"
        tableView.reloadData()
        Lite.shared.queue.async {
            var failure: String?
            do {
                let path = try Lite.shared.invoke("downloadRepoExtension", ["extension_id": id, "dest_dir": dest.path,
                                                                           "registry_url": entry.str("registry_url")]) as? String ?? ""
                _ = try Lite.shared.invoke(upgrade ? "upgradeExtension" : "loadExtensionFromPath", ["file_path": path])
                try? FileManager.default.removeItem(atPath: path)
                try Lite.shared.reloadExtensionsSync()
            } catch {
                failure = error.localizedDescription
            }
            DispatchQueue.main.async {
                self.status = ""
                if let failure = failure { self.alert("Install failed", failure) }
                self.refreshCatalog()
            }
        }
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 3 }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        ["Repositories", "Installed", "Available"][section]
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 2 && !status.isEmpty ? status : nil
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0: return Lite.shared.repoURLs.count + 1
        case 1: return Lite.shared.extensions.count
        default: return catalog.count
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        Theme.style(cell)
        cell.backgroundColor = UIColor(white: 0.11, alpha: 1)
        switch indexPath.section {
        case 0:
            let urls = Lite.shared.repoURLs
            if indexPath.row < urls.count {
                cell.textLabel?.text = urls[indexPath.row]
                cell.selectionStyle = .none
            } else {
                cell.textLabel?.text = "Add repository…"
                cell.textLabel?.textColor = view.tintColor
            }
        case 1:
            let ext = Lite.shared.extensions[indexPath.row]
            cell.textLabel?.text = ext.extName
            var caps: [String] = []
            if ext["has_download_provider"] as? Bool == true { caps.append("download") }
            if ext["has_metadata_provider"] as? Bool == true { caps.append("metadata") }
            let state = ext.str("status")
            cell.detailTextLabel?.text = ([ext.str("version")] + caps + (state.isEmpty || state == "loaded" ? [] : [state])).joined(separator: " · ")
            let toggle = UISwitch()
            toggle.isOn = ext["enabled"] as? Bool ?? false
            toggle.tag = indexPath.row
            toggle.addTarget(self, action: #selector(toggled(_:)), for: .valueChanged)
            cell.accessoryView = toggle
        default:
            let entry = catalog[indexPath.row]
            cell.textLabel?.text = entry.extName
            let installed = entry["is_installed"] as? Bool ?? false
            let update = entry["has_update"] as? Bool ?? false
            let tag = update ? "Update available" : installed ? "Installed" : "Tap to install"
            cell.detailTextLabel?.text = "\(entry.str("version")) · \(tag) · \(entry.str("description"))"
            cell.selectionStyle = installed && !update ? .none : .default
        }
        return cell
    }

    @objc private func toggled(_ sender: UISwitch) {
        let ext = Lite.shared.extensions[sender.tag]
        Lite.shared.call("setExtensionEnabled", ["extension_id": ext.str("id"), "enabled": sender.isOn]) { _, error in
            if let error = error { self.alert("Error", error.localizedDescription) }
            Lite.shared.reloadExtensions()
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 0, indexPath.row == Lite.shared.repoURLs.count { addRepo() }
        if indexPath.section == 1 {
            let ext = Lite.shared.extensions[indexPath.row]
            let sheet = UIAlertController(title: ext.extName, message: nil, preferredStyle: .actionSheet)
            sheet.addAction(UIAlertAction(title: "Delete extension", style: .destructive) { _ in self.removeExtension(ext.str("id")) })
            sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            sheet.popoverPresentationController?.sourceView = tableView
            sheet.popoverPresentationController?.sourceRect = tableView.rectForRow(at: indexPath)
            present(sheet, animated: true)
        }
        if indexPath.section == 2 {
            let entry = catalog[indexPath.row]
            if !(entry["is_installed"] as? Bool ?? false) || (entry["has_update"] as? Bool ?? false) { install(entry) }
        }
    }

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        indexPath.section == 1 || (indexPath.section == 0 && indexPath.row < Lite.shared.repoURLs.count)
    }

    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete else { return }
        if indexPath.section == 0 {
            var urls = Lite.shared.repoURLs
            urls.remove(at: indexPath.row)
            setRepos(urls)
            tableView.reloadData()
        } else {
            removeExtension(Lite.shared.extensions[indexPath.row].str("id"))
        }
    }

    private func removeExtension(_ id: String) {
        Lite.shared.call("removeExtension", ["extension_id": id]) { _, error in
            if let error = error { self.alert("Error", error.localizedDescription) }
            Lite.shared.reloadExtensions()
            self.refreshCatalog()
        }
    }
}
