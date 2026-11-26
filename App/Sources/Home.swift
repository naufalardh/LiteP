import UIKit

/// Spotify-style home: quick tiles, recently added albums and playlists.
final class HomeViewController: UICollectionViewController, UICollectionViewDelegateFlowLayout {
    private struct Tile { let title: String; let subtitle: String; let cover: String?; let icon: Icon; let round: Bool; let open: () -> UIViewController }

    private var sections: [(String, [Tile])] = []

    init() { super.init(collectionViewLayout: UICollectionViewFlowLayout()) }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.alwaysBounceVertical = true
        collectionView.register(TileCell.self, forCellWithReuseIdentifier: "tile")
        collectionView.register(CardCell.self, forCellWithReuseIdentifier: "card")
        collectionView.register(SectionTitle.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
                                withReuseIdentifier: "h")
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: Icon.settings.image(22), style: .plain, target: self,
                                                            action: #selector(openExtensions))
        for n in [Lite.libraryChanged, PlaylistStore.changed] {
            NotificationCenter.default.addObserver(self, selector: #selector(reload), name: n, object: nil)
        }
        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        let hour = Calendar.current.component(.hour, from: Date())
        title = hour < 5 ? "Good night" : hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        collectionView.collectionViewLayout.invalidateLayout()
    }

    @objc private func openExtensions() {
        navigationController?.pushViewController(ExtensionsViewController(style: .grouped), animated: true)
    }

    @objc private func reload() {
        let albums = albumGroups(LibraryStore.shared.items)
            .sorted { ($0.map { $0.modified }.max() ?? 0) > ($1.map { $0.modified }.max() ?? 0) }
        let albumTiles = albums.prefix(12).map { items in
            Tile(title: items[0].albumName, subtitle: items[0].artistName, cover: items.first { $0.coverPath != nil }?.coverPath,
                 icon: .music, round: false, open: { SongListViewController.album(items[0]) })
        }
        let playlistTiles = PlaylistStore.shared.playlists.map { p -> Tile in
            let items = PlaylistStore.shared.items(p.id)
            return Tile(title: p.name, subtitle: "Playlist · \(songCount(items.count))", cover: items.first { $0.coverPath != nil }?.coverPath,
                        icon: .list, round: false, open: { SongListViewController(playlist: p.id) })
        }
        var artists: [String] = []
        for album in albums where !artists.contains(album[0].artistName) { artists.append(album[0].artistName) }
        let artistTiles = artists.prefix(8).map { name -> Tile in
            let cover = LibraryStore.shared.items.first { $0.artistName == name && $0.coverPath != nil }?.coverPath
            return Tile(title: name, subtitle: "Artist", cover: cover, icon: .person, round: true, open: { SongListViewController.artist(name) })
        }
        sections = [("", Array((playlistTiles + albumTiles).prefix(6))), ("Recently added", Array(albumTiles)),
                    ("Your playlists", playlistTiles), ("Your artists", Array(artistTiles))].filter { !$0.1.isEmpty }
        collectionView.backgroundView = sections.isEmpty ? Theme.emptyLabel(
            "Nothing here yet.\n\nAdd a repository and extensions with the button at the top right, then find music in Search.") : nil
        collectionView.reloadData()
    }

    private var hasShortcuts: Bool { sections.first?.0 == "" }

    private func columns(_ width: CGFloat) -> CGFloat { width >= 900 ? 5 : width >= 600 ? 4 : 2 }

    override func numberOfSections(in collectionView: UICollectionView) -> Int { sections.count }

    override func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { sections[section].1.count }

    override func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let tile = sections[indexPath.section].1[indexPath.item]
        if indexPath.section == 0 && hasShortcuts {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "tile", for: indexPath) as! TileCell
            cell.label.text = tile.title
            Art.set(cell.art, path: tile.cover, size: 56, placeholder: tile.icon)
            return cell
        }
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "card", for: indexPath) as! CardCell
        cell.title.text = tile.title
        cell.subtitle.text = tile.subtitle
        cell.round = tile.round
        Art.set(cell.art, path: tile.cover, size: 180, placeholder: tile.icon)
        return cell
    }

    override func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String,
                                 at indexPath: IndexPath) -> UICollectionReusableView {
        let v = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: "h", for: indexPath) as! SectionTitle
        v.label.text = sections[indexPath.section].0
        return v
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        navigationController?.pushViewController(sections[indexPath.section].1[indexPath.item].open(), animated: true)
    }

    func collectionView(_ collectionView: UICollectionView, layout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let w = collectionView.bounds.width - 32
        if indexPath.section == 0 && hasShortcuts {
            let n: CGFloat = w >= 600 ? 3 : 2
            return CGSize(width: floor((w - (n - 1) * 8) / n), height: 56)
        }
        let n = columns(w)
        let side = floor((w - (n - 1) * 16) / n)
        return CGSize(width: side, height: side + 48)
    }

    func collectionView(_ collectionView: UICollectionView, layout: UICollectionViewLayout, insetForSectionAt section: Int) -> UIEdgeInsets {
        UIEdgeInsets(top: 4, left: 16, bottom: 16, right: 16)
    }

    func collectionView(_ collectionView: UICollectionView, layout: UICollectionViewLayout, minimumLineSpacingForSectionAt section: Int) -> CGFloat {
        section == 0 && hasShortcuts ? 8 : 16
    }

    func collectionView(_ collectionView: UICollectionView, layout: UICollectionViewLayout,
                        minimumInteritemSpacingForSectionAt section: Int) -> CGFloat { 8 }

    func collectionView(_ collectionView: UICollectionView, layout: UICollectionViewLayout,
                        referenceSizeForHeaderInSection section: Int) -> CGSize {
        CGSize(width: collectionView.bounds.width, height: sections[section].0.isEmpty ? 8 : 52)
    }
}

private final class TileCell: UICollectionViewCell {
    let art = UIImageView()
    let label = Theme.label(13, .bold)

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = Theme.elevated
        contentView.layer.cornerRadius = 4
        contentView.clipsToBounds = true
        art.clipsToBounds = true
        art.backgroundColor = UIColor(white: 0.22, alpha: 1)
        label.numberOfLines = 2
        contentView.addSubview(art)
        contentView.addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let h = contentView.bounds.height
        art.frame = CGRect(x: 0, y: 0, width: h, height: h)
        label.frame = CGRect(x: h + 10, y: 0, width: contentView.bounds.width - h - 16, height: h)
    }
}

private final class CardCell: UICollectionViewCell {
    let art = UIImageView()
    let title = Theme.label(14, .semibold)
    let subtitle = Theme.label(12, .regular, Theme.subtext)
    var round = false { didSet { setNeedsLayout() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        art.clipsToBounds = true
        art.backgroundColor = Theme.elevated
        [art, title, subtitle].forEach { contentView.addSubview($0) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = contentView.bounds.width
        art.frame = CGRect(x: 0, y: 0, width: w, height: w)
        art.layer.cornerRadius = round ? w / 2 : 4
        title.textAlignment = round ? .center : .left
        subtitle.textAlignment = title.textAlignment
        title.frame = CGRect(x: 0, y: w + 8, width: w, height: 18)
        subtitle.frame = CGRect(x: 0, y: w + 27, width: w, height: 16)
    }
}

private final class SectionTitle: UICollectionReusableView {
    let label = Theme.label(22, .bold)

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = CGRect(x: 16, y: bounds.height - 40, width: bounds.width - 32, height: 30)
    }
}
