import AppKit

/// 视图模式「全部照片列表」：右上区域改为可上下滚动的网格，
/// 一次列出当前目录（含递归子目录，若目录树开关打开）的所有照片。
///
/// 每格显示缩略图、文件名与 4 行简要 EXIF；支持单击选中、⌘/Shift 多选、
/// 右键复用缩略图条的操作菜单、双击回到单张大图。
final class PhotoGridView: NSView, NSCollectionViewDataSource, NSCollectionViewDelegate {

    var onSelect: ((Int) -> Void)?
    var onActivate: ((Int) -> Void)?
    var onContextAction: ((ThumbnailContextAction, [Int]) -> Void)?

    static let itemWidth: CGFloat = 168
    static let itemHeight: CGFloat = 188
    static let spacing: CGFloat = 10
    static let inset: CGFloat = 12

    /// 纯计算：给定可用宽度能排下几列（自检与布局说明共用）。
    static func columns(forWidth width: CGFloat) -> Int {
        guard width > 0 else { return 1 }
        let usable = width - inset * 2 + spacing
        return max(1, Int(floor(usable / (itemWidth + spacing))))
    }

    private let scrollView = NSScrollView()
    private let collectionView = GridCollectionView()
    private let flowLayout = NSCollectionViewFlowLayout()
    private let cellIdentifier = NSUserInterfaceItemIdentifier("PhotoScope.GridCell")

    private var items: [MediaItem] = []
    private var isProgrammaticSelection = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setupViews() {
        flowLayout.scrollDirection = .vertical
        flowLayout.itemSize = NSSize(width: Self.itemWidth, height: Self.itemHeight)
        flowLayout.minimumInteritemSpacing = Self.spacing
        flowLayout.minimumLineSpacing = Self.spacing
        flowLayout.sectionInset = NSEdgeInsets(top: Self.inset, left: Self.inset,
                                               bottom: Self.inset, right: Self.inset)

        collectionView.collectionViewLayout = flowLayout
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [.windowBackgroundColor]
        collectionView.register(GridPhotoItem.self, forItemWithIdentifier: cellIdentifier)
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        collectionView.onContextMenu = { [weak self] event in self?.buildContextMenu(for: event) }
        collectionView.onDoubleClick = { [weak self] index in self?.onActivate?(index) }

        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .windowBackgroundColor
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    override func layout() {
        super.layout()
        syncDocumentSize()
    }

    /// 垂直滚动时 documentView 的高度必须等于内容高度，宽度跟随可视区以决定列数。
    private func syncDocumentSize() {
        let width = max(scrollView.contentSize.width, Self.itemWidth + Self.inset * 2)
        let height = max(flowLayout.collectionViewContentSize.height, scrollView.contentSize.height)
        let current = collectionView.frame.size
        if abs(current.width - width) > 0.5 || abs(current.height - height) > 0.5 {
            collectionView.setFrameSize(NSSize(width: width, height: height))
            flowLayout.invalidateLayout()
        }
    }

    // MARK: - 数据

    func reload(items: [MediaItem]) {
        self.items = items
        flowLayout.invalidateLayout()
        collectionView.reloadData()
        collectionView.layoutSubtreeIfNeeded()
        syncDocumentSize()
    }

    func select(index: Int, scroll: Bool = true) {
        isProgrammaticSelection = true
        if index < 0 || index >= items.count {
            collectionView.deselectAll(nil)
        } else {
            let path = IndexPath(item: index, section: 0)
            collectionView.deselectAll(nil)
            collectionView.selectItems(at: Set([path]),
                                       scrollPosition: scroll ? .centeredVertically : [])
            if scroll {
                collectionView.scrollToItems(at: Set([path]), scrollPosition: .centeredVertically)
            }
        }
        isProgrammaticSelection = false
    }

    func refresh(indexes: [Int]) {
        let paths = indexes.filter { items.indices.contains($0) }.map { IndexPath(item: $0, section: 0) }
        guard !paths.isEmpty else { return }
        collectionView.reloadItems(at: Set(paths))
    }

    // MARK: - 右键菜单

    private func buildContextMenu(for event: NSEvent) -> NSMenu? {
        let point = collectionView.convert(event.locationInWindow, from: nil)
        guard let indexPath = collectionView.indexPathForItem(at: point),
              items.indices.contains(indexPath.item) else { return nil }
        let index = indexPath.item
        let selection = collectionView.selectionIndexPaths
        let indexes: [Int]
        if selection.count > 1 && selection.contains(indexPath) {
            indexes = selection.map(\.item).sorted()
        } else {
            indexes = [index]
            if !selection.contains(indexPath) { onSelect?(index) }
        }
        let hasRotation = indexes.contains { RotationStore.quarterTurns(for: items[$0].url) != 0 }
        let containsVideo = indexes.contains { items[$0].isVideo }
        return ThumbnailContextMenu.build(target: self, action: #selector(contextMenuItemClicked(_:)),
                                          indexes: indexes, hasRotation: hasRotation,
                                          containsVideo: containsVideo)
    }

    @objc private func contextMenuItemClicked(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? ThumbnailContextActionBox else { return }
        onContextAction?(box.action, box.indexes)
    }

    // MARK: - NSCollectionViewDataSource

    func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(_ collectionView: NSCollectionView,
                        itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        guard let cell = collectionView.makeItem(withIdentifier: cellIdentifier,
                                                 for: indexPath) as? GridPhotoItem else {
            return GridPhotoItem()
        }
        guard items.indices.contains(indexPath.item) else { return cell }
        let item = items[indexPath.item]
        cell.configure(with: item, image: ThumbnailCache.shared.cached(item.url))

        ThumbnailCache.shared.image(for: item) { [weak cell] image in
            guard let cell = cell, cell.currentURL == item.url else { return }
            cell.setThumbnail(image)
        }
        if let summary = MediaSummaryIndex.shared.cached(item) {
            cell.setSummary(summary)
        } else {
            cell.setSummary(.empty)
            MediaSummaryIndex.shared.summary(for: item) { [weak cell] value in
                guard let cell = cell, cell.currentURL == item.url else { return }
                cell.setSummary(value)
            }
        }
        return cell
    }

    // MARK: - NSCollectionViewDelegate

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard !isProgrammaticSelection, indexPaths.count == 1, let indexPath = indexPaths.first else { return }
        onSelect?(indexPath.item)
    }
}

