import AppKit
import AVFoundation
import AVKit

/// 视频：显示封面帧 + 播放按钮，点击后交给 AVPlayerView 的内建控制条播放/暂停/拖动进度。
final class VideoPlayerView: NSView {

    private let playerView = AVPlayerView()
    private let posterView = NSImageView()
    private let playButton = NSButton(title: "▶  播放视频", target: nil, action: nil)
    private let nameLabel = NSTextField(labelWithString: "")

    private var currentURL: URL?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setupViews() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        playerView.controlsStyle = .inline
        playerView.showsFullScreenToggleButton = true
        playerView.translatesAutoresizingMaskIntoConstraints = false
        playerView.isHidden = true
        addSubview(playerView)

        posterView.imageScaling = .scaleProportionallyUpOrDown
        posterView.imageAlignment = .alignCenter
        posterView.translatesAutoresizingMaskIntoConstraints = false
        posterView.wantsLayer = true
        posterView.layer?.backgroundColor = NSColor.black.cgColor
        addSubview(posterView)

        // 自定义高对比按钮：默认 bezel 在复杂的视频封面上几乎不可见
        playButton.isBordered = false
        playButton.attributedTitle = NSAttributedString(string: "▶  播放视频", attributes: [
            .font: NSFont.boldSystemFont(ofSize: 14),
            .foregroundColor: NSColor.white
        ])
        playButton.wantsLayer = true
        playButton.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        playButton.layer?.cornerRadius = 9
        playButton.layer?.masksToBounds = true
        playButton.target = self
        playButton.action = #selector(playTapped(_:))
        playButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(playButton)

        nameLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        nameLabel.textColor = .white
        nameLabel.drawsBackground = true
        nameLabel.backgroundColor = NSColor.black.withAlphaComponent(0.65)
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nameLabel)

        NSLayoutConstraint.activate([
            playerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            playerView.topAnchor.constraint(equalTo: topAnchor),
            playerView.bottomAnchor.constraint(equalTo: bottomAnchor),

            posterView.leadingAnchor.constraint(equalTo: leadingAnchor),
            posterView.trailingAnchor.constraint(equalTo: trailingAnchor),
            posterView.topAnchor.constraint(equalTo: topAnchor),
            posterView.bottomAnchor.constraint(equalTo: bottomAnchor),

            playButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            playButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            playButton.widthAnchor.constraint(equalToConstant: 170),
            playButton.heightAnchor.constraint(equalToConstant: 40),

            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            nameLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16)
        ])
    }

    func load(url: URL) {
        stop()
        currentURL = url
        nameLabel.stringValue = url.lastPathComponent
        posterView.image = nil
        posterView.isHidden = false
        playButton.isHidden = false
        nameLabel.isHidden = false
        playerView.isHidden = true
        playerView.player = AVPlayer(url: url)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let poster = ImageDecoder.videoPoster(url: url, maxPixel: 1600)
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.currentURL == url else { return }
                self.posterView.image = poster
            }
        }
    }

    func dumpLayout() {
        NSLog("PhotoScope video: frame=%@ player=%@ hidden=%d poster=%@ hidden=%d play=%@ hidden=%d label=%@ hidden=%d",
              NSStringFromRect(frame), NSStringFromRect(playerView.frame), playerView.isHidden,
              NSStringFromRect(posterView.frame), posterView.isHidden,
              NSStringFromRect(playButton.frame), playButton.isHidden,
              NSStringFromRect(nameLabel.frame), nameLabel.isHidden)
    }

    func stop() {
        playerView.player?.pause()
        playerView.player = nil
        currentURL = nil
        posterView.image = nil
    }

    @objc private func playTapped(_ sender: Any?) {
        posterView.isHidden = true
        playButton.isHidden = true
        nameLabel.isHidden = true
        playerView.isHidden = false
        playerView.player?.play()
    }
}
