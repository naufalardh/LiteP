import ImageIO
import UIKit

/// Spotify-like dark look, drawn with plain UIKit (no blur, no heavy animation).
enum Theme {
    static let bg = UIColor(white: 0.07, alpha: 1)
    static let elevated = UIColor(white: 0.16, alpha: 1)
    static let text = UIColor.white
    static let subtext = UIColor(white: 0.70, alpha: 1)
    static let green = UIColor(red: 0.11, green: 0.73, blue: 0.33, alpha: 1)
    static let red = UIColor(red: 0.95, green: 0.36, blue: 0.36, alpha: 1)

    static func apply(_ window: UIWindow?) {
        window?.backgroundColor = bg
        window?.tintColor = green
        let nav = UINavigationBar.appearance()
        nav.barStyle = .black
        nav.isTranslucent = false
        nav.barTintColor = bg
        nav.tintColor = text
        nav.setBackgroundImage(fill(bg), for: .default)
        nav.shadowImage = UIImage()
        nav.titleTextAttributes = [.foregroundColor: text, .font: UIFont.boldSystemFont(ofSize: 17)]
        nav.largeTitleTextAttributes = [.foregroundColor: text, .font: UIFont.systemFont(ofSize: 30, weight: .heavy)]
        UITableView.appearance().backgroundColor = bg
        UITableView.appearance().separatorColor = UIColor(white: 0.18, alpha: 1)
        UITableView.appearance().sectionIndexColor = subtext
        UITableViewCell.appearance().backgroundColor = bg
        UILabel.appearance(whenContainedInInstancesOf: [UITableViewHeaderFooterView.self]).textColor = subtext
        UICollectionView.appearance().backgroundColor = bg
        UITextField.appearance().keyboardAppearance = .dark
        UISearchBar.appearance().setSearchFieldBackgroundImage(rounded(.white, height: 36), for: .normal)
        UISearchBar.appearance().searchTextPositionAdjustment = UIOffset(horizontal: 6, vertical: 0)
        UITextField.appearance(whenContainedInInstancesOf: [UISearchBar.self]).defaultTextAttributes =
            [.foregroundColor: UIColor.black, .font: UIFont.systemFont(ofSize: 15, weight: .medium)]
        UISwitch.appearance().onTintColor = green
        UIRefreshControl.appearance().tintColor = subtext
        UIProgressView.appearance().progressTintColor = green
        UIProgressView.appearance().trackTintColor = elevated
    }

    static func style(_ cell: UITableViewCell) {
        cell.backgroundColor = bg
        cell.tintColor = green
        cell.textLabel?.textColor = text
        cell.detailTextLabel?.textColor = subtext
        let selected = UIView()
        selected.backgroundColor = elevated
        cell.selectedBackgroundView = selected
    }

    static func fill(_ color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in
            color.setFill()
            UIRectFill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
    }

    static func rounded(_ color: UIColor, height: CGFloat) -> UIImage {
        let r = height / 2
        let image = UIGraphicsImageRenderer(size: CGSize(width: height + 2, height: height)).image { _ in
            color.setFill()
            UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: height + 2, height: height), cornerRadius: 6).fill()
        }
        return image.resizableImage(withCapInsets: UIEdgeInsets(top: r, left: r, bottom: r, right: r))
    }

    static func label(_ size: CGFloat, _ weight: UIFont.Weight, _ color: UIColor = text) -> UILabel {
        let l = UILabel()
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        return l
    }

    /// Green circle button with a black icon, like Spotify's play button.
    static func circleButton(_ icon: Icon, size: CGFloat, color: UIColor = green) -> UIButton {
        let b = UIButton(type: .custom)
        b.backgroundColor = color
        b.layer.cornerRadius = size / 2
        b.setImage(icon.image(size * 0.42, .black), for: .normal)
        b.frame.size = CGSize(width: size, height: size)
        return b
    }

    static func iconButton(_ icon: Icon, size: CGFloat = 26, color: UIColor = subtext) -> UIButton {
        let b = UIButton(type: .custom)
        b.setImage(icon.image(size, color), for: .normal)
        b.frame.size = CGSize(width: 44, height: 44)
        return b
    }

    static func emptyLabel(_ text: String) -> UILabel {
        let l = label(15, .regular, subtext)
        l.text = text
        l.numberOfLines = 0
        l.textAlignment = .center
        return l
    }
}

