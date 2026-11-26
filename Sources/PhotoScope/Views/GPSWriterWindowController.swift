import AppKit

/// 轨迹文件处理页面：选轨迹 → 核对时间口径 → 选处理范围 → 提交写入 GPS。
///
/// 这是 PhotoScope 唯一会修改原始照片的功能，因此默认开启备份并在提交前二次确认。
final class GPSWriterWindowController: NSWindowController {

    // MARK: - 数据

    private var directory: URL?
    private var items: [MediaItem] = []
    private var selectedIndexes: [Int] = []

    private var trackURL: URL?
    private var trackData: Data?
    private var trackFormat: TrackFormat = .unknown
    private var trackPoints: [TrackPoint] = []
    private var trackInfo: TrackInfo?
    /// FIT 的时间戳是二进制 UTC，小米伪 Z 修正不适用；选中 FIT 时禁用该复选框。
    private var isFITTrack = false

    private let cancelFlag = CancelFlag()
    private var isBusy = false
    /// 处理结束后通知主窗口刷新 EXIF（地图按钮可能 newly 可用）。
    var onDidFinish: (() -> Void)?
    /// 自动化诊断：跳过确认弹窗，直接提交。
    var autoRun = false
    private var diagnosticsApplied = false
    var diagnosticTrackPath: String?
    var diagnosticXiaomi = false
    var diagnosticScope: GPSWriteScope = .selected
    var diagnosticDryRun = false

    // MARK: - 控件