/// 双击回到单张大图；右键沿用 AppKit 默认的 menu(for:) 流程。
private final class GridCollectionView: NSCollectionView {
    var onContextMenu: ((NSEvent) -> NSMenu?)?
    var onDoubleClick: ((Int) -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            let point = convert(event.locationInWindow, from: nil)
            if let indexPath = indexPathForItem(at: point) { onDoubleClick?(indexPath.item) }
        }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        onContextMenu?(event) ?? super.menu(for: event)
    }
}

/// 单个网格单元：缩略图 + 文件名 + 4 行简要 EXIF。
private final class GridPhotoItem: NSCollectionViewItem {

    private let thumbnailView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private var infoLabels: [NSTextField] = []
    private let badge = NSTextField(labelWithString: "")

    var currentURL: URL?

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0,
                                             width: PhotoGridView.itemWidth,
                                             height: PhotoGridView.itemHeight))
        container.wantsLayer = true
        container.layer?.cornerRadius = 4
        self.view = container

        let width = PhotoGridView.itemWidth - 16
        thumbnailView.frame = NSRect(x: 8, y: 76, width: width, height: 104)
        thumbnailView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailView.imageAlignment = .alignCenter
        thumbnailView.wantsLayer = true
        thumbnailView.layer?.cornerRadius = 3
        thumbnailView.layer?.masksToBounds = true
        thumbnailView.layer?.backgroundColor = NSColor(calibratedWhite: 0.19, alpha: 1).cgColor
        container.addSubview(thumbnailView)

        nameLabel.frame = NSRect(x: 8, y: 58, width: width, height: 15)
        nameLabel.font = NSFont.systemFont(ofSize: 10.5, weight: .medium)
        nameLabel.textColor = .labelColor
        nameLabel.alignment = .left
        nameLabel.lineBreakMode = .byTruncatingMiddle
        container.addSubview(nameLabel)

        for row in 0..<4 {
            let label = NSTextField(labelWithString: "")
            label.frame = NSRect(x: 8, y: 44 - CGFloat(row) * 12, width: width, height: 11)
            label.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            container.addSubview(label)
            infoLabels.append(label)
        }

        badge.frame = NSRect(x: width - 22, y: 164, width: 30, height: 14)
        badge.font = NSFont.boldSystemFont(ofSize: 9)
        badge.textColor = .white
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        badge.layer?.cornerRadius = 3
        badge.isHidden = true
        container.addSubview(badge)
    }

    override var isSelected: Bool {
        didSet { updateHighlight() }
    }

    func configure(with item: MediaItem, image: NSImage?) {
        currentURL = item.url
        nameLabel.stringValue = item.name
        nameLabel.toolTip = item.name
        let turns = RotationStore.quarterTurns(for: item.url)
        if item.isVideo {
            badge.stringValue = "视频"
            badge.isHidden = false
        } else if turns != 0 {
            badge.stringValue = "\(turns * 90)°"
            badge.isHidden = false
        } else {
            badge.isHidden = true
        }
        thumbnailView.image = image ?? NSImage(systemSymbolName: item.isVideo ? "film" : "photo",
                                               accessibilityDescription: nil)
        infoLabels.forEach { $0.stringValue = "" }
        updateHighlight()
    }

    func setThumbnail(_ image: NSImage?) {
        guard let image else { return }
        thumbnailView.image = image
    }

    func setSummary(_ summary: MediaSummary) {
        let lines = summary.lines
        for (index, label) in infoLabels.enumerated() {
            let text = index < lines.count ? lines[index] : ""
            label.stringValue = text
            label.toolTip = text
        }
    }

    private func updateHighlight() {
        guard let layer = view.layer else { return }
        layer.borderWidth = isSelected ? 3 : 0
        layer.borderColor = ViewModeControl.accent.cgColor
    }
}