private func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

/// Line icons drawn in code (iOS 12 has no SF Symbols); 24×24 design grid.
enum Icon {
    case home, search, library, download, settings, play, pause, next, previous, shuffle, repeatAll, repeatOne
    case more, down, plus, music, person, list

    func image(_ size: CGFloat = 24, _ color: UIColor = .white) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { ctx in
            ctx.cgContext.scaleBy(x: size / 24, y: size / 24)
            color.setStroke()
            color.setFill()
            let p = UIBezierPath()
            p.lineWidth = 2
            p.lineCapStyle = .round
            p.lineJoinStyle = .round
            func line(_ points: [CGPoint]) {
                p.move(to: points[0])
                points.dropFirst().forEach { p.addLine(to: $0) }
            }
            func dot(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) {
                UIBezierPath(ovalIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)).fill()
            }
            switch self {
            case .home:
                line([P(3, 11), P(12, 3), P(21, 11)])
                line([P(5, 9.5), P(5, 21), P(10, 21), P(10, 15), P(14, 15), P(14, 21), P(19, 21), P(19, 9.5)])
            case .search:
                p.append(UIBezierPath(ovalIn: CGRect(x: 4, y: 4, width: 13, height: 13)))
                line([P(15.5, 15.5), P(21, 21)])
            case .library:
                line([P(5, 3), P(5, 21)])
                line([P(10, 3), P(10, 21)])
                line([P(14, 4), P(20, 20.5)])
            case .download:
                p.append(UIBezierPath(ovalIn: CGRect(x: 3, y: 3, width: 18, height: 18)))
                line([P(12, 7), P(12, 16.5)])
                line([P(8, 12.5), P(12, 16.5), P(16, 12.5)])
            case .settings:
                for (y, x) in [(6, 8), (12, 16), (18, 10)] as [(CGFloat, CGFloat)] {
                    line([P(3, y), P(21, y)])
                    dot(x, y, 2.6)
                }
            case .play:
                let t = UIBezierPath()
                t.move(to: P(7, 4)); t.addLine(to: P(20, 12)); t.addLine(to: P(7, 20)); t.close(); t.fill()
            case .pause:
                UIBezierPath(roundedRect: CGRect(x: 6, y: 4, width: 4, height: 16), cornerRadius: 1).fill()
                UIBezierPath(roundedRect: CGRect(x: 14, y: 4, width: 4, height: 16), cornerRadius: 1).fill()
            case .next:
                let t = UIBezierPath()
                t.move(to: P(5, 5)); t.addLine(to: P(15, 12)); t.addLine(to: P(5, 19)); t.close(); t.fill()
                UIBezierPath(rect: CGRect(x: 16.5, y: 5, width: 2.5, height: 14)).fill()
            case .previous:
                let t = UIBezierPath()
                t.move(to: P(19, 5)); t.addLine(to: P(9, 12)); t.addLine(to: P(19, 19)); t.close(); t.fill()
                UIBezierPath(rect: CGRect(x: 5, y: 5, width: 2.5, height: 14)).fill()
            case .shuffle:
                line([P(3, 17), P(8, 17), P(16, 7), P(21, 7)])
                line([P(3, 7), P(8, 7), P(10.5, 10)])
                line([P(13.5, 14), P(16, 17), P(21, 17)])
                line([P(18, 4), P(21, 7), P(18, 10)])
                line([P(18, 14), P(21, 17), P(18, 20)])
            case .repeatAll, .repeatOne:
                p.append(UIBezierPath(roundedRect: CGRect(x: 3, y: 6, width: 18, height: 12), cornerRadius: 4))
                line([P(13, 3), P(16, 6), P(13, 9)])
                if case .repeatOne = self { dot(12, 12, 2.2) }
            case .more:
                dot(5, 12, 1.9); dot(12, 12, 1.9); dot(19, 12, 1.9)
            case .down:
                line([P(5, 9), P(12, 16), P(19, 9)])
            case .plus:
                line([P(12, 4), P(12, 20)])
                line([P(4, 12), P(20, 12)])
            case .music:
                line([P(10, 17), P(10, 4), P(19, 2.5), P(19, 15)])
                dot(7.5, 17.5, 2.8); dot(16.5, 15.5, 2.8)
            case .person:
                p.append(UIBezierPath(ovalIn: CGRect(x: 8, y: 3, width: 8, height: 8)))
                p.move(to: P(4, 21))
                p.addCurve(to: P(20, 21), controlPoint1: P(4, 12), controlPoint2: P(20, 12))
            case .list:
                for y in [6, 12, 18] as [CGFloat] { line([P(4, y), P(20, y)]) }
            }
            p.stroke()
        }
    }
}

