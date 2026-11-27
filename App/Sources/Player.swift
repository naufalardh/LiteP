import AVFoundation
import MediaPlayer
import UIKit

final class Player: NSObject {
    static let shared = Player()
    static let changed = Notification.Name("LitePlayerChanged")

    /// Preloads the next song in AVQueuePlayer so it starts without a pause.
    static var gapless: Bool {
        get { UserDefaults.standard.object(forKey: "gapless") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "gapless")
            shared.preloadNext()
        }
    }

    /// Crossfade length in seconds (0 = off). When on, the next song starts on the second player while volumes ramp.
    static var crossfade: Int {
        get { UserDefaults.standard.integer(forKey: "crossfade") }
        set {
            UserDefaults.standard.set(newValue, forKey: "crossfade")
            shared.preloadNext()
        }
    }

    private let players = [AVQueuePlayer(), AVQueuePlayer()]
    private var active = 0
    private var player: AVQueuePlayer { players[active] }
    private var outgoing: AVQueuePlayer?
    private var fadeTimer: Timer?
    private var statusObserver: NSKeyValueObservation?
    private var itemObservers: [NSKeyValueObservation] = []
    private var timeObservers: [Any] = []
    private var playing: AVPlayerItem?
    private var preloaded: AVPlayerItem?
    private var preloadedIndex = 0
    private var original: [LibraryItem] = []
    private(set) var queue: [LibraryItem] = []
    private(set) var index = 0
    private(set) var shuffled = false
    /// 0 off, 1 repeat queue, 2 repeat song.
    private(set) var repeatMode = 0
    var current: LibraryItem? { queue.indices.contains(index) ? queue[index] : nil }
    var upNext: [LibraryItem] { Array(queue.dropFirst(index + 1)) }
    var isPlaying: Bool { player.rate > 0 }
    var position: Double { player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0 }
    var duration: Double { player.currentItem?.duration.seconds.isFinite == true ? player.currentItem!.duration.seconds : 0 }

    private override init() {
        super.init()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
        NotificationCenter.default.addObserver(self, selector: #selector(ended), name: .AVPlayerItemDidPlayToEndTime, object: nil)
        for p in players {
            itemObservers.append(p.observe(\.currentItem) { [weak self] _, _ in
                DispatchQueue.main.async { self?.advanced() }
            })
            timeObservers.append(p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) {
                [weak self, weak p] _ in
                guard let self = self, p === self.player else { return }
                self.checkCrossfade()
            })
        }
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in self?.resume(); return .success }
        center.pauseCommand.addTarget { [weak self] _ in self?.pause(); return .success }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in self?.toggle(); return .success }
        center.nextTrackCommand.addTarget { [weak self] _ in self?.next(); return .success }
        center.previousTrackCommand.addTarget { [weak self] _ in self?.previous(); return .success }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(event.positionTime)
            return .success
        }
    }

    func play(_ items: [LibraryItem], at start: Int) {
        guard items.indices.contains(start) else { return }
        original = items
        queue = items
        index = start
        if shuffled { reshuffle() }
        load()
    }

    /// Plays in random order; turning shuffle off afterwards restores the list's order.
    func shuffle(_ items: [LibraryItem]) {
        guard !items.isEmpty else { return }
        shuffled = true
        original = items
        queue = items.shuffled()
        index = 0
        load()
    }

    func playNext(_ items: [LibraryItem]) {
        guard current != nil else { return play(items, at: 0) }
        queue.insert(contentsOf: items, at: index + 1)
        original += items
        queueChanged()
    }

    func addToQueue(_ items: [LibraryItem]) {
        guard current != nil else { return play(items, at: 0) }
        queue += items
        original += items
        queueChanged()
    }

    /// Indexes are positions in `upNext`.
    func moveUpNext(from: Int, to: Int) {
        let f = index + 1 + from, t = index + 1 + to
        guard queue.indices.contains(f), queue.indices.contains(t) else { return }
        queue.insert(queue.remove(at: f), at: t)
        queueChanged()
    }

    func removeUpNext(at i: Int) {
        let f = index + 1 + i
        guard queue.indices.contains(f) else { return }
        let removed = queue.remove(at: f)
        if let o = original.firstIndex(where: { $0.path == removed.path }) { original.remove(at: o) }
        queueChanged()
    }

    func jump(toUpNext i: Int) {
        let f = index + 1 + i
        guard queue.indices.contains(f) else { return }
        index = f
        load()
    }

    func toggleShuffle() {
        shuffled.toggle()
        if shuffled {
            reshuffle()
        } else if let now = current {
            queue = original
            index = original.firstIndex { $0.path == now.path } ?? 0
        }
        queueChanged()
    }

    func cycleRepeat() {
        repeatMode = (repeatMode + 1) % 3
        queueChanged()
    }

    private func queueChanged() {
        preloadNext()
        update()
    }

    private func reshuffle() {
        guard let now = current else { return }
        var rest = queue
        rest.remove(at: index)
        queue = [now] + rest.shuffled()
        index = 0
    }

    private func watch(_ playerItem: AVPlayerItem, _ item: LibraryItem) {
        statusObserver = playerItem.observe(\.status) { observed, _ in
            guard observed.status == .failed else { return }
            NSLog("MornyeLite: cannot play %@: %@", item.url.lastPathComponent, "\(observed.error.map { "\($0)" } ?? "unknown")")
        }
    }

    private func checkCrossfade() {
        let setting = Double(Player.crossfade)
        guard setting > 0, outgoing == nil, isPlaying, repeatMode != 2, duration > setting + 1, position >= duration - setting else { return }
        // The observer fires every 0.5 s, so fit the ramp into what is actually left of the song.
        let fade = max(0.2, min(setting, duration - position))
        let nextIndex = index + 1 < queue.count ? index + 1 : (repeatMode == 1 && !queue.isEmpty ? 0 : -1)
        guard nextIndex >= 0 else { return }
        let old = player
        let incoming = players[1 - active]
        let item = AVPlayerItem(url: queue[nextIndex].url)
        incoming.removeAllItems()
        incoming.volume = 0
        incoming.actionAtItemEnd = .pause
        incoming.insert(item, after: nil)
        active = 1 - active
        index = nextIndex
        playing = item
        preloaded = nil
        watch(item, queue[index])
        incoming.play()
        outgoing = old
        let start = Date()
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            let t = min(1, Date().timeIntervalSince(start) / fade)
            incoming.volume = Float(t)
            old.volume = Float(1 - t)
            if t >= 1 { self?.finishFade() }
        }
        update()
    }

    private func finishFade() {
        fadeTimer?.invalidate()
        fadeTimer = nil
        if let old = outgoing {
            old.pause()
            old.removeAllItems()
            old.volume = 1
        }
        outgoing = nil
        player.volume = 1
    }

    private func load() {
        guard let item = current else { return }
        finishFade()
        try? AVAudioSession.sharedInstance().setActive(true)
        let playerItem = AVPlayerItem(url: item.url)
        preloaded = nil
        playing = playerItem
        player.removeAllItems()
        watch(playerItem, item)
        player.insert(playerItem, after: nil)
        preloadNext()
        player.play()
        update()
    }

    /// AVQueuePlayer moved on to the preloaded song by itself.
    private func advanced() {
        guard let item = player.currentItem, item !== playing, item === preloaded, queue.indices.contains(preloadedIndex) else { return }
        index = preloadedIndex
        playing = item
        preloaded = nil
        watch(item, queue[index])
        preloadNext()
        update()
    }

    func preloadNext() {
        advanced()
        if let old = preloaded {
            player.remove(old)
            preloaded = nil
        }
        let nextIndex = index + 1 < queue.count ? index + 1 : (repeatMode == 1 && !queue.isEmpty ? 0 : -1)
        guard Player.gapless, Player.crossfade == 0, repeatMode != 2, nextIndex >= 0, let playing = playing, player.currentItem === playing else {
            player.actionAtItemEnd = .pause
            return
        }
        let item = AVPlayerItem(url: queue[nextIndex].url)
        player.insert(item, after: playing)
        preloaded = item
        preloadedIndex = nextIndex
        player.actionAtItemEnd = .advance
    }

    func toggle() { isPlaying ? pause() : resume() }
    func resume() {
        if player.currentItem == nil { return load() }
        if duration > 0 && position >= duration - 0.5 { player.seek(to: .zero) }
        player.play()
        update()
    }
    func pause() { finishFade(); player.pause(); update() }
    func next() {
        if index + 1 < queue.count {
            index += 1
        } else if repeatMode == 1, !queue.isEmpty {
            index = 0
        } else { return }
        load()
    }
    func previous() {
        if position > 3 || index == 0 { seek(0); return }
        index -= 1
        load()
    }
    func seek(_ seconds: Double, completion: (() -> Void)? = nil) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                self?.update()
                completion?()
            }
        }
    }

    @objc private func ended(_ note: Notification) {
        DispatchQueue.main.async {
            guard (note.object as? AVPlayerItem) === self.playing, self.preloaded == nil else { return }
            if self.repeatMode == 2 {
                self.player.seek(to: .zero)
                self.player.play()
            } else if self.index + 1 < self.queue.count || self.repeatMode == 1 {
                self.next()
            } else {
                self.update()
            }
        }
    }

    private func update() {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: current?.title ?? "",
            MPMediaItemPropertyArtist: current?.artist ?? "",
            MPMediaItemPropertyAlbumTitle: current?.album ?? "",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let image = Art.image(current?.coverPath, size: 300) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = current == nil ? nil : info
        NotificationCenter.default.post(name: Player.changed, object: nil)
    }
}

