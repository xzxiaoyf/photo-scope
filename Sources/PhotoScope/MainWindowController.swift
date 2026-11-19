import AppKit
import CoreGraphics
import UniformTypeIdentifiers

private enum ToolbarID {
    static let open = "ps.open"
    static let previous = "ps.previous"
    static let next = "ps.next"
    static let zoomOut = "ps.zoomOut"
    static let zoomIn = "ps.zoomIn"
    static let fit = "ps.fit"
    static let actual = "ps.actual"
    static let info = "ps.info"
    static let map = "ps.map"
    static let save = "ps.save"
}

/// 主窗口：左侧目录树 / 右上大图或视频 / 右下缩略图条 / 顶部工具栏。
///
/// 代码按「服务层（Services）+ 视图层（Views）+ 控制器」划分，
/// 后续新增功能（幻灯片、批量导出、排序、评分、关键字检索等）只需在工具栏与控制器挂新入口。
final class MainWindowController: NSWindowController,
                                  NSToolbarDelegate,
                                  NSSplitViewDelegate,
                                  DirectoryTreeViewDelegate {

    // MARK: - 视图

    private let splitView = NSSplitView()
    private let treeView = DirectoryTreeView()
    private let viewerContainer = NSView()
    private let imageViewer = ImageViewer()
    private let videoView = VideoPlayerView()
    private let stripView = ThumbnailStrip()
    private let statusLabel = NSTextField(labelWithString: "请选择左侧目录")
    private let zoomLabel = NSTextField(labelWithString: "")

    private var toolbarButtons: [String: NSButton] = [:]
    private var infoController: MetadataWindowController?
    private var mapController: MapWindowController?
    private var keyMonitor: Any?
    /// 自动化诊断：把保存面板中的质量控件渲染到指定 PNG 路径
    var qualityDumpPath: String?

    // MARK: - 状态

    private var items: [MediaItem] = []
    private var currentIndex: Int = -1
    private var currentDirectory: URL?
    private var currentMetadata: PhotoMetadata?

    private var scanToken = UUID()
    private var imageToken = UUID()
    private var metadataToken = UUID()
    private var sortToken = UUID()
    /// 最近一次右键/菜单操作的提示，附加在状态栏末尾。
    private var statusNote: String?
    /// Finder「打开方式」传入单个文件时，等目录扫描完成后定位到它。
    /// 同时记录所属目录，避免用户随后点了别的目录时把选中项串过去。
    private var pendingSelection: (directory: URL, file: URL)?

    private let lastDirectoryKey = "PhotoScope.lastDirectory"

    private var currentItem: MediaItem? {
        items.indices.contains(currentIndex) ? items[currentIndex] : nil
    }

    // MARK: - 初始化

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "PhotoScope — 照片查看器"
        window.minSize = NSSize(width: 940, height: 620)
        window.center()
        window.setFrameAutosaveName("PhotoScope.MainWindow")
        super.init(window: window)
        setupLayout()
        setupToolbar()
        setupInteractions()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func windowDidLoad() {
        super.windowDidLoad()
        splitView.setPosition(250, ofDividerAt: 0)
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        // NSSplitView 只有在窗口完成布局之后才能正确设置分隔线位置
        DispatchQueue.main.async { [weak self] in
            self?.splitView.setPosition(250, ofDividerAt: 0)
            self?.splitView.layoutSubtreeIfNeeded()
        }
    }

    deinit {
        if let monitor = keyMonitor { NSEvent.removeMonitor(monitor) }
    }

    // MARK: - 布局

    private func setupLayout() {
        guard let content = window?.contentView else { return }

        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.translatesAutoresizingMaskIntoConstraints = false

        let leftPane = NSView()
        leftPane.translatesAutoresizingMaskIntoConstraints = false
        let rightPane = NSView()
        rightPane.translatesAutoresizingMaskIntoConstraints = false
        splitView.addArrangedSubview(leftPane)
        splitView.addArrangedSubview(rightPane)

        content.addSubview(splitView)
        NSLayoutConstraint.activate([
            splitView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            splitView.topAnchor.constraint(equalTo: content.topAnchor),
            splitView.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])

        // 左侧：目录树
        treeView.translatesAutoresizingMaskIntoConstraints = false
        leftPane.addSubview(treeView)
        pin(treeView, to: leftPane)

        // 右侧：大图 / 状态栏 / 缩略图条
        viewerContainer.translatesAutoresizingMaskIntoConstraints = false
        imageViewer.translatesAutoresizingMaskIntoConstraints = false
        videoView.translatesAutoresizingMaskIntoConstraints = false
        viewerContainer.addSubview(imageViewer)
        viewerContainer.addSubview(videoView)
        pin(imageViewer, to: viewerContainer)
        pin(videoView, to: viewerContainer)
        videoView.isHidden = true

        let statusBar = NSView()
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        statusBar.wantsLayer = true
        statusBar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle
        zoomLabel.translatesAutoresizingMaskIntoConstraints = false
        zoomLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        zoomLabel.textColor = .secondaryLabelColor
        zoomLabel.alignment = .right
        statusBar.addSubview(statusLabel)
        statusBar.addSubview(zoomLabel)

        stripView.translatesAutoresizingMaskIntoConstraints = false
        rightPane.addSubview(viewerContainer)
        rightPane.addSubview(statusBar)
        rightPane.addSubview(stripView)

        NSLayoutConstraint.activate([
            viewerContainer.leadingAnchor.constraint(equalTo: rightPane.leadingAnchor),
            viewerContainer.trailingAnchor.constraint(equalTo: rightPane.trailingAnchor),
            viewerContainer.topAnchor.constraint(equalTo: rightPane.topAnchor),
            viewerContainer.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            statusBar.leadingAnchor.constraint(equalTo: rightPane.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: rightPane.trailingAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 26),
            statusBar.bottomAnchor.constraint(equalTo: stripView.topAnchor),

            statusLabel.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 10),
            statusLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: zoomLabel.leadingAnchor, constant: -10),
            zoomLabel.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor, constant: -10),
            zoomLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            zoomLabel.widthAnchor.constraint(equalToConstant: 70),

            stripView.leadingAnchor.constraint(equalTo: rightPane.leadingAnchor),
            stripView.trailingAnchor.constraint(equalTo: rightPane.trailingAnchor),
            stripView.bottomAnchor.constraint(equalTo: rightPane.bottomAnchor),
            stripView.heightAnchor.constraint(equalToConstant: 132)
        ])
    }

    private func pin(_ view: NSView, to container: NSView) {
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }

    // MARK: - 工具栏

    private func setupToolbar() {
        let toolbar = NSToolbar(identifier: NSToolbar.Identifier("PhotoScope.MainToolbar"))
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.sizeMode = .regular
        window?.toolbar = toolbar
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            NSToolbarItem.Identifier(ToolbarID.open),
            NSToolbarItem.Identifier(ToolbarID.previous),
            NSToolbarItem.Identifier(ToolbarID.next),
            .flexibleSpace,
            NSToolbarItem.Identifier(ToolbarID.zoomOut),
            NSToolbarItem.Identifier(ToolbarID.zoomIn),
            NSToolbarItem.Identifier(ToolbarID.fit),
            NSToolbarItem.Identifier(ToolbarID.actual),
            .flexibleSpace,
            NSToolbarItem.Identifier(ToolbarID.info),
            NSToolbarItem.Identifier(ToolbarID.map),
            NSToolbarItem.Identifier(ToolbarID.save)
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let id = itemIdentifier.rawValue
        let specs: [String: (String, String, Selector)] = [
            ToolbarID.open: ("打开文件夹", "folder", #selector(openFolder(_:))),
            ToolbarID.previous: ("上一张", "chevron.left", #selector(previousPhoto(_:))),
            ToolbarID.next: ("下一张", "chevron.right", #selector(nextPhoto(_:))),
            ToolbarID.zoomOut: ("缩小", "minus.magnifyingglass", #selector(zoomOut(_:))),
            ToolbarID.zoomIn: ("放大", "plus.magnifyingglass", #selector(zoomIn(_:))),
            ToolbarID.fit: ("适合窗口", "arrow.down.right.and.arrow.up.left", #selector(fitToWindow(_:))),
            ToolbarID.actual: ("实际大小", "1.circle", #selector(actualSize(_:))),
            ToolbarID.info: ("信息", "info.circle", #selector(toggleInfo(_:))),
            ToolbarID.map: ("地图位置", "mappin.circle", #selector(showMap(_:))),
            ToolbarID.save: ("另存为 JPG", "square.and.arrow.down", #selector(saveAsJPEG(_:)))
        ]
        guard let spec = specs[id] else { return nil }

        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        let button = NSButton(title: spec.0, target: self, action: spec.2)
        button.image = NSImage(systemSymbolName: spec.1, accessibilityDescription: spec.0)
        button.imagePosition = .imageLeading
        button.bezelStyle = .rounded
        button.font = NSFont.systemFont(ofSize: 11)
        button.toolTip = spec.0
        button.sizeToFit()
        var size = button.frame.size
        size.width += 10
        size.height = max(26, size.height)
        button.setFrameSize(size)

        item.view = button
        item.label = spec.0
        item.paletteLabel = spec.0
        item.toolTip = spec.0

        toolbarButtons[id] = button
        return item
    }

    // MARK: - 交互绑定

    private func setupInteractions() {
        treeView.delegate = self
        stripView.onSelect = { [weak self] index in
            self?.select(index: index)
        }
        stripView.onContextAction = { [weak self] action, indexes in
            self?.handleContextAction(action, indexes: indexes)
        }
        imageViewer.onZoomChanged = { [weak self] magnification in
            self?.zoomLabel.stringValue = String(format: "%.0f%%", magnification * 100)
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.window?.isKeyWindow == true else { return event }
            if self.window?.firstResponder is NSTextView { return event }
            switch event.keyCode {
            case 123: // ←
                self.previousPhoto(nil)
                return nil
            case 124: // →
                self.nextPhoto(nil)
                return nil
            default:
                return event
            }
        }

        updateSaveToolTip()
        restoreLastDirectory()
    }

    private func restoreLastDirectory() {
        guard let path = UserDefaults.standard.string(forKey: lastDirectoryKey) else { return }
        let url = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return }
        treeView.addRoot(url: url, select: true)
    }

    // MARK: - 目录与列表

    func openDirectory(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: lastDirectoryKey)
        treeView.addRoot(url: url, select: true)
    }

    /// Finder「打开方式」/ 双击把目录或单个媒体文件交给本程序时调用。
    /// - Returns: 路径可用并已受理时返回 true；AppDelegate 据此回复 Launch Services。
    @discardableResult
    func revealFromFinder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              let request = OpenFileRouter.request(for: url, isDirectory: isDirectory.boolValue) else {
            return false
        }
        pendingSelection = request.selectedFile.map { (request.directory, $0) }
        openDirectory(request.directory)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        return true
    }

    func directoryTree(_ tree: DirectoryTreeView, didSelectDirectory url: URL) {
        currentDirectory = url
        UserDefaults.standard.set(url.path, forKey: lastDirectoryKey)
        reloadMedia()
    }

    func directoryTree(_ tree: DirectoryTreeView, didChangeRecursive flag: Bool) {
        reloadMedia()
    }

    private func reloadMedia() {
        guard let directory = currentDirectory else { return }
        let token = UUID()
        scanToken = token
        statusLabel.stringValue = "正在读取「\(directory.lastPathComponent)」…"

        // 仅当本次扫描的目录与 Finder 打开的文件所属目录一致时，才应用定位。
        let pendingFile: URL? = {
            guard let pending = pendingSelection,
                  pending.directory.standardizedFileURL == directory.standardizedFileURL else { return nil }
            return pending.file
        }()

        let recursive = treeView.isRecursive
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = MediaScanner.scan(directory: directory, recursive: recursive)
            // 目录加载即按用户记住的排序偏好排列（拍摄时间/型号/镜头需要读 EXIF）。
            MediaSortIndex.shared.sorted(found, options: MediaSortOptions.current) { [weak self] sorted in
                guard let self = self, self.scanToken == token else { return }
                self.pendingSelection = nil
                self.items = sorted
                self.stripView.reload(items: sorted)

                var index = sorted.isEmpty ? -1 : 0
                var note = "排序：\(MediaSortOptions.current.summary)"
                if let target = pendingFile {
                    if let found = sorted.firstIndex(where: { $0.url.standardizedFileURL == target }) {
                        index = found
                    } else {
                        note += " · 未列出「\(target.lastPathComponent)」"
                    }
                }
                self.select(index: index)
                self.updateToolbarState()
                self.statusNote = note
                self.updateStatus()
            }
        }
    }

    // MARK: - 选中与加载

    private func select(index: Int) {
        statusNote = nil
        guard index >= 0, index < items.count else {
            currentIndex = -1
            currentMetadata = nil
            imageToken = UUID()
            metadataToken = UUID()
            imageViewer.clear()
            imageViewer.isHidden = false
            videoView.stop()
            videoView.isHidden = true
            stripView.select(index: -1)
            infoController?.update(with: nil, fileName: nil)
            updateToolbarState()
            updateStatus()
            return
        }

        currentIndex = index
        currentMetadata = nil
        let item = items[index]
        stripView.select(index: index)

        let imageLoad = UUID()
        let metadataLoad = UUID()
        imageToken = imageLoad
        metadataToken = metadataLoad

        if item.isVideo {
            imageViewer.clear()
            imageViewer.isHidden = true
            videoView.isHidden = false
            videoView.load(url: item.url)
            zoomLabel.stringValue = "—"
        } else {
            videoView.stop()
            videoView.isHidden = true
            imageViewer.isHidden = false
            imageViewer.clear()
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let image = ImageDecoder.displayNSImage(url: item.url)
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.imageToken == imageLoad else { return }
                    self.imageViewer.setImage(image)
                    self.zoomLabel.stringValue = String(format: "%.0f%%", self.imageViewer.magnification * 100)
                }
            }
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let metadata = MetadataReader.read(item)
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.metadataToken == metadataLoad else { return }
                self.currentMetadata = metadata
                self.infoController?.update(with: metadata, fileName: item.name)
                self.updateToolbarState()
                self.updateStatus()
            }
        }

        updateToolbarState()
        updateStatus()
    }

    /// 自动化验证用：按文件名选中一张照片。
    func selectItem(named name: String) {
        if let index = items.firstIndex(where: { $0.name == name }) {
            select(index: index)
        }
    }

    private func updateToolbarState() {
        let hasItem = currentItem != nil
        let isImage = currentItem.map { !$0.isVideo } ?? false
        let hasGPS = currentMetadata?.gps != nil

        setEnabled(ToolbarID.previous, currentIndex > 0)
        setEnabled(ToolbarID.next, currentIndex >= 0 && currentIndex + 1 < items.count)
        setEnabled(ToolbarID.zoomIn, isImage)
        setEnabled(ToolbarID.zoomOut, isImage)
        setEnabled(ToolbarID.fit, isImage)
        setEnabled(ToolbarID.actual, isImage)
        setEnabled(ToolbarID.info, hasItem)
        setEnabled(ToolbarID.map, hasGPS)
        setEnabled(ToolbarID.save, hasItem)

        let infoVisible = infoController?.window?.isVisible ?? false
        toolbarButtons[ToolbarID.info]?.contentTintColor = infoVisible ? .controlAccentColor : nil
        toolbarButtons[ToolbarID.map]?.contentTintColor = hasGPS ? .controlAccentColor : nil
        updateSaveToolTip()
    }

    private func setEnabled(_ id: String, _ enabled: Bool) {
        toolbarButtons[id]?.isEnabled = enabled
    }

    private func updateStatus() {
        guard let item = currentItem else {
            statusLabel.stringValue = currentDirectory == nil
                ? "请选择左侧目录"
                : "该目录下没有可浏览的照片或视频"
            zoomLabel.stringValue = ""
            return
        }
        var parts: [String] = [
            item.name,
            "\(currentIndex + 1)/\(items.count)",
            MetadataReader.byteString(item.byteCount)
        ]
        if let size = currentMetadata?.pixelSize {
            parts.append("\(Int(size.width))×\(Int(size.height))")
        }
        if item.isVideo { parts.append("视频") }
        let turns = RotationStore.quarterTurns(for: item.url)
        if turns != 0 { parts.append("旋转 \(turns * 90)°") }
        if let note = statusNote { parts.append(note) }
        statusLabel.stringValue = parts.joined(separator: "   •   ")
    }

    // MARK: - 缩略图右键菜单：旋转 / 删除 / 排序

    private func handleContextAction(_ action: ThumbnailContextAction, indexes: [Int]) {
        let valid = Array(Set(indexes)).sorted().filter { items.indices.contains($0) }
        switch action {
        case .rotateClockwise: rotate(1, indexes: valid)
        case .rotateCounterClockwise: rotate(-1, indexes: valid)
        case .resetRotation: clearRotation(indexes: valid)
        case .delete: deleteItems(at: valid)
        case .revealInFinder: revealInFinder(valid)
        case .copyPath: copyPaths(valid)
        case .saveAsJPEG: saveAsJPEG(nil)
        case .sort(let key, let order): changeSort(key: key, order: order)
        case .resetSort: changeSort(key: .fileName, order: .ascending)
        }
    }

    /// 旋转为「非破坏性覆盖」：只写本机偏好，显示 / 缩略图 / JPG 导出统一叠加。
    private func rotate(_ delta: Int, indexes: [Int]) {
        let imageIndexes = indexes.filter { !items[$0].isVideo }
        guard !imageIndexes.isEmpty else { return }
        for index in imageIndexes {
            let url = items[index].url
            RotationStore.add(delta, for: url)
            ThumbnailCache.shared.invalidate(url)
        }
        stripView.refresh(indexes: imageIndexes)
        if imageIndexes.contains(currentIndex) { select(index: currentIndex) }
        statusNote = delta > 0
            ? "已顺时针旋转 \(imageIndexes.count) 张（原文件未改动）"
            : "已逆时针旋转 \(imageIndexes.count) 张（原文件未改动）"
        updateStatus()
    }

    private func clearRotation(indexes: [Int]) {
        guard !indexes.isEmpty else { return }
        for index in indexes {
            let url = items[index].url
            RotationStore.reset(for: url)
            ThumbnailCache.shared.invalidate(url)
        }
        stripView.refresh(indexes: indexes)
        if indexes.contains(currentIndex) { select(index: currentIndex) }
        statusNote = "已恢复 \(indexes.count) 张照片的原始方向"
        updateStatus()
    }

    /// 删除走系统废纸篓（可恢复），不做不可撤销的 rm。
    private func deleteItems(at indexes: [Int]) {
        let targets = indexes.compactMap { items.indices.contains($0) ? items[$0] : nil }
        guard !targets.isEmpty, let window = window else { return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = targets.count == 1
            ? "将「\(targets[0].name)」移到废纸篓？"
            : "将 \(targets.count) 个文件移到废纸篓？"
        alert.informativeText = "文件不会被永久删除，可从废纸篓恢复；这些照片的旋转设置也会一并清除。"
        alert.addButton(withTitle: "移到废纸篓")
        alert.addButton(withTitle: "取消")
        let anchor = indexes.min() ?? 0
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.performTrash(targets, anchor: anchor)
        }
    }

    private func performTrash(_ targets: [MediaItem], anchor: Int) {
        var removed = Set<URL>()
        var failures: [String] = []
        for item in targets {
            do {
                var resulting: NSURL?
                try FileManager.default.trashItem(at: item.url, resultingItemURL: &resulting)
                let standardized = item.url.standardizedFileURL
                removed.insert(standardized)
                ThumbnailCache.shared.invalidate(item.url)
                MediaSortIndex.shared.invalidate(item.url)
            } catch {
                failures.append("\(item.name)：\(error.localizedDescription)")
            }
        }
        RotationStore.purge(targets.filter { removed.contains($0.url.standardizedFileURL) }.map(\.url))
        guard !removed.isEmpty else {
            showWarning("未能移到废纸篓", failures.joined(separator: "\n"))
            return
        }

        let remaining = items.filter { !removed.contains($0.url.standardizedFileURL) }
        items = remaining
        stripView.reload(items: remaining)
        let next = remaining.isEmpty ? -1 : min(max(0, anchor), remaining.count - 1)
        select(index: next)
        updateToolbarState()
        statusNote = "已移到废纸篓 \(removed.count) 个文件"
        updateStatus()
        if !failures.isEmpty {
            showWarning("部分文件未能移到废纸篓", failures.joined(separator: "\n"))
        }
    }

    private func revealInFinder(_ indexes: [Int]) {
        let urls = indexes.map { items[$0].url }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    private func copyPaths(_ indexes: [Int]) {
        let paths = indexes.map { items[$0].url.path }
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
        statusNote = "已复制 \(paths.count) 个文件路径"
        updateStatus()
    }

    // MARK: - 排序

    private func changeSort(key: MediaSortKey?, order: MediaSortOrder?) {
        var options = MediaSortOptions.current
        if let key = key { options.key = key }
        if let order = order { options.order = order }
        MediaSortOptions.current = options
        applySort()
    }

    /// 排序后按文件 URL 找回当前照片，避免「排完序大图变成另一张」。
    private func applySort() {
        guard items.count > 1 else {
            statusNote = "排序：\(MediaSortOptions.current.summary)"
            updateStatus()
            return
        }
        let token = UUID()
        sortToken = token
        let anchorURL = currentItem?.url
        let options = MediaSortOptions.current
        statusLabel.stringValue = "正在按「\(options.summary)」排序…"
        MediaSortIndex.shared.sorted(items, options: options) { [weak self] sorted in
            guard let self = self, self.sortToken == token else { return }
            self.items = sorted
            self.stripView.reload(items: sorted)
            let index = anchorURL.flatMap { url in sorted.firstIndex { $0.url == url } }
                ?? (sorted.isEmpty ? -1 : 0)
            self.select(index: index)
            self.updateToolbarState()
            self.statusNote = "排序：\(options.summary)"
            self.updateStatus()
        }
    }

    private func showWarning(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "好")
        guard let window = window else { return }
        alert.beginSheetModal(for: window)
    }

    // MARK: - 主菜单入口（与右键菜单共用同一套处理）

    @objc func rotateClockwise(_ sender: Any?) { handleContextAction(.rotateClockwise, indexes: [currentIndex]) }
    @objc func rotateCounterClockwise(_ sender: Any?) { handleContextAction(.rotateCounterClockwise, indexes: [currentIndex]) }
    @objc func resetPhotoRotation(_ sender: Any?) { handleContextAction(.resetRotation, indexes: [currentIndex]) }
    @objc func deleteSelectedPhoto(_ sender: Any?) { handleContextAction(.delete, indexes: [currentIndex]) }
    @objc func sortByFileName(_ sender: Any?) { changeSort(key: .fileName, order: nil) }
    @objc func sortByCaptureDate(_ sender: Any?) { changeSort(key: .captureDate, order: nil) }
    @objc func sortByModel(_ sender: Any?) { changeSort(key: .model, order: nil) }
    @objc func sortByLens(_ sender: Any?) { changeSort(key: .lens, order: nil) }
    @objc func sortAscending(_ sender: Any?) { changeSort(key: nil, order: .ascending) }
    @objc func sortDescending(_ sender: Any?) { changeSort(key: nil, order: .descending) }

    // MARK: - 工具栏 / 菜单动作

    @objc func openFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "打开"
        panel.message = "选择要查看照片的目录"
        guard let window = window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.openDirectory(url)
        }
    }

    @objc func previousPhoto(_ sender: Any?) {
        guard currentIndex > 0 else { return }
        select(index: currentIndex - 1)
    }

    @objc func nextPhoto(_ sender: Any?) {
        guard currentIndex + 1 < items.count else { return }
        select(index: currentIndex + 1)
    }

    @objc func zoomIn(_ sender: Any?) {
        guard currentItem?.isVideo == false else { return }
        imageViewer.zoomIn()
    }

    @objc func zoomOut(_ sender: Any?) {
        guard currentItem?.isVideo == false else { return }
        imageViewer.zoomOut()
    }

    @objc func fitToWindow(_ sender: Any?) {
        guard currentItem?.isVideo == false else { return }
        imageViewer.fit()
    }

    @objc func actualSize(_ sender: Any?) {
        guard currentItem?.isVideo == false else { return }
        imageViewer.actualSize()
    }

    @objc func toggleInfo(_ sender: Any?) {
        if infoController == nil {
            infoController = MetadataWindowController()
            infoController?.mainController = self
        }
        infoController?.update(with: currentMetadata, fileName: currentItem?.name)
        infoController?.toggle()
        updateToolbarState()
    }

    func debugMapHTML() { mapController?.debugDumpHTML() }

    func infoPanelDidClose() {
        updateToolbarState()
    }

    @objc func showMap(_ sender: Any?) {
        guard let gps = currentMetadata?.gps, let name = currentItem?.name else { return }
        if mapController == nil { mapController = MapWindowController() }
        mapController?.show(location: gps, fileName: name)
    }

    @objc func saveAsJPEG(_ sender: Any?) {
        guard let item = currentItem, let window = window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = JPEGExporter.suggestedName(for: item)
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.jpeg]
        let qualityView = JPEGQualityAccessoryView(quality: JPEGExporter.preferredQuality)
        panel.accessoryView = qualityView
        panel.message = item.isVideo
            ? "提取视频代表帧保存为 JPG，写入拍摄时间与 GPS；可在下方调整质量"
            : "按原始尺寸转换为 JPG，保留原始 EXIF / GPS 信息；可在下方调整质量"
        if let dumpPath = qualityDumpPath {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                let ok = qualityView.renderToPNG(URL(fileURLWithPath: dumpPath))
                NSLog("PhotoScope quality accessory dump: %@ frame=%@ subviews=%d",
                      ok ? "ok" : "failed", NSStringFromRect(qualityView.frame),
                      qualityView.subviews.count)
            }
        }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let destination = panel.url else { return }
            let quality = JPEGExporter.clamped(qualityView.quality)
            JPEGExporter.preferredQuality = quality
            let percent = JPEGExporter.percent(quality)
            self?.updateSaveToolTip()
            self?.statusLabel.stringValue = "正在导出 JPG（质量 \(percent)%，写入 EXIF）…"
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try JPEGExporter.exportDetailed(item, to: destination, quality: quality)
                    DispatchQueue.main.async { [weak self] in
                        self?.updateStatus()
                        let exifNote = result.metadataPreserved
                            ? "已保留 EXIF/GPS（\(result.metadataGroupCount) 组元数据）"
                            : "元数据写入失败，已仅保存图像"
                        self?.statusLabel.stringValue = "已导出 JPG（质量 \(percent)%，\(exifNote)）：\(result.url.path)"
                    }
                } catch {
                    DispatchQueue.main.async { [weak self] in
                        self?.updateStatus()
                        self?.showExportError(error)
                    }
                }
            }
        }
    }

    /// 文件菜单：预设/修改默认的 JPG 导出质量（导出时仍可临时覆盖）。
    @objc func configureJPEGQuality(_ sender: Any?) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "JPG 导出质量"
        alert.informativeText = "设置另存为 JPG 时使用的压缩质量。数值越大细节越多，文件也越大。"
        let qualityView = JPEGQualityAccessoryView(quality: JPEGExporter.preferredQuality)
        alert.accessoryView = qualityView
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let quality = JPEGExporter.clamped(qualityView.quality)
        JPEGExporter.preferredQuality = quality
        updateSaveToolTip()
        statusLabel.stringValue = "JPG 导出质量已设为 \(JPEGExporter.percent(quality))%（下次导出生效，也可在保存面板临时调整）"
    }

    private func updateSaveToolTip() {
        let percent = JPEGExporter.percent(JPEGExporter.preferredQuality)
        toolbarButtons[ToolbarID.save]?.toolTip = "另存为 JPG（默认质量 \(percent)%，保留原始 EXIF / GPS）"
    }

    private func showExportError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "导出失败"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "好")
        guard let window = window else { return }
        alert.beginSheetModal(for: window)
    }

    // MARK: - 分栏约束

    func splitView(_ splitView: NSSplitView,
                   constrainMinCoordinate proposedMinimumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(180, proposedMinimumPosition)
    }

    func splitView(_ splitView: NSSplitView,
                   constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(max(260, splitView.bounds.width - 520), proposedMaximumPosition)
    }

    // MARK: - 自动化诊断（--dump-layout / --rotate / --screenshot）

    /// 无交互地触发一次与右键菜单等价的动作，用于验证旋转/排序等链路。
    func debugApply(_ action: ThumbnailContextAction) {
        handleContextAction(action, indexes: [currentIndex])
    }

    func debugDumpOrder() {
        let preview = items.prefix(12).map(\.name).joined(separator: ", ")
        print("ORDER [\(MediaSortOptions.current.summary)] \(items.count) 项: \(preview)")
    }

    func dumpLayout() {
        guard let window = window, let content = window.contentView else { return }
        NSLog("PhotoScope layout: window=%@ content=%@ split=%@ tree=%@ viewer=%@ strip=%@ toolbar=%@",
              NSStringFromRect(window.frame), NSStringFromRect(content.bounds),
              NSStringFromRect(splitView.frame), NSStringFromRect(treeView.frame),
              NSStringFromRect(viewerContainer.frame), NSStringFromRect(stripView.frame),
              window.toolbar?.items.map { "\($0.itemIdentifier.rawValue):\(NSStringFromRect($0.view?.frame ?? .zero))" }.joined(separator: ",") ?? "none")
        treeView.dumpLayout()
        videoView.dumpLayout()
    }

    func captureScreenshot(to url: URL) -> Bool {
        guard let window = window else { return false }
        window.contentView?.layoutSubtreeIfNeeded()

        var rep: NSBitmapImageRep?
        // 优先抓取整个窗口（含标题栏与工具栏）
        if let cgImage = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            CGWindowID(window.windowNumber),
            [.boundsIgnoreFraming]
        ) {
            rep = NSBitmapImageRep(cgImage: cgImage)
        }
        // 无屏幕录制权限时回退到内容视图缓存
        if rep == nil, let view = window.contentView {
            let bounds = view.bounds
            let cached = view.bitmapImageRepForCachingDisplay(in: bounds)
            if let cached = cached { view.cacheDisplay(in: bounds, to: cached) }
            rep = cached
        }
        guard let imageRep = rep,
              let data = imageRep.representation(using: .png, properties: [:]) else { return false }
        do {
            try data.write(to: url)
            return true
        } catch {
            NSLog("PhotoScope screenshot write failed: %@", error.localizedDescription)
            return false
        }
    }
}