    private let chooseButton = NSButton(title: "选择轨迹文件…", target: nil, action: nil)
    private let trackPathLabel = NSTextField(labelWithString: "未选择轨迹文件")
    private let previewTextView = NSTextView()
    private let xiaomiCheckbox = NSButton(checkboxWithTitle: "小米轨迹时间修正（原时间是国内时间 +Z → 减 8 小时改为格林威治时间 +Z）",
                                          target: nil, action: nil)
    private let xiaomiHint = NSTextField(labelWithString: "")
    private let scopeSelectedRadio = NSButton(radioButtonWithTitle: "仅处理选中的照片", target: nil, action: nil)
    private let scopeAllRadio = NSButton(radioButtonWithTitle: "处理当前目录的全部照片", target: nil, action: nil)
    private let toleranceField = NSTextField(string: "30")
    private let timezoneField = NSTextField(string: "8")
    private let overwriteCheckbox = NSButton(checkboxWithTitle: "覆盖已有 GPS 信息（默认跳过已有 GPS 的文件）",
                                             target: nil, action: nil)
    private let backupCheckbox = NSButton(checkboxWithTitle: "写入前备份原文件到同目录 exif_backup/（推荐）",
                                          target: nil, action: nil)
    private let videoCheckbox = NSButton(checkboxWithTitle: "同时处理视频文件（写入 Keys:GPSCoordinates）",
                                         target: nil, action: nil)
    private let dryRunCheckbox = NSButton(checkboxWithTitle: "仅预览匹配结果（不改动任何文件）",
                                          target: nil, action: nil)
    private let runButton = NSButton(title: "提交处理", target: nil, action: nil)
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)
    private let closeButton = NSButton(title: "关闭", target: nil, action: nil)
    private let progressIndicator = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "就绪：请选择轨迹文件")
    private let logTextView = NSTextView()

    // MARK: - 初始化

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 880),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "轨迹匹配写入 GPS"
        window.minSize = NSSize(width: 800, height: 850)
        window.center()
        window.setFrameAutosaveName("PhotoScope.GPSWriter")
        super.init(window: window)
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - 上下文

    func updateContext(directory: URL?, items: [MediaItem], selectedIndexes: [Int]) {
        self.directory = directory
        self.items = items
        self.selectedIndexes = selectedIndexes.filter { items.indices.contains($0) }
        refreshScopeTitles()
    }

    func toggle() {
        if window?.isVisible == true {
            window?.makeKeyAndOrderFront(nil)
        } else {
            showWindow(nil)
            window?.makeKeyAndOrderFront(nil)
        }
        applyDiagnosticsIfNeeded()
    }

    // MARK: - UI 构建

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let title = NSTextField(labelWithString: "按拍摄时间把轨迹点的 GPS 写入照片（原地写入，可自动备份）")
        title.font = NSFont.boldSystemFont(ofSize: 14)

        let trackTitle = sectionTitle("① 轨迹文件")
        chooseButton.target = self
        chooseButton.action = #selector(chooseTrack(_:))
        chooseButton.bezelStyle = .rounded
        trackPathLabel.lineBreakMode = .byTruncatingMiddle
        trackPathLabel.textColor = .secondaryLabelColor
        trackPathLabel.font = NSFont.systemFont(ofSize: 11)

        let previewTitle = sectionTitle("② 轨迹时间预览（前 3 条，用于核对时间口径）")
        configureTextView(previewTextView, fontSize: 11)
        let previewScroll = scrollView(with: previewTextView)

        xiaomiCheckbox.target = self
        xiaomiCheckbox.action = #selector(xiaomiToggled(_:))
        xiaomiHint.font = NSFont.systemFont(ofSize: 10)
        xiaomiHint.textColor = .secondaryLabelColor
        xiaomiHint.lineBreakMode = .byWordWrapping
        xiaomiHint.stringValue = "勾选后仅对 GPX / TCX 里 Z / 无时区后缀的时间减 8 小时；带 +08:00 之类数字偏移的时间按偏移真换算，不受影响。FIT 时间戳是二进制 UTC，此选项自动忽略。"

        let scopeTitle = sectionTitle("③ 处理范围")
        scopeSelectedRadio.target = self
        scopeAllRadio.target = self
        scopeSelectedRadio.action = #selector(scopeChanged(_:))
        scopeAllRadio.action = #selector(scopeChanged(_:))
        scopeSelectedRadio.state = .on

        let optionTitle = sectionTitle("④ 匹配与写入选项")
        let paramRow = horizontal([
            labeledField("匹配容差（秒）", toleranceField, width: 56),
            labeledField("照片时区 UTC+", timezoneField, width: 44),
            hint("小时"), NSView()
        ], spacing: 12)
        let paramHint = hint("照片与最近轨迹点的时间差超过容差就不写入；没有匹配上绝不写入 GPS。")

        for box in [overwriteCheckbox, backupCheckbox, videoCheckbox, dryRunCheckbox] {
            box.font = NSFont.systemFont(ofSize: 11)
        }
        backupCheckbox.state = .on

        runButton.target = self
        runButton.action = #selector(startProcessing(_:))
        runButton.bezelStyle = .rounded
        runButton.keyEquivalent = "\r"
        cancelButton.target = self
        cancelButton.action = #selector(cancelProcessing(_:))
        cancelButton.bezelStyle = .rounded
        cancelButton.isEnabled = false
        closeButton.target = self
        closeButton.action = #selector(closeWindow(_:))
        closeButton.bezelStyle = .rounded
        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle

        let logTitle = sectionTitle("⑤ 处理日志（结束后会在当前目录生成带时间戳的 .log）")
        configureTextView(logTextView, fontSize: 11)
        let logScroll = scrollView(with: logTextView)

        var anchor = content.topAnchor
        func add(_ view: NSView, height: CGFloat?, spacing: CGFloat = 8) {
            content.addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
                view.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
                view.topAnchor.constraint(equalTo: anchor, constant: spacing)
            ])
            if let height { view.heightAnchor.constraint(equalToConstant: height).isActive = true }
            anchor = view.bottomAnchor
        }

        let trackRow = horizontal([chooseButton, trackPathLabel], spacing: 10)
        chooseButton.setContentHuggingPriority(.required, for: .horizontal)
        trackPathLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        chooseButton.widthAnchor.constraint(equalToConstant: 150).isActive = true

        add(title, height: 22, spacing: 14)
        add(trackTitle, height: 18, spacing: 12)
        add(trackRow, height: 26)
        add(previewTitle, height: 18, spacing: 14)
        add(previewScroll, height: 208)
        add(xiaomiCheckbox, height: 20, spacing: 12)
        add(xiaomiHint, height: 26, spacing: 2)
        add(scopeTitle, height: 18, spacing: 12)
        add(horizontal([scopeSelectedRadio, scopeAllRadio, NSView()], spacing: 18), height: 22)
        add(optionTitle, height: 18, spacing: 12)
        add(paramRow, height: 24)
        add(overwriteCheckbox, height: 18, spacing: 8)
        add(backupCheckbox, height: 18, spacing: 4)
        add(videoCheckbox, height: 18, spacing: 4)
        add(dryRunCheckbox, height: 18, spacing: 4)
        add(paramHint, height: 16, spacing: 4)

        let buttonRow = horizontal([
            runButton, cancelButton, closeButton, NSView(), progressIndicator
        ], spacing: 10)
        add(buttonRow, height: 28, spacing: 14)
        add(statusLabel, height: 18, spacing: 4)
        add(logTitle, height: 18, spacing: 12)

        content.addSubview(logScroll)
        logScroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            logScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            logScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            logScroll.topAnchor.constraint(equalTo: anchor, constant: 6),
            logScroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            logScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120)
        ])

        refreshScopeTitles()
        refreshPreview()
        refreshExifToolState()
    }

    private func sectionTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.boldSystemFont(ofSize: 12)
        return label
    }

    private func hint(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 10)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func labeledField(_ title: String, _ field: NSTextField, width: CGFloat) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 11)
        field.font = NSFont.systemFont(ofSize: 11)
        field.alignment = .center
        let stack = NSStackView(views: [label, field])
        stack.orientation = .horizontal
        stack.spacing = 5
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        return stack
    }

    private func horizontal(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = spacing
        stack.alignment = .centerY
        stack.distribution = .fill
        return stack
    }

    private func configureTextView(_ view: NSTextView, fontSize: CGFloat) {
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        view.textColor = .labelColor
        view.backgroundColor = .textBackgroundColor
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.textContainerInset = NSSize(width: 6, height: 6)
    }

    private func scrollView(with textView: NSTextView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.borderType = .bezelBorder
        textView.autoresizingMask = [.width]
        return scroll
    }

    // MARK: - 状态刷新

    private func refreshScopeTitles() {
        let selectedCount = selectedIndexes.isEmpty
            ? (items.indices.contains(0) ? 1 : 0)
            : selectedIndexes.count
        let photos = items.filter { !$0.isVideo }
        scopeSelectedRadio.title = "仅处理选中的 \(selectedCount) 张照片"
        scopeAllRadio.title = "处理当前目录的全部 \(photos.count) 张照片"
        statusLabel.stringValue = directory == nil
            ? "请先在左侧目录树选择照片目录"
            : "当前目录：\(directory!.lastPathComponent)（共 \(items.count) 个媒体文件）"
    }

    private func refreshExifToolState() {
        if let version = ExifTool.version() {
            statusLabel.stringValue = (directory == nil ? "请选择照片目录" : "目录：\(directory!.lastPathComponent)")
                + "   ·   exiftool \(version) 已就绪"
        } else {
            statusLabel.stringValue = "⚠ 未找到 exiftool，无法写入 GPS（请安装 https://exiftool.org/）"
        }
    }

    /// 选完轨迹或切换小米修正后，重算预览与信息。
    private func refreshPreview() {
        guard let data = trackData, let url = trackURL else {
            previewTextView.string = "未选择轨迹文件。\n支持 GPX / TCX / FIT；格式由文件内容自动识别。"
            trackPoints = []
            trackInfo = nil
            return
        }
        let corrected = xiaomiCheckbox.state == .on && !isFITTrack
        let points = GPSTrack.parse(data: data, format: trackFormat, xiaomiCorrection: corrected)
        let info = GPSTrack.info(for: points, url: url, format: trackFormat)
        trackPoints = GPSTrack.sortedByTime(points)
        trackInfo = info

        let timeRule = isFITTrack
            ? "FIT 二进制 UTC 时间戳（FIT epoch 1989-12-31，小米修正不适用）"
            : (corrected ? "小米修正（Z 时间 −8h）" : "原样（Z 视为真 UTC）")
        var text = "轨迹：\(url.lastPathComponent)  格式：\(info.format.rawValue.uppercased())\n"
        text += "共 \(info.total) 点（含时间 \(info.withTime)、含海拔 \(info.withAltitude)）"
            + "  时间口径：\(timeRule)\n"
        if let min = info.minTime, let max = info.maxTime {
            text += "范围 UTC：\(GPSTrack.utcString(min)) ~ \(GPSTrack.utcString(max))\n"
            text += "      北京：\(GPSTrack.beijingString(min)) ~ \(GPSTrack.beijingString(max))\n"
        }
        text += "──────────────────────────────────────────────────\n"
        for (index, point) in info.samples.enumerated() {
            if let time = point.time {
                let original = point.timeIsBinary
                    ? "FIT 时间戳 \(point.rawTime ?? "（无）")"
                    : "原始 \(point.rawTime ?? "（无）")"
                text += "\(index + 1). \(original)"
                    + "  →  UTC \(GPSTrack.utcString(time)) / 北京 \(GPSTrack.beijingString(time))"
                    + (corrected ? "  [−8h]" : "") + "\n"
            } else {
                text += "\(index + 1). 原始 \(point.rawTime ?? "（无）")   ⚠ 时间无法解析\n"
            }
            text += String(format: "   %.6f, %.6f", point.latitude, point.longitude)
            if let alt = point.altitude { text += String(format: "   海拔 %.1fm", alt) }
            text += "\n"
        }
        if info.samples.isEmpty { text += "（没有解析到轨迹点）\n" }
        text += isFITTrack
            ? "提示：FIT 时间戳按规范为 UTC 秒；若与照片拍摄时间差约 8 小时，请检查导出轨迹的设备时钟。"
            : "提示：若照片拍摄时间约为 09:xx，而上面「北京时间」显示 17:xx，请勾选小米修正。"
        previewTextView.string = text
        previewTextView.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }

    // MARK: - 动作

    @objc private func chooseTrack(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.message = "选择 GPX / TCX / FIT 轨迹文件；格式由程序自动识别"
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.loadTrack(url)
        }
    }

    func loadTrack(_ url: URL) {
        statusLabel.stringValue = "正在解析轨迹…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let format = GPSTrack.detectFormat(url)
            let data = try? Data(contentsOf: url)
            DispatchQueue.main.async {
                guard let self else { return }
                self.trackURL = url
                self.trackData = data
                self.trackFormat = format
                self.trackPathLabel.stringValue = url.path
                self.isFITTrack = (format == .fit)
                if self.isFITTrack {
                    self.xiaomiCheckbox.state = .off
                    self.xiaomiCheckbox.isEnabled = false
                } else {
                    self.xiaomiCheckbox.isEnabled = !self.isBusy
                }
                guard data != nil, format == .gpx || format == .tcx || format == .fit else {
                    self.statusLabel.stringValue = "无法识别的轨迹格式"
                    self.previewTextView.string = "无法识别的轨迹格式：\(url.lastPathComponent)\n仅支持 GPX / TCX / FIT。"
                    self.trackPoints = []
                    self.trackInfo = nil
                    return
                }
                if format == .fit, let bytes = data, !FITTrackParser.hasValidHeader(bytes) {
                    self.statusLabel.stringValue = "FIT 文件头无效"
                    self.previewTextView.string = "这个 .fit 文件缺少 .FIT 文件头或数据长度异常，无法解析。\n可先用设备厂商工具重新导出，或改用 GPX / TCX。"
                    self.trackPoints = []
                    self.trackInfo = nil
                    return
                }
                self.refreshPreview()
                let info = self.trackInfo
                guard let info, info.total > 0, info.withTime > 0 else {
                    self.statusLabel.stringValue = "轨迹解析失败：没有带时间戳的定位点"
                    self.trackPoints = []
                    self.trackInfo = nil
                    return
                }
                self.statusLabel.stringValue = "轨迹已加载：\(info.format.rawValue.uppercased()) · \(info.total) 点（含时间 \(info.withTime)）"
                self.appendLog("轨迹已加载：\(url.lastPathComponent)（\(info.format.rawValue.uppercased())，\(info.total) 点）")
                if let min = info.minTime, let max = info.maxTime {
                    self.appendLog("轨迹 UTC 范围：\(GPSTrack.utcString(min)) ~ \(GPSTrack.utcString(max))")
                    self.appendLog("对应北京时间：\(GPSTrack.beijingString(min)) ~ \(GPSTrack.beijingString(max))")
                }
            }
        }
    }

    @objc private func xiaomiToggled(_ sender: Any?) {
        guard !isFITTrack else { return }
        refreshPreview()
        appendLog(xiaomiCheckbox.state == .on
                  ? "小米时间修正已开启：Z / 无后缀时间统一减 8 小时"
                  : "小米时间修正已关闭：Z 时间按真 UTC 解释")
    }

    @objc private func scopeChanged(_ sender: Any?) {
        if let button = sender as? NSButton {
            if button === scopeSelectedRadio {
                scopeAllRadio.state = .off
            } else {
                scopeSelectedRadio.state = .off
            }
        }
        refreshScopeTitles()
    }

    @objc private func closeWindow(_ sender: Any?) {
        if isBusy {
            let alert = NSAlert()
            alert.messageText = "正在处理中"
            alert.informativeText = "请先点「取消」等待当前文件处理完毕。"
            alert.addButton(withTitle: "好")
            alert.beginSheetModal(for: window!) { _ in }
            return
        }
        close()
    }

    @objc private func cancelProcessing(_ sender: Any?) {
        cancelFlag.value = true
        statusLabel.stringValue = "正在取消…"
    }

    @objc private func startProcessing(_ sender: Any?) {
        submit(autoConfirm: false)
    }

    /// 自动化诊断入口：跳过确认弹窗。
    func runDiagnostics() {
        guard let path = diagnosticTrackPath else { return }
        let url = URL(fileURLWithPath: path)
        trackURL = url
        trackData = try? Data(contentsOf: url)
        trackFormat = GPSTrack.detectFormat(url)
        isFITTrack = (trackFormat == .fit)
        trackPathLabel.stringValue = path
        xiaomiCheckbox.state = (diagnosticXiaomi && !isFITTrack) ? .on : .off
        xiaomiCheckbox.isEnabled = !isFITTrack
        dryRunCheckbox.state = diagnosticDryRun ? .on : .off
        switch diagnosticScope {
        case .selected: scopeSelectedRadio.state = .on; scopeAllRadio.state = .off
        case .all: scopeSelectedRadio.state = .off; scopeAllRadio.state = .on
        }
        refreshScopeTitles()
        refreshPreview()
        if autoRun { submit(autoConfirm: true) }
    }

    private func applyDiagnosticsIfNeeded() {
        guard !diagnosticsApplied, diagnosticTrackPath != nil else { return }
        diagnosticsApplied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.runDiagnostics()
        }
    }

    // MARK: - 提交

    private func submit(autoConfirm: Bool) {
        guard !isBusy else { return }
        guard let directory else { showAlert("请先选择照片目录", "在左侧目录树选一个包含照片的目录。"); return }
        guard !trackPoints.isEmpty, trackInfo?.withTime ?? 0 > 0 else {
            showAlert("请先选择有效轨迹文件", "需要 GPX / TCX / FIT，且至少有一个点带时间戳。")
            return
        }
        guard ExifTool.isAvailable() else {
            showAlert("缺少 exiftool", "原地写入 RAW / HEIC / JPG 的 GPS 需要 exiftool。请安装 https://exiftool.org/ 后重试。")
            return
        }
        let tolerance = Double(toleranceField.stringValue.trimmingCharacters(in: .whitespaces)) ?? -1
        let tz = Double(timezoneField.stringValue.trimmingCharacters(in: .whitespaces))
        guard tolerance >= 0 else { showAlert("参数有误", "匹配容差必须是非负数字。"); return }
        guard let tz, tz >= -14, tz <= 14 else { showAlert("参数有误", "照片时区必须是 -14 ~ 14 的数字。"); return }

        let scope: GPSWriteScope = scopeAllRadio.state == .on ? .all : .selected
        let selectedItems = selectedIndexes.compactMap { items.indices.contains($0) ? items[$0] : nil }
        let fallback = items.indices.contains(0) ? [items[0]] : []
        let targets: [MediaItem] = scope == .all
            ? items
            : (selectedItems.isEmpty ? fallback : selectedItems)
        guard !targets.isEmpty else { showAlert("没有可处理的照片", "当前范围为空。"); return }

        let xiaomiCorrection = xiaomiCheckbox.state == .on && !isFITTrack
        var options = GPSWriteOptions()
        options.scope = scope
        options.tolerance = tolerance
        options.photoTimezoneHours = tz
        options.overwriteExistingGPS = overwriteCheckbox.state == .on
        options.backupBeforeWrite = backupCheckbox.state == .on
        options.includeVideo = videoCheckbox.state == .on
        options.xiaomiCorrection = xiaomiCorrection
        options.dryRun = dryRunCheckbox.state == .on

        let confirm = {
            self.beginProcessing(targets: targets, directory: directory, options: options)
        }
        if autoConfirm || options.dryRun {
            beginProcessing(targets: targets, directory: directory, options: options)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "即将修改 \(targets.count) 个原始照片文件"
        alert.informativeText = """
        目录：\(directory.path)
        轨迹：\(trackURL?.lastPathComponent ?? "—")（\(trackFormat.rawValue.uppercased())，\(xiaomiCorrection ? "小米修正开启" : isFITTrack ? "FIT 二进制 UTC" : "小米修正关闭")）
        容差 \(Int(options.tolerance)) 秒 · 照片时区 UTC+\(String(format: "%g", options.photoTimezoneHours))
        \(options.backupBeforeWrite ? "写入前会备份到各文件所在目录的 exif_backup/。" : "⚠ 未开启备份，写入不可自动回滚。")
        处理结束后会在该目录生成带时间戳的 .log 日志。
        """
        alert.addButton(withTitle: "开始处理")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window!) { response in
            if response == .alertFirstButtonReturn { confirm() }
        }
    }

    private func beginProcessing(targets: [MediaItem], directory: URL, options: GPSWriteOptions) {
        isBusy = true
        cancelFlag.value = false
        setBusy(true)
        logTextView.string = ""
        statusLabel.stringValue = "正在处理…"
        let points = trackPoints

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = GPSWriter.process(
                items: targets,
                directory: directory,
                points: points,
                options: options,
                log: { message in
                    DispatchQueue.main.async { self?.appendLog(message) }
                },
                cancelled: { self?.cancelFlag.value ?? false }
            )
            let logURL = GPSWriter.writeLog(
                result.lines.map { "[\(GPSTrack.string($0.0, offset: GPSTrack.beijingOffsetHours * 3600))] \($0.1)" },
                to: directory
            )
            DispatchQueue.main.async {
                guard let self else { return }
                self.isBusy = false
                self.setBusy(false)
                if let logURL {
                    self.appendLog("日志文件：\(logURL.path)")
                    self.statusLabel.stringValue = "完成 · \(result.stats.summary) · 日志 \(logURL.lastPathComponent)"
                } else {
                    self.appendLog("⚠ 日志文件写入失败")
                    self.statusLabel.stringValue = "完成 · \(result.stats.summary)"
                }
                self.onDidFinish?()
            }
        }
    }

    private func setBusy(_ busy: Bool) {
        runButton.isEnabled = !busy
        chooseButton.isEnabled = !busy
        cancelButton.isEnabled = busy
        closeButton.isEnabled = !busy
        xiaomiCheckbox.isEnabled = !busy && !isFITTrack
        if busy { progressIndicator.startAnimation(nil) } else { progressIndicator.stopAnimation(nil) }
    }

    // MARK: - 日志与提示

    private func appendLog(_ message: String) {
        guard let storage = logTextView.textStorage else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.labelColor
        ]
        storage.append(NSAttributedString(string: message + "\n", attributes: attributes))
        logTextView.scrollToEndOfDocument(nil)
    }

    private func showAlert(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "好")
        guard let window else { return }
        alert.beginSheetModal(for: window) { _ in }
    }
}

/// 后台线程与主线程共享的取消标志。
private final class CancelFlag {
    private let lock = NSLock()
    private var cancelled = false

    var value: Bool {
        get {
            lock.lock(); defer { lock.unlock() }
            return cancelled
        }
        set {
            lock.lock(); cancelled = newValue; lock.unlock()
        }
    }
}
