import AppKit

protocol DirectoryTreeViewDelegate: AnyObject {
    func directoryTree(_ tree: DirectoryTreeView, didSelectDirectory url: URL)
    func directoryTree(_ tree: DirectoryTreeView, didChangeRecursive flag: Bool)
}

/// 左侧目录树：快捷位置 + 用户添加的目录，子节点按需加载。
final class DirectoryTreeView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {

    weak var delegate: DirectoryTreeViewDelegate?

    private let outlineView = NSOutlineView()
    private let scrollView = NSScrollView()
    private let addButton = NSButton(title: "添加目录…", target: nil, action: nil)
    private let recursiveButton = NSButton(checkboxWithTitle: "包含子文件夹", target: nil, action: nil)
    private let cellIdentifier = NSUserInterfaceItemIdentifier("PhotoScope.DirectoryCell")
    private let rootsKey = "PhotoScope.treeRoots"

    private var roots: [DirectoryNode] = []

    var isRecursive: Bool { recursiveButton.state == .on }

    // MARK: - 初始化

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupOutline()
        setupFooter()
        setupLayout()
        roots = defaultRoots() + savedRoots()
        outlineView.reloadData()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setupOutline() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("PhotoScope.DirectoryColumn"))
        column.width = 220
        column.minWidth = 120
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.rowHeight = 24
        outlineView.indentationPerLevel = 14
        outlineView.allowsMultipleSelection = false
        outlineView.autoresizesOutlineColumn = false
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.translatesAutoresizingMaskIntoConstraints = false

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .windowBackgroundColor
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.postsFrameChangedNotifications = true
    }

    private func setupFooter() {
        addButton.bezelStyle = .rounded
        addButton.font = NSFont.systemFont(ofSize: 11)
        addButton.target = self
        addButton.action = #selector(addDirectory(_:))
        addButton.translatesAutoresizingMaskIntoConstraints = false

        recursiveButton.font = NSFont.systemFont(ofSize: 11)
        recursiveButton.state = .off
        recursiveButton.target = self
        recursiveButton.action = #selector(recursiveToggled(_:))
        recursiveButton.translatesAutoresizingMaskIntoConstraints = false
    }

    private func setupLayout() {
        addSubview(scrollView)
        addSubview(addButton)
        addSubview(recursiveButton)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: addButton.topAnchor, constant: -8),

            addButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            addButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
            recursiveButton.leadingAnchor.constraint(equalTo: addButton.trailingAnchor, constant: 10),
            recursiveButton.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),
            recursiveButton.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8)
        ])
    }

    // MARK: - 根节点

    private func defaultRoots() -> [DirectoryNode] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let candidates: [(URL, String)] = [
            (home, "个人目录"),
            (home.appendingPathComponent("Pictures"), "图片"),
            (home.appendingPathComponent("Desktop"), "桌面"),
            (home.appendingPathComponent("Downloads"), "下载"),
            (home.appendingPathComponent("Documents"), "文稿"),
            (URL(fileURLWithPath: "/Volumes"), "宗卷")
        ]
        return candidates.compactMap { url, name in
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return nil }
            return DirectoryNode(url: url, displayName: name)
        }
    }

    private func savedRoots() -> [DirectoryNode] {
        let paths = UserDefaults.standard.stringArray(forKey: rootsKey) ?? []
        var seen = Set<String>()
        return paths.compactMap { path in
            var isDirectory: ObjCBool = false
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return nil }
            let normalized = url.standardizedFileURL.path
            guard seen.insert(normalized).inserted else { return nil }
            return DirectoryNode(url: url)
        }
    }

    private func persistRoots() {
        // 只持久化用户添加的目录，不含内置的快捷位置
        let builtIn = Set(defaultRoots().map { $0.url.standardizedFileURL.path })
        let custom = roots.map { $0.url.path }.filter { !builtIn.contains(URL(fileURLWithPath: $0).standardizedFileURL.path) }
        UserDefaults.standard.set(Array(custom.suffix(20)), forKey: rootsKey)
    }

    /// 添加并选中一个目录（工具栏「打开文件夹」与 --dir 启动参数共用此入口）。
    func addRoot(url: URL, select: Bool) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return }

        let target = url.standardizedFileURL
        if !roots.contains(where: { $0.url.standardizedFileURL == target }) {
            roots.append(DirectoryNode(url: url))
            persistRoots()
        }
        outlineView.reloadData()

        if select {
            // 先清掉上一行的选中态，避免 reloadData 后残留的旧目录触发一次多余的刷新
            outlineView.deselectAll(nil)
            if let node = roots.first(where: { $0.url.standardizedFileURL == target }) {
                let row = outlineView.row(forItem: node)
                if row >= 0 {
                    outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    outlineView.scrollRowToVisible(row)
                }
            }
            delegate?.directoryTree(self, didSelectDirectory: url)
        }
    }

    // MARK: - 操作

    @objc private func addDirectory(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "添加"
        panel.message = "选择要浏览的照片目录"
        guard let window = window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.addRoot(url: url, select: true)
        }
    }

    @objc private func recursiveToggled(_ sender: Any?) {
        delegate?.directoryTree(self, didChangeRecursive: isRecursive)
    }

    func dumpLayout() {
        NSLog("PhotoScope sidebar: tree=%@ scroll=%@ outline=%@ add=%@ checkbox=%@ addHidden=%@ checkHidden=%@",
              NSStringFromRect(frame), NSStringFromRect(scrollView.frame),
              NSStringFromRect(outlineView.frame), NSStringFromRect(addButton.frame),
              NSStringFromRect(recursiveButton.frame),
              addButton.isHidden ? "yes" : "no", recursiveButton.isHidden ? "yes" : "no")
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return roots.count }
        return (item as? DirectoryNode)?.children.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            return roots.indices.contains(index) ? roots[index] : roots[0]
        }
        guard let node = item as? DirectoryNode, node.children.indices.contains(index) else {
            return DirectoryNode(url: URL(fileURLWithPath: "/"))
        }
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? DirectoryNode)?.hasChildren ?? false
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? DirectoryNode else { return nil }
        let cell = (outlineView.makeView(withIdentifier: cellIdentifier, owner: self) as? DirectoryCellView)
            ?? DirectoryCellView()
        cell.identifier = cellIdentifier
        cell.configure(name: node.name)
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let row = outlineView.selectedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? DirectoryNode else { return }
        delegate?.directoryTree(self, didSelectDirectory: node.url)
    }
}

/// 目录单元格：文件夹图标 + 名称。
private final class DirectoryCellView: NSTableCellView {

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyDown
        icon.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            ?? NSImage(named: NSImage.folderName)
        icon.contentTintColor = .controlAccentColor
        addSubview(icon)
        imageView = icon

        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.font = NSFont.systemFont(ofSize: 12)
        addSubview(label)
        textField = label

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(name: String) {
        textField?.stringValue = name
        textField?.toolTip = name
    }
}
