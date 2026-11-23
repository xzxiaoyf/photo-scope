import AppKit

/// 并排对比的左右两侧。左侧为 A（选择），右侧为 B（备用）。
enum CompareSide: Int, CaseIterable {
    case left = 0
    case right = 1

    var title: String { self == .left ? "A  选择" : "B  备用" }
    var other: CompareSide { self == .left ? .right : .left }
}

/// 视图模式「双张对比」：两个独立的大图面板，各自可选照片，缩放倍率联动。
///
/// 活动面板用橙红色边框标出；点击面板或顶部标签切换活动侧，
/// 底部缩略图条 / ← → / 工具栏上一张下一张都只改变活动侧的照片。
final class CompareView: NSView {

    var onActiveSideChanged: ((CompareSide) -> Void)?
    var onZoomChanged: ((CGFloat) -> Void)?

    private(set) var activeSide: CompareSide = .left
    private var items: [MediaItem] = []
    private var indices: [CompareSide: Int] = [:]
    private var loadedURLs: [CompareSide: URL] = [:]
    private var loadTokens: [CompareSide: UUID] = [:]

    private let leftPane = ComparePane(side: .left)
    private let rightPane = ComparePane(side: .right)

    /// 纯计算：进入对比模式时的默认 A/B 组合（相邻两张；末张回退到前一张）。
    static func defaultPair(current: Int, count: Int) -> (left: Int?, right: Int?) {
        guard count > 0 else { return (nil, nil) }
        let left = max(0, min(current, count - 1))
        guard count > 1 else { return (left, left) }
        let right = left + 1 < count ? left + 1 : left - 1
        return (left, right)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setupViews() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 1).cgColor

        let stack = NSStackView(views: [leftPane, rightPane])
        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        leftPane.onActivate = { [weak self] in self?.activate(side: .left) }
        rightPane.onActivate = { [weak self] in self?.activate(side: .right) }

        leftPane.viewer.onZoomChanged = { [weak self] value in
            self?.rightPane.viewer.applyExternalMagnification(value)
            self?.onZoomChanged?(value)
        }
        rightPane.viewer.onZoomChanged = { [weak self] value in
            self?.leftPane.viewer.applyExternalMagnification(value)
            self?.onZoomChanged?(value)
        }
        setActive(.left)
    }

    // MARK: - 数据

    func show(items: [MediaItem], left: Int?, right: Int?, active: CompareSide) {
        self.items = items
        indices[.left] = left
        indices[.right] = right
        for side in CompareSide.allCases {
            let index = side == .left ? left : right
            guard let index, items.indices.contains(index) else {
                loadedURLs[side] = nil
                pane(side).viewer.clear()
                pane(side).set(name: "—", isVideo: false)
                continue
            }
            let item = items[index]
            pane(side).set(name: item.name, isVideo: item.isVideo)
            guard loadedURLs[side] != item.url.standardizedFileURL else { continue }
            load(item, side: side)
        }
        setActive(active)
    }

    private func load(_ item: MediaItem, side: CompareSide) {
        let token = UUID()
        loadTokens[side] = token
        let url = item.url.standardizedFileURL
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let image: NSImage? = item.isVideo
                ? ImageDecoder.videoPoster(url: item.url, maxPixel: 2048)
                : ImageDecoder.displayNSImage(url: item.url)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.loadTokens[side] == token else { return }
                self.loadedURLs[side] = url
                self.pane(side).viewer.setImage(image)
            }
        }
    }

    /// 旋转覆盖变更后强制重新解码指定侧（缩略图缓存已由控制器失效）。
    func reload(side: CompareSide) {
        loadedURLs[side] = nil
        guard let index = indices[side], items.indices.contains(index) else { return }
        load(items[index], side: side)
    }

    func clear() {
        items = []
        indices = [:]
        loadedURLs = [:]
        for side in CompareSide.allCases {
            pane(side).viewer.clear()
            pane(side).set(name: "—", isVideo: false)
        }
    }

    // MARK: - 活动侧

    func setActive(_ side: CompareSide) {
        activeSide = side
        leftPane.setActive(side == .left)
        rightPane.setActive(side == .right)
    }

    private func activate(side: CompareSide) {
        setActive(side)
        onActiveSideChanged?(side)
    }

    func index(for side: CompareSide) -> Int? { indices[side] }

    private func pane(_ side: CompareSide) -> ComparePane {
        side == .left ? leftPane : rightPane
    }

    // MARK: - 缩放（两侧联动）

    var magnification: CGFloat { pane(activeSide).viewer.magnification }

    func zoomIn() { pane(activeSide).viewer.zoomIn() }
    func zoomOut() { pane(activeSide).viewer.zoomOut() }

    func fit() {
        leftPane.viewer.fit()
        rightPane.viewer.fit()
        onZoomChanged?(magnification)
    }

    func actualSize() {
        leftPane.viewer.actualSize()
        rightPane.viewer.actualSize()
        onZoomChanged?(magnification)
    }
}

