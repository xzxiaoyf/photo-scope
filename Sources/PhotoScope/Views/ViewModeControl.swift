import AppKit

/// 工具栏右上角的三段视图切换控件。
///
/// 图标按参考界面自绘：3×3 方格 = 全部照片列表；上大方块 + 下小方块 = 单张大图；
/// 左右双竖条 = 并排两张。当前段用橙红色填充，其余段跟随系统标签色，
/// 因此浅色 / 深色外观下都能看清。
final class ViewModeControl: NSView {

    static let segmentCount = 3
    static let accent = NSColor(calibratedRed: 1.0, green: 0.34, blue: 0.16, alpha: 1.0)

    /// 三段固定顺序，供菜单、诊断与自检共用。
    static let modes: [ViewMode] = [.grid, .single, .compare]

    static func mode(at index: Int) -> ViewMode? {
        modes.indices.contains(index) ? modes[index] : nil
    }

    var onChange: ((ViewMode) -> Void)?

    private(set) var selected: ViewMode {
        didSet { updateSegments() }
    }

    private var buttons: [NSButton] = []

    init(selected: ViewMode = .single) {
        self.selected = selected
        super.init(frame: NSRect(x: 0, y: 0, width: 104, height: 30))
        setupViews()
        updateSegments()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setupViews() {
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor

        let segmentWidth: CGFloat = 32
        for (index, mode) in Self.modes.enumerated() {
            let button = NSButton(frame: NSRect(x: 2 + CGFloat(index) * segmentWidth,
                                                y: 2,
                                                width: segmentWidth - 2,
                                                height: 26))
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            button.tag = index
            button.target = self
            button.action = #selector(segmentClicked(_:))
            button.toolTip = "\(mode.title)（⌘\(mode.shortcut)）"
            button.wantsLayer = true
            button.layer?.cornerRadius = 4
            addSubview(button)
            buttons.append(button)
        }
    }

    func setSelected(_ mode: ViewMode, notify: Bool = false) {
        selected = mode
        if notify { onChange?(mode) }
    }

    private func updateSegments() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        for (index, button) in buttons.enumerated() {
            guard let mode = Self.mode(at: index) else { continue }
            let isOn = mode == selected
            button.image = Self.icon(for: mode, highlighted: isOn)
            button.contentTintColor = isOn ? Self.accent : .secondaryLabelColor
            button.layer?.backgroundColor = isOn
                ? Self.accent.withAlphaComponent(0.16).cgColor
                : NSColor.clear.cgColor
        }
    }

    @objc private func segmentClicked(_ sender: NSButton) {
        guard let mode = Self.mode(at: sender.tag) else { return }
        selected = mode
        onChange?(mode)
    }

    // MARK: - 图标绘制（纯函数，自检可核验尺寸与非空）

    static func icon(for mode: ViewMode, highlighted: Bool) -> NSImage {
        let size = NSSize(width: 26, height: 20)
        let color = highlighted ? accent : NSColor.secondaryLabelColor
        let image = NSImage(size: size, flipped: false) { _ in
            color.setFill()
            switch mode {
            case .grid:
                for row in 0..<3 {
                    for column in 0..<3 {
                        let rect = NSRect(x: 3.5 + CGFloat(column) * 7,
                                          y: 2 + CGFloat(row) * 5.5,
                                          width: 5, height: 4)
                        NSBezierPath(roundedRect: rect, xRadius: 0.7, yRadius: 0.7).fill()
                    }
                }
            case .single:
                NSBezierPath(roundedRect: NSRect(x: 3, y: 7, width: 20, height: 11),
                             xRadius: 1, yRadius: 1).fill()
                NSBezierPath(roundedRect: NSRect(x: 3, y: 2, width: 9, height: 3),
                             xRadius: 0.7, yRadius: 0.7).fill()
                NSBezierPath(roundedRect: NSRect(x: 14, y: 2, width: 9, height: 3),
                             xRadius: 0.7, yRadius: 0.7).fill()
            case .compare:
                NSBezierPath(roundedRect: NSRect(x: 3, y: 2, width: 9, height: 16),
                             xRadius: 1, yRadius: 1).fill()
                NSBezierPath(roundedRect: NSRect(x: 14, y: 2, width: 9, height: 16),
                             xRadius: 1, yRadius: 1).fill()
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}