/// Full-screen player with a background tinted from the artwork.
final class PlayerViewController: UIViewController {
    private let gradient = CAGradientLayer()
    private let close = Theme.iconButton(.down, size: 24, color: Theme.text)
    private let header = Theme.label(12, .bold)
    private let cover = UIImageView()
    private let titleLabel = Theme.label(22, .bold)
    private let artistLabel = Theme.label(16, .regular, Theme.subtext)
    private let slider = UISlider()
    private var scrubTarget: Float?
    private let elapsed = Theme.label(12, .regular, Theme.subtext)
    private let remaining = Theme.label(12, .regular, Theme.subtext)
    private let playButton = Theme.circleButton(.play, size: 68, color: .white)
    private let prevButton = Theme.iconButton(.previous, size: 30, color: Theme.text)
    private let nextButton = Theme.iconButton(.next, size: 30, color: Theme.text)
    private let shuffle = Theme.iconButton(.shuffle, size: 24)
    private let repeatButton = Theme.iconButton(.repeatAll, size: 24)
    private let queueButton = Theme.iconButton(.list, size: 22, color: Theme.text)
    private var timer: Timer?
    private var shownPath: String?

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.bg
        view.layer.addSublayer(gradient)
        header.text = "NOW PLAYING"
        header.textAlignment = .center
        cover.clipsToBounds = true
        cover.layer.cornerRadius = 4
        cover.backgroundColor = Theme.elevated
        slider.minimumTrackTintColor = .white
        slider.maximumTrackTintColor = UIColor(white: 1, alpha: 0.25)
        slider.setThumbImage(UIGraphicsImageRenderer(size: CGSize(width: 12, height: 12)).image { _ in
            UIColor.white.setFill()
            UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: 12, height: 12)).fill()
        }, for: .normal)
        // Preview while dragging; seek once on release so playback doesn't stutter.
        slider.addTarget(self, action: #selector(scrubbed), for: .valueChanged)
        slider.addTarget(self, action: #selector(scrubEnded), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        remaining.textAlignment = .right
        close.addTarget(self, action: #selector(dismissTapped), for: .touchUpInside)
        playButton.addTarget(self, action: #selector(playTapped), for: .touchUpInside)
        prevButton.addTarget(self, action: #selector(prevTapped), for: .touchUpInside)
        nextButton.addTarget(self, action: #selector(nextTapped), for: .touchUpInside)
        shuffle.addTarget(self, action: #selector(shuffleTapped), for: .touchUpInside)
        repeatButton.addTarget(self, action: #selector(repeatTapped), for: .touchUpInside)
        queueButton.addTarget(self, action: #selector(queueTapped), for: .touchUpInside)
        view.addSubview(queueButton)
        [close, header, cover, titleLabel, artistLabel, slider, elapsed, remaining, shuffle, prevButton, playButton, nextButton, repeatButton]
            .forEach { view.addSubview($0) }
        let swipe = UISwipeGestureRecognizer(target: self, action: #selector(dismissTapped))
        swipe.direction = .down
        view.addGestureRecognizer(swipe)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: Player.changed, object: nil)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        gradient.frame = view.bounds
        let safe = view.safeAreaLayoutGuide.layoutFrame
        let w = min(safe.width - 48, 520)
        let x = (view.bounds.width - w) / 2
        close.frame.origin = CGPoint(x: x - 12, y: safe.minY + 4)
        header.frame = CGRect(x: x + 40, y: safe.minY + 4, width: w - 80, height: 44)
        queueButton.frame.origin = CGPoint(x: x + w - 32, y: safe.minY + 4)
        let controls: CGFloat = 250
        let side = max(120, min(w, safe.height - 60 - controls))
        cover.frame = CGRect(x: (view.bounds.width - side) / 2, y: safe.minY + 60, width: side, height: side)
        var y = cover.frame.maxY + 28
        titleLabel.frame = CGRect(x: x, y: y, width: w, height: 28)
        artistLabel.frame = CGRect(x: x, y: y + 30, width: w, height: 22)
        y += 68
        slider.frame = CGRect(x: x, y: y, width: w, height: 24)
        elapsed.frame = CGRect(x: x, y: y + 26, width: 80, height: 16)
        remaining.frame = CGRect(x: x + w - 80, y: y + 26, width: 80, height: 16)
        y += 62
        playButton.frame.origin = CGPoint(x: view.bounds.midX - 34, y: y)
        let mid = y + 34 - 22
        prevButton.frame.origin = CGPoint(x: playButton.frame.minX - 24 - 44, y: mid)
        nextButton.frame.origin = CGPoint(x: playButton.frame.maxX + 24, y: mid)
        shuffle.frame.origin = CGPoint(x: x - 10, y: mid)
        repeatButton.frame.origin = CGPoint(x: x + w - 34, y: mid)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        timer?.invalidate()
        timer = nil
    }

    @objc private func refresh() {
        let p = Player.shared
        titleLabel.text = p.current?.title ?? "Nothing playing"
        artistLabel.text = p.current?.artistName
        if shownPath != p.current?.path {
            shownPath = p.current?.path
            let image = Art.image(p.current?.coverPath, size: 520)
            cover.image = image ?? Icon.music.image(64, Theme.subtext)
            cover.contentMode = image == nil ? .center : .scaleAspectFill
            gradient.colors = [Art.tint(image).cgColor, Theme.bg.cgColor]
            gradient.locations = [0, 0.75]
        }
        playButton.setImage((p.isPlaying ? Icon.pause : Icon.play).image(28, .black), for: .normal)
        shuffle.setImage(Icon.shuffle.image(24, p.shuffled ? Theme.green : Theme.subtext), for: .normal)
        repeatButton.setImage((p.repeatMode == 2 ? Icon.repeatOne : Icon.repeatAll)
            .image(24, p.repeatMode > 0 ? Theme.green : Theme.subtext), for: .normal)
        tick()
    }

    private func tick() {
        let p = Player.shared
        slider.maximumValue = Float(max(p.duration, 1))
        let scrubbing = slider.isTracking || scrubTarget != nil
        if !scrubbing { slider.value = Float(p.position) }
        let shown = scrubbing ? Double(slider.value) : p.position
        elapsed.text = clock(shown)
        remaining.text = "-" + clock(max(0, p.duration - shown))
    }

    private func clock(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }
    @objc private func scrubbed() {
        // VoiceOver adjusts the value without a touch, so seek right away.
        if slider.isTracking { tick() } else { scrubEnded() }
    }
    @objc private func scrubEnded() {
        let target = slider.value
        scrubTarget = target
        Player.shared.seek(Double(target)) { [weak self] in
            guard let self = self, self.scrubTarget == target else { return }
            self.scrubTarget = nil
            self.tick()
        }
    }
    @objc private func playTapped() { Player.shared.toggle() }
    @objc private func prevTapped() { Player.shared.previous() }
    @objc private func nextTapped() { Player.shared.next() }
    @objc private func shuffleTapped() { Player.shared.toggleShuffle() }
    @objc private func repeatTapped() { Player.shared.cycleRepeat() }
    @objc private func dismissTapped() { dismiss(animated: true) }
    @objc private func queueTapped() { present(UINavigationController(rootViewController: UpNextViewController()), animated: true) }
}

/// Now playing and Up Next; drag to reorder, swipe to remove, tap to jump.
final class UpNextViewController: UITableViewController {
    private var ignoreChanges = false

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Queue"
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(close))
        tableView.rowHeight = 60
        tableView.separatorStyle = .none
        tableView.allowsSelectionDuringEditing = true
        setEditing(true, animated: false)
        NotificationCenter.default.addObserver(self, selector: #selector(changed), name: Player.changed, object: nil)
    }

    @objc private func close() { dismiss(animated: true) }
    @objc private func changed() { if !ignoreChanges { tableView.reloadData() } }

    override func numberOfSections(in tableView: UITableView) -> Int { 2 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? (Player.shared.current == nil ? 0 : 1) : Player.shared.upNext.count
    }

    override func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat { 44 }

    override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let v = UIView()
        v.backgroundColor = Theme.bg
        let l = Theme.label(18, .bold)
        l.text = section == 0 ? "Now playing" : (Player.shared.upNext.isEmpty ? "Nothing up next" : "Next up")
        l.frame = CGRect(x: 16, y: 12, width: tableView.bounds.width - 32, height: 26)
        v.addSubview(l)
        return v
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "a") as? ArtCell ?? ArtCell(style: .default, reuseIdentifier: "a")
        guard let item = indexPath.section == 0 ? Player.shared.current : Player.shared.upNext[indexPath.row] else { return cell }
        Art.set(cell.art, path: item.coverPath, size: 46)
        cell.set(item.title, item.artistName, playing: indexPath.section == 0)
        return cell
    }

    override func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle {
        indexPath.section == 1 ? .delete : .none
    }

    override func tableView(_ tableView: UITableView, shouldIndentWhileEditingRowAt indexPath: IndexPath) -> Bool { indexPath.section == 1 }
    override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool { indexPath.section == 1 }

    override func tableView(_ tableView: UITableView, targetIndexPathForMoveFromRowAt source: IndexPath,
                            toProposedIndexPath proposed: IndexPath) -> IndexPath {
        proposed.section == 1 ? proposed : IndexPath(row: 0, section: 1)
    }

    override func tableView(_ tableView: UITableView, moveRowAt source: IndexPath, to destination: IndexPath) {
        ignoreChanges = true
        Player.shared.moveUpNext(from: source.row, to: destination.row)
        ignoreChanges = false
    }

    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete, indexPath.section == 1 else { return }
        ignoreChanges = true
        Player.shared.removeUpNext(at: indexPath.row)
        ignoreChanges = false
        tableView.deleteRows(at: [indexPath], with: .automatic)
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 1 { Player.shared.jump(toUpNext: indexPath.row) }
    }
}

/// Bar above the tab bar showing the current song.
final class MiniPlayer: UIView {
    var onOpen: (() -> Void)?
    private let art = UIImageView()
    private let titleLabel = Theme.label(14, .semibold)
    private let artistLabel = Theme.label(12, .regular, Theme.subtext)
    private let play = UIButton(type: .custom)
    private let progress = UIView()
    private var timer: Timer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.elevated
        layer.cornerRadius = 6
        clipsToBounds = true
        art.clipsToBounds = true
        art.layer.cornerRadius = 3
        progress.backgroundColor = .white
        play.addTarget(self, action: #selector(toggle), for: .touchUpInside)
        [art, titleLabel, artistLabel, play, progress].forEach { addSubview($0) }
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(open)))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let h = bounds.height, w = bounds.width
        art.frame = CGRect(x: 8, y: 8, width: h - 16, height: h - 16)
        play.frame = CGRect(x: w - 52, y: 0, width: 48, height: h)
        let x = art.frame.maxX + 10
        titleLabel.frame = CGRect(x: x, y: h / 2 - 18, width: play.frame.minX - x, height: 18)
        artistLabel.frame = CGRect(x: x, y: h / 2 + 1, width: play.frame.minX - x, height: 16)
        tick()
    }

    func update() {
        let p = Player.shared
        titleLabel.text = p.current?.title
        artistLabel.text = p.current?.artistName
        Art.set(art, path: p.current?.coverPath, size: 40)
        play.setImage((p.isPlaying ? Icon.pause : Icon.play).image(22, .white), for: .normal)
        timer?.invalidate()
        timer = p.isPlaying ? Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() } : nil
        tick()
    }

    private func tick() {
        let p = Player.shared
        let fraction = p.duration > 0 ? CGFloat(p.position / p.duration) : 0
        progress.frame = CGRect(x: 8, y: bounds.height - 2, width: (bounds.width - 16) * min(1, fraction), height: 2)
    }

    @objc private func toggle() { Player.shared.toggle() }
    @objc private func open() { onOpen?() }
}