/// 单个对比面板：顶部标签 / 中间可缩放图 / 底部文件名，活动侧带橙红边框。
private final class ComparePane: NSView {

    let viewer = ImageViewer()
    var onActivate: (() -> Void)?

    private let titleButton = NSButton()
    private let nameLabel = NSTextField(labelWithString: "—")
    private let side: CompareSide

    init(side: CompareSide) {
        self.side = side
        super.init(frame: .zero)
        setupViews()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setupViews() {
        wantsLayer = true
        layer?.cornerRadius = 2
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor

        let header = NSView()
        header.wantsLayer = true
        header.layer?.backgroundColor = NSColor(calibratedWhite: 0.16, alpha: 1).cgColor
        header.translatesAutoresizingMaskIntoConstraints = false

        titleButton.title = side.title
        titleButton.isBordered = false
        titleButton.font = NSFont.boldSystemFont(ofSize: 11)
        titleButton.contentTintColor = .white
        titleButton.target = self
        titleButton.action = #selector(titleClicked(_:))
        titleButton.toolTip = "点击切换到\(side == .left ? "左侧 A" : "右侧 B")"
        titleButton.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(titleButton)

        viewer.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        nameLabel.textColor = .lightGray
        nameLabel.alignment = .left
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(header)
        addSubview(viewer)
        addSubview(nameLabel)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.topAnchor.constraint(equalTo: topAnchor),
            header.heightAnchor.constraint(equalToConstant: 22),
            titleButton.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 8),
            titleButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            viewer.leadingAnchor.constraint(equalTo: leadingAnchor),
            viewer.trailingAnchor.constraint(equalTo: trailingAnchor),
            viewer.topAnchor.constraint(equalTo: header.bottomAnchor),
            viewer.bottomAnchor.constraint(equalTo: nameLabel.topAnchor, constant: -2),

            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            nameLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            nameLabel.heightAnchor.constraint(equalToConstant: 14)
        ])

        // 点击面板空白处也能切换活动侧；不阻断内部 scrollView 的拖拽/捏合。
        let click = NSClickGestureRecognizer(target: self, action: #selector(paneClicked(_:)))
        click.numberOfClicksRequired = 1
        click.delaysPrimaryMouseButtonEvents = false
        addGestureRecognizer(click)
    }

    func set(name: String, isVideo: Bool) {
        nameLabel.stringValue = isVideo ? "\(name)   （视频封面帧）" : name
        nameLabel.toolTip = name
    }

    func setActive(_ isActive: Bool) {
        layer?.borderWidth = isActive ? 2 : 1
        layer?.borderColor = (isActive ? ViewModeControl.accent : NSColor.separatorColor).cgColor
        titleButton.contentTintColor = isActive ? ViewModeControl.accent : .lightGray
    }

    @objc private func titleClicked(_ sender: Any?) { onActivate?() }
    @objc private func paneClicked(_ sender: Any?) { onActivate?() }
}