/// Downsampled artwork from a local file or a remote URL, cached in memory with a small budget.
enum Art {
    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.totalCostLimit = 12 * 1024 * 1024
        return c
    }()
    private static let queue = DispatchQueue(label: "mornye.art", qos: .userInitiated, attributes: .concurrent)

    static func set(_ view: UIImageView, path: String?, url: String? = nil, size: CGFloat, placeholder: Icon = .music) {
        let source = path ?? url ?? ""
        let key = "\(source)#\(Int(size))"
        view.accessibilityIdentifier = key
        if let hit = cache.object(forKey: key as NSString) {
            view.contentMode = .scaleAspectFill
            view.image = hit
            return
        }
        view.contentMode = .center
        view.image = placeholder.image(max(18, size * 0.38), Theme.subtext)
        guard !source.isEmpty else { return }
        let pixels = size * UIScreen.main.scale
        let finish: (UIImage?) -> Void = { image in
            guard let image = image else { return }
            cache.setObject(image, forKey: key as NSString, cost: Int(pixels * pixels * 4))
            DispatchQueue.main.async {
                guard view.accessibilityIdentifier == key else { return }
                view.contentMode = .scaleAspectFill
                view.image = image
            }
        }
        if let path = path {
            queue.async { finish(thumb(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil), pixels)) }
        } else if let remote = URL(string: source) {
            URLSession.shared.dataTask(with: remote) { data, _, _ in
                finish(data.flatMap { thumb(CGImageSourceCreateWithData($0 as CFData, nil), pixels) })
            }.resume()
        }
    }

    static func image(_ path: String?, size: CGFloat) -> UIImage? {
        guard let path = path else { return nil }
        return thumb(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil), size * UIScreen.main.scale)
    }

    private static func thumb(_ source: CGImageSource?, _ pixels: CGFloat) -> UIImage? {
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: pixels,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        guard let source = source, let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg, scale: UIScreen.main.scale, orientation: .up)
    }

    /// Average color of an image, for the player's background gradient.
    static func tint(_ image: UIImage?) -> UIColor {
        guard let cg = image?.cgImage else { return Theme.elevated }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return Theme.elevated }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let k: CGFloat = 0.75 / 255
        return UIColor(red: CGFloat(pixel[0]) * k, green: CGFloat(pixel[1]) * k, blue: CGFloat(pixel[2]) * k, alpha: 1)
    }
}