final class MainTabController: UITabBarController {
    private let mini = MiniPlayer()

    override func viewDidLoad() {
        super.viewDidLoad()
        tabBar.barStyle = .black
        tabBar.isTranslucent = false
        tabBar.barTintColor = UIColor(white: 0.04, alpha: 1)
        tabBar.tintColor = Theme.text
        tabBar.unselectedItemTintColor = Theme.subtext
        mini.isHidden = true
        mini.onOpen = { [weak self] in self?.openNowPlaying() }
        view.addSubview(mini)
        NotificationCenter.default.addObserver(self, selector: #selector(playerChanged), name: Player.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(downloadsChanged), name: DownloadManager.changed, object: nil)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        mini.frame = CGRect(x: 8, y: tabBar.frame.minY - 62, width: view.bounds.width - 16, height: 56)
        view.bringSubviewToFront(mini)
    }

    @objc private func playerChanged() {
        let show = Player.shared.current != nil
        if mini.isHidden == show {
            mini.isHidden = !show
            viewControllers?.forEach { $0.additionalSafeAreaInsets.bottom = show ? 64 : 0 }
        }
        mini.update()
    }

    @objc private func downloadsChanged() {
        let active = DownloadManager.shared.jobs.filter { !$0.done }.count
        viewControllers?.first { $0.tabBarItem.tag == 3 }?.tabBarItem.badgeValue = active > 0 ? "\(active)" : nil
    }
}
