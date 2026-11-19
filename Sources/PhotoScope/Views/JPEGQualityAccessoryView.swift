import AppKit

/// JPG 导出质量控件：同时用于「另存为 JPG」保存面板的 accessoryView
/// 与「文件 → JPG 导出质量…」设置对话框。
final class JPEGQualityAccessoryView: NSView {

    private let titleLabel = NSTextField(labelWithString: "JPEG 质量：")
    private let slider = NSSlider()
    private let valueLabel = NSTextField(labelWithString: "90%")
    private let resetButton = NSButton(title: "默认", target: nil, action: nil)
    private let caption = NSTextField(labelWithString: "")

    /// 滑杆变化时回调，便于调用方实时更新提示文字。
    var onQualityChanged: ((Double) -> Void)?

    var quality: Double {
        get { Double(slider.intValue) / 100.0 }
        set {
            slider.intValue = Int32(JPEGExporter.percent(newValue))
            syncLabel()
        }
    }

    convenience init(quality: Double) {
        self.init(frame: NSRect(x: 0, y: 0, width: 440, height: 68))
        setupViews()
        self.quality = quality
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setupViews() {
        // accessoryView 由 NSSavePanel / NSAlert 按 frame 尺寸排版，因此使用手动布局
        titleLabel.font = NSFont.systemFont(ofSize: 11)
        titleLabel.textColor = .labelColor
        titleLabel.frame = NSRect(x: 2, y: 42, width: 78, height: 17)
        titleLabel.autoresizingMask = [.maxYMargin]
        addSubview(titleLabel)

        slider.frame = NSRect(x: 82, y: 40, width: 252, height: 22)
        slider.minValue = 10
        slider.maxValue = 100
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderChanged(_:))
        slider.autoresizingMask = [.width, .maxYMargin]
        addSubview(slider)

        valueLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        valueLabel.textColor = .labelColor
        valueLabel.alignment = .right
        valueLabel.frame = NSRect(x: 340, y: 42, width: 44, height: 17)
        valueLabel.autoresizingMask = [.minXMargin, .maxYMargin]
        addSubview(valueLabel)

        resetButton.bezelStyle = .rounded
        resetButton.font = NSFont.systemFont(ofSize: 10)
        resetButton.toolTip = "恢复为默认 90%"
        resetButton.target = self
        resetButton.action = #selector(resetTapped(_:))
        resetButton.frame = NSRect(x: 388, y: 38, width: 50, height: 24)
        resetButton.autoresizingMask = [.minXMargin, .maxYMargin]
        addSubview(resetButton)

        caption.font = NSFont.systemFont(ofSize: 10)
        caption.textColor = .secondaryLabelColor
        caption.stringValue = "数值越大画质越好、文件也越大；本次选择会记住，作为下次导出的默认值。"
        caption.lineBreakMode = .byWordWrapping
        caption.frame = NSRect(x: 2, y: 6, width: 436, height: 28)
        caption.autoresizingMask = [.width, .maxYMargin]
        addSubview(caption)
    }

    /// 自动化诊断：把控件自身渲染为 PNG（不依赖屏幕录制权限）。
    @discardableResult
    func renderToPNG(_ url: URL) -> Bool {
        layoutSubtreeIfNeeded()
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return false }
        cacheDisplay(in: bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try data.write(to: url)
            return true
        } catch {
            return false
        }
    }

    @objc private func sliderChanged(_ sender: Any?) {
        syncLabel()
        onQualityChanged?(quality)
    }

    @objc private func resetTapped(_ sender: Any?) {
        quality = JPEGExporter.defaultQuality
        onQualityChanged?(quality)
    }

    private func syncLabel() {
        valueLabel.stringValue = "\(JPEGExporter.percent(quality))%"
    }
}
