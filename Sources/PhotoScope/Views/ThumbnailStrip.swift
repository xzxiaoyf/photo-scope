import AppKit

/// 右侧底部：当前目录媒体的横向缩略图条。
///
/// 支持单击导航、⌘/Shift 多选，以及在照片上右键弹出操作菜单
/// （旋转 / 删除 / 排序等）。菜单本身由 ThumbnailContextMenu 构建，
/// 这里只负责把「点了哪几张」传递给控制器。
final class ThumbnailStrip: NSView, NSCollectionViewDataSource, NSCollectionViewDelegate {

    var onSelect: ((Int) -> Void)?
    var onContextAction: ((ThumbnailContextAction, [Int]) -> Void)?

    private let scrollView = NSScrollView()
    private let collectionView = ContextCollectionView()
    private let flowLayout = NSCollectionViewFlowLayout()
    private let cellIdentifier = NSUserInterfaceItemIdentifier("PhotoScope.ThumbnailCell")

    private let itemSize = NSSize(width: 132, height: 86)
    private let stripHeight: CGFloat = 132

    private var items: [MediaItem] = []
    private var isProgrammaticSelection = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setupViews() {
        flowLayout.scrollDirection = .horizontal
        flowLayout.itemSize = itemSize
        flowLayout.minimumInteritemSpacing = 8
        flowLayout.minimumLineSpacing = 8
        flowLayout.sectionInset = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)

        collectionView.collectionViewLayout = flowLayout
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [.windowBackgroundColor]
        collectionView.register(ThumbnailItem.self, forItemWithIdentifier: cellIdentifier)
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.frame = NSRect(x: 0, y: 0, width: 800, height: stripHeight)
        collectionView.onContextMenu = { [weak self] event in
            self?.buildContextMenu(for: event)
        }

        scrollView.documentView = collectionView
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
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

    /// 横向滚动依赖 documentView 的真实宽度；NSCollectionView 不会自动把它撑开到内容宽度。
    private func syncDocumentSize() {
        let width = max(flowLayout.collectionViewContentSize.width, scrollView.contentSize.width)
        let height = max(stripHeight, scrollView.contentSize.height)
        let current = collectionView.frame.size
        if abs(current.width - width) > 0.5 || abs(current.height - height) > 0.5 {
            collectionView.setFrameSize(NSSize(width: width, height: height))
            collectionView.needsLayout = true
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

    func select(index: Int) {
        isProgrammaticSelection = true
        if index < 0 || index >= items.count {
            collectionView.deselectAll(nil)
        } else {
            let indexPath = IndexPath(item: index, section: 0)
            collectionView.deselectAll(nil)
            collectionView.selectItems(at: Set([indexPath]), scrollPosition: .centeredHorizontally)
        }
        isProgrammaticSelection = false
    }

    /// 旋转后只重绘受影响的缩略图（控制器会先让缩略图缓存失效）。
    func refresh(indexes: [Int]) {
        let paths = indexes
            .filter { items.indices.contains($0) }
            .map { IndexPath(item: $0, section: 0) }
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
            // 右键落在多选集合内：对全部选中项批量操作
            indexes = selection.map(\.item).sorted()
        } else {
            indexes = [index]
            // 右键落在未选中的照片上：先把它设为当前照片，让大图与后续操作对象一致
            if !selection.contains(indexPath) { onSelect?(index) }
        }

        let hasRotation = indexes.contains { RotationStore.quarterTurns(for: items[$0].url) != 0 }
        let containsVideo = indexes.contains { items[$0].isVideo }

        return ThumbnailContextMenu.build(
            target: self,
            action: #selector(contextMenuItemClicked(_:)),
            indexes: indexes,
            hasRotation: hasRotation,
            containsVideo: containsVideo
        )
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
                                                 for: indexPath) as? ThumbnailItem else {
            return ThumbnailItem()
        }
        guard items.indices.contains(indexPath.item) else { return cell }
        let item = items[indexPath.item]
        cell.configure(with: item, image: ThumbnailCache.shared.cached(item.url))

        ThumbnailCache.shared.image(for: item) { [weak cell] image in
            guard let cell = cell, cell.currentURL == item.url else { return }
            cell.setThumbnail(image)
        }
        return cell
    }

    // MARK: - NSCollectionViewDelegate

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        // 多选只用于批量右键操作，不改变大图；单选才触发导航。
        guard !isProgrammaticSelection, indexPaths.count == 1, let indexPath = indexPaths.first else { return }
        onSelect?(indexPath.item)
    }
}

/// 只重写 menu(for:)，沿用 AppKit 默认的右键弹出流程。
private final class ContextCollectionView: NSCollectionView {
    var onContextMenu: ((NSEvent) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        onContextMenu?(event) ?? super.menu(for: event)
    }
}

/// 单个缩略图：图片 + 文件名 + 视频/旋转角标。
private final class ThumbnailItem: NSCollectionViewItem {

    private let thumbnailView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")

    var currentURL: URL?

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 132, height: 86))
        container.wantsLayer = true
        container.layer?.cornerRadius = 6
        container.layer?.borderWidth = 0
        self.view = container

        thumbnailView.frame = NSRect(x: 4, y: 22, width: 124, height: 60)
        thumbnailView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailView.imageAlignment = .alignCenter
        thumbnailView.wantsLayer = true
        thumbnailView.layer?.cornerRadius = 4
        thumbnailView.layer?.masksToBounds = true
        // 中性深色底：等比缩放留下的留白不会在深色界面里形成刺眼白条
        thumbnailView.layer?.backgroundColor = NSColor(calibratedWhite: 0.19, alpha: 1).cgColor
        container.addSubview(thumbnailView)

        nameLabel.frame = NSRect(x: 4, y: 5, width: 124, height: 16)
        nameLabel.font = NSFont.systemFont(ofSize: 10)
        nameLabel.textColor = .secondaryLabelColor
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingMiddle
        container.addSubview(nameLabel)

        badge.frame = NSRect(x: 96, y: 62, width: 30, height: 16)
        badge.font = NSFont.boldSystemFont(ofSize: 10)
        badge.textColor = .white
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        badge.layer?.cornerRadius = 4
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
        thumbnailView.image = image ?? placeholder(for: item)
        updateHighlight()
    }

    func setThumbnail(_ image: NSImage?) {
        guard let image = image else { return }
        thumbnailView.image = image
    }

    private func updateHighlight() {
        guard let layer = view.layer else { return }
        layer.borderWidth = isSelected ? 3 : 0
        layer.borderColor = NSColor.controlAccentColor.cgColor
    }

    private func placeholder(for item: MediaItem) -> NSImage? {
        let symbol = item.isVideo ? "film" : "photo"
        return NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    }
}
