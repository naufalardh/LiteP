import AVFoundation
import MediaPlayer
import UIKit

final class Player: NSObject {
    static let shared = Player()
    static let changed = Notification.Name("LitePlayerChanged")

    private let player = AVPlayer()
    private(set) var queue: [LibraryItem] = []
    private(set) var index = 0
    var current: LibraryItem? { queue.indices.contains(index) ? queue[index] : nil }
    var isPlaying: Bool { player.rate > 0 }
    var position: Double { player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0 }
    var duration: Double { player.currentItem?.duration.seconds.isFinite == true ? player.currentItem!.duration.seconds : 0 }

    private override init() {
        super.init()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
        NotificationCenter.default.addObserver(self, selector: #selector(ended), name: .AVPlayerItemDidPlayToEndTime, object: nil)
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
        queue = items
        index = start
        load()
    }

    private func load() {
        guard let item = current else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        player.replaceCurrentItem(with: AVPlayerItem(url: item.url))
        player.play()
        update()
    }

    func toggle() { isPlaying ? pause() : resume() }
    func resume() { player.play(); update() }
    func pause() { player.pause(); update() }
    func next() { guard index + 1 < queue.count else { return }; index += 1; load() }
    func previous() {
        if position > 3 || index == 0 { seek(0); return }
        index -= 1
        load()
    }
    func seek(_ seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600)) { [weak self] _ in self?.update() }
    }

    @objc private func ended(_ note: Notification) {
        DispatchQueue.main.async {
            guard (note.object as? AVPlayerItem) === self.player.currentItem else { return }
            if self.index + 1 < self.queue.count { self.next() } else { self.update() }
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
        if let path = current?.coverPath, let image = UIImage(contentsOfFile: path) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = current == nil ? nil : info
        NotificationCenter.default.post(name: Player.changed, object: nil)
    }
}

final class PlayerViewController: UIViewController {
    private let cover = UIImageView()
    private let titleLabel = UILabel()
    private let artistLabel = UILabel()
    private let slider = UISlider()
    private let timeLabel = UILabel()
    private let playButton = UIButton(type: .system)
    private var timer: Timer?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Now Playing"
        view.backgroundColor = .white
        cover.contentMode = .scaleAspectFit
        cover.backgroundColor = UIColor(white: 0.94, alpha: 1)
        titleLabel.font = .boldSystemFont(ofSize: 20)
        titleLabel.textAlignment = .center
        artistLabel.textColor = .gray
        artistLabel.textAlignment = .center
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        timeLabel.textColor = .gray
        timeLabel.textAlignment = .center
        slider.addTarget(self, action: #selector(seek), for: .valueChanged)
        let prev = button("Prev", #selector(prevTapped))
        let next = button("Next", #selector(nextTapped))
        playButton.setTitle("Play", for: .normal)
        playButton.titleLabel?.font = .boldSystemFont(ofSize: 22)
        playButton.addTarget(self, action: #selector(playTapped), for: .touchUpInside)
        let controls = UIStackView(arrangedSubviews: [prev, playButton, next])
        controls.distribution = .fillEqually
        let stack = UIStackView(arrangedSubviews: [cover, titleLabel, artistLabel, slider, timeLabel, controls])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            cover.heightAnchor.constraint(equalTo: cover.widthAnchor),
            cover.heightAnchor.constraint(lessThanOrEqualToConstant: 360),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: Player.changed, object: nil)
    }

    private func button(_ title: String, _ action: Selector) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 20)
        b.addTarget(self, action: action, for: .touchUpInside)
        return b
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
        artistLabel.text = p.current?.artist
        cover.image = p.current?.coverPath.flatMap { UIImage(contentsOfFile: $0) }
        playButton.setTitle(p.isPlaying ? "Pause" : "Play", for: .normal)
        tick()
    }

    private func tick() {
        let p = Player.shared
        slider.maximumValue = Float(max(p.duration, 1))
        if !slider.isTracking { slider.value = Float(p.position) }
        timeLabel.text = "\(clock(p.position)) / \(clock(p.duration))"
    }

    private func clock(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }
    @objc private func seek() { Player.shared.seek(Double(slider.value)) }
    @objc private func playTapped() { Player.shared.toggle() }
    @objc private func prevTapped() { Player.shared.previous() }
    @objc private func nextTapped() { Player.shared.next() }
}