/// Row with square (or round) artwork, title, subtitle and an optional "…" button.
final class ArtCell: UITableViewCell {
    let art = UIImageView()
    let titleLabel = Theme.label(16, .medium)
    let subtitleLabel = Theme.label(13, .regular, Theme.subtext)
    private let moreButton = UIButton(type: .custom)
    var onMore: ((UIView) -> Void)? { didSet { moreButton.isHidden = onMore == nil; setNeedsLayout() } }
    var round = false { didSet { setNeedsLayout() } }
    var showsArt = true { didSet { setNeedsLayout() } }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: .default, reuseIdentifier: reuseIdentifier)
        Theme.style(self)
        art.clipsToBounds = true
        art.backgroundColor = Theme.elevated
        moreButton.setImage(Icon.more.image(20, Theme.subtext), for: .normal)
        moreButton.addTarget(self, action: #selector(moreTapped), for: .touchUpInside)
        moreButton.isHidden = true
        [art, titleLabel, subtitleLabel, moreButton].forEach { contentView.addSubview($0) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(_ title: String, _ subtitle: String?, playing: Bool = false) {
        titleLabel.text = title
        subtitleLabel.text = subtitle
        titleLabel.textColor = playing ? Theme.green : Theme.text
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let h = contentView.bounds.height, w = contentView.bounds.width
        let side = showsArt ? h - 14 : 0
        art.isHidden = !showsArt
        art.frame = CGRect(x: 16, y: 7, width: side, height: side)
        art.layer.cornerRadius = round ? side / 2 : 3
        let x = showsArt ? art.frame.maxX + 12 : 16
        moreButton.frame = CGRect(x: w - 48, y: 0, width: 44, height: h)
        let right = moreButton.isHidden ? w - 12 : w - 50
        let hasSubtitle = !(subtitleLabel.text ?? "").isEmpty
        titleLabel.frame = CGRect(x: x, y: hasSubtitle ? h / 2 - 21 : h / 2 - 11, width: right - x, height: 22)
        subtitleLabel.frame = CGRect(x: x, y: h / 2 + 1, width: right - x, height: 18)
    }

    @objc private func moreTapped() { onMore?(moreButton) }

    override func prepareForReuse() {
        super.prepareForReuse()
        onMore = nil
        round = false
        showsArt = true
        accessoryType = .none
        accessoryView = nil
    }
}

/// Horizontal filter chips (Playlists / Artists / Albums …).
final class PillBar: UIScrollView {
    private(set) var selected: Int
    var changed: ((Int) -> Void)?
    private var buttons: [UIButton] = []

    init(_ titles: [String], selected: Int = 0) {
        self.selected = selected
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: 52))
        autoresizingMask = .flexibleWidth
        showsHorizontalScrollIndicator = false
        backgroundColor = Theme.bg
        var x: CGFloat = 16
        for (i, title) in titles.enumerated() {
            let b = UIButton(type: .custom)
            b.setTitle(title, for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
            b.contentEdgeInsets = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
            b.layer.cornerRadius = 16
            b.layer.borderWidth = 1
            b.tag = i
            b.addTarget(self, action: #selector(tap(_:)), for: .touchUpInside)
            b.sizeToFit()
            b.frame = CGRect(x: x, y: 10, width: b.bounds.width, height: 32)
            x += b.bounds.width + 8
            addSubview(b)
            buttons.append(b)
        }
        contentSize = CGSize(width: x + 8, height: 52)
        choose(selected)
    }

    required init?(coder: NSCoder) { fatalError() }

    func choose(_ index: Int) {
        selected = index
        for b in buttons {
            let on = b.tag == index
            b.backgroundColor = on ? Theme.green : .clear
            b.setTitleColor(on ? .black : Theme.text, for: .normal)
            b.layer.borderColor = (on ? Theme.green : UIColor(white: 0.42, alpha: 1)).cgColor
        }
    }

    @objc private func tap(_ b: UIButton) {
        choose(b.tag)
        changed?(b.tag)
    }
}

/// Album / artist / playlist header: big artwork, title, subtitle, shuffle and a green action button.
final class DetailHeader: UIView {
    let art = UIImageView()
    let titleLabel = Theme.label(26, .heavy)
    let subtitleLabel = Theme.label(14, .regular, Theme.subtext)
    let action: UIButton
    let shuffle = Theme.iconButton(.shuffle, size: 26)
    let extra = Theme.iconButton(.plus, size: 26)
    private let round: Bool

    init(width: CGFloat, round: Bool, action icon: Icon = .play) {
        self.round = round
        action = Theme.circleButton(icon, size: 56)
        super.init(frame: CGRect(x: 0, y: 0, width: width, height: 0))
        art.clipsToBounds = true
        art.backgroundColor = Theme.elevated
        titleLabel.numberOfLines = 2
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.7
        extra.isHidden = true
        [art, titleLabel, subtitleLabel, action, shuffle, extra].forEach { addSubview($0) }
        frame.size.height = layout(width)
    }

    required init?(coder: NSCoder) { fatalError() }

    @discardableResult
    func layout(_ width: CGFloat) -> CGFloat {
        let side = min(220, width * 0.55)
        art.frame = CGRect(x: (width - side) / 2, y: 20, width: side, height: side)
        art.layer.cornerRadius = round ? side / 2 : 4
        titleLabel.frame = CGRect(x: 16, y: art.frame.maxY + 18, width: width - 32, height: 64)
        titleLabel.sizeToFit()
        titleLabel.frame.size.width = width - 32
        subtitleLabel.frame = CGRect(x: 16, y: titleLabel.frame.maxY + 6, width: width - 32, height: 18)
        let y = subtitleLabel.frame.maxY + 10
        action.frame.origin = CGPoint(x: width - 16 - 56, y: y)
        shuffle.frame.origin = CGPoint(x: 6, y: y + 6)
        extra.frame.origin = CGPoint(x: 50, y: y + 6)
        return y + 56 + 12
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layout(bounds.width)
    }
}
