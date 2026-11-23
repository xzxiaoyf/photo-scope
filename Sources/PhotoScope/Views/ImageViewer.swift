import AppKit

/// 右上区域：可缩放的大图视图（NSScrollView 的 magnification 机制）。
final class ImageViewer: NSView {

    enum ZoomMode {
        case fit
        case manual
    }

    var onZoomChanged: ((CGFloat) -> Void)?

    private let scrollView = NSScrollView()
    private let imageView = NSImageView()
    private let placeholder = NSTextField(labelWithString: "从左侧选择一个包含照片的目录")

    private(set) var mode: ZoomMode = .fit
    private var isApplyingFit = false

    var magnification: CGFloat { scrollView.magnification }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
        observeMagnification()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setupViews() {
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.02
        scrollView.maxMagnification = 20
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(calibratedWhite: 0.14, alpha: 1.0)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.postsFrameChangedNotifications = true

        // 默认 NSClipView 会把小于可视区的文档视图钉在左下角，这里改成居中。
        let clipView = CenteringClipView(frame: scrollView.contentView.frame)
        clipView.drawsBackground = true
        clipView.backgroundColor = NSColor(calibratedWhite: 0.14, alpha: 1.0)
        scrollView.contentView = clipView

        imageView.imageScaling = .scaleNone
        imageView.imageAlignment = .alignCenter
        imageView.wantsLayer = true
        imageView.frame = .zero
        scrollView.documentView = imageView

        placeholder.font = NSFont.systemFont(ofSize: 15, weight: .medium)
        placeholder.textColor = .tertiaryLabelColor
        placeholder.alignment = .center
        placeholder.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scrollView)
        addSubview(placeholder)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            placeholder.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: centerYAnchor),
            placeholder.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -40)
        ])
    }

    private func observeMagnification() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(liveMagnificationEnded(_:)),
            name: NSScrollView.didEndLiveMagnifyNotification,
            object: scrollView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollFrameChanged(_:)),
            name: NSView.frameDidChangeNotification,
            object: scrollView
        )
    }

    @objc private func liveMagnificationEnded(_ notification: Notification) {
        mode = .manual
        notifyZoom()
    }

    @objc private func scrollFrameChanged(_ notification: Notification) {
        if mode == .fit { applyFit() }
    }

    // MARK: - 图像

    func setImage(_ image: NSImage?) {
        guard let image = image, image.size.width > 0, image.size.height > 0 else {
            clear()
            return
        }
        imageView.image = image
        imageView.setFrameSize(image.size)
        placeholder.isHidden = true
        if mode == .fit { applyFit() }
        notifyZoom()
    }

    func clear() {
        imageView.image = nil
        imageView.setFrameSize(.zero)
        placeholder.isHidden = false
        notifyZoom()
    }

    // MARK: - 缩放

    func zoomIn() {
        mode = .manual
        setMagnification(scrollView.magnification * 1.25)
    }

    func zoomOut() {
        mode = .manual
        setMagnification(scrollView.magnification / 1.25)
    }

    func fit() {
        mode = .fit
        applyFit()
        notifyZoom()
    }

    func actualSize() {
        mode = .manual
        setMagnification(1.0)
    }

    private func setMagnification(_ value: CGFloat) {
        guard imageView.image != nil else { return }
        let clamped = min(max(value, scrollView.minMagnification), scrollView.maxMagnification)
        scrollView.magnification = clamped
        notifyZoom()
    }

    /// 并排对比时把另一侧的缩放倍率同步过来。
    /// 不触发 onZoomChanged，避免两个视图互相通知形成回环。
    func applyExternalMagnification(_ value: CGFloat) {
        guard imageView.image != nil else { return }
        let clamped = min(max(value, scrollView.minMagnification), scrollView.maxMagnification)
        guard abs(scrollView.magnification - clamped) > 0.0005 else { return }
        mode = .manual
        scrollView.magnification = clamped
    }

    private func applyFit() {
        guard let image = imageView.image,
              image.size.width > 0, image.size.height > 0 else { return }
        let visible = scrollView.contentSize
        guard visible.width > 10, visible.height > 10 else { return }
        let ratio = min(visible.width / image.size.width, visible.height / image.size.height)
        let clamped = min(max(ratio, scrollView.minMagnification), 4.0)
        if abs(scrollView.magnification - clamped) > 0.0005 {
            isApplyingFit = true
            scrollView.magnification = clamped
            isApplyingFit = false
        }
    }

    override func layout() {
        super.layout()
        if mode == .fit && !isApplyingFit {
            applyFit()
        }
    }

    private func notifyZoom() {
        onZoomChanged?(scrollView.magnification)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

/// Apple 官方示例做法：文档视图小于可视区时保持居中，而不是贴在左下角。
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        let documentFrame = document.frame
        if rect.size.width >= documentFrame.size.width {
            rect.origin.x = (documentFrame.size.width - rect.size.width) / 2
        }
        if rect.size.height >= documentFrame.size.height {
            rect.origin.y = (documentFrame.size.height - rect.size.height) / 2
        }
        return rect
    }
}
