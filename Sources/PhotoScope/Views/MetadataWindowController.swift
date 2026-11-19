import AppKit

/// EXIF 信息浮窗：切换照片时自动刷新，可整体复制。
final class MetadataWindowController: NSWindowController, NSWindowDelegate {

    weak var mainController: MainWindowController?

    private let scrollView = NSScrollView()
    private let textView = NSTextView()
    private let copyButton = NSButton(title: "复制全部信息", target: nil, action: nil)
    private let stateLabel = NSTextField(labelWithString: "")

    private var plainText = ""

    convenience init() {
        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 470, height: 620),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "照片信息 (EXIF)"
        panel.minSize = NSSize(width: 360, height: 320)
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.setFrameAutosaveName("PhotoScope.MetadataPanel")
        self.init(window: panel)
        panel.delegate = self
        setupViews()
    }

    private func setupViews() {
        guard let content = window?.contentView else { return }

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.autoresizingMask = [.width, .height]

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        copyButton.bezelStyle = .rounded
        copyButton.font = NSFont.systemFont(ofSize: 11)
        copyButton.target = self
        copyButton.action = #selector(copyAll(_:))
        copyButton.translatesAutoresizingMaskIntoConstraints = false

        stateLabel.font = NSFont.systemFont(ofSize: 11)
        stateLabel.textColor = .secondaryLabelColor
        stateLabel.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(scrollView)
        content.addSubview(copyButton)
        content.addSubview(stateLabel)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: content.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: copyButton.topAnchor, constant: -10),

            copyButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            copyButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),

            stateLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            stateLabel.centerYAnchor.constraint(equalTo: copyButton.centerYAnchor),
            stateLabel.trailingAnchor.constraint(lessThanOrEqualTo: copyButton.leadingAnchor, constant: -10)
        ])
    }

    func update(with metadata: PhotoMetadata?, fileName: String?) {
        guard let metadata = metadata, !metadata.sections.isEmpty else {
            renderEmpty(fileName: fileName)
            return
        }

        let attributed = NSMutableAttributedString()
        var plain = ""

        if let fileName = fileName {
            let header = "📷 \(fileName)\n\n"
            attributed.append(NSAttributedString(string: header, attributes: [
                .font: NSFont.boldSystemFont(ofSize: 13),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: headerParagraph()
            ]))
            plain += header
        }

        let rowParagraph = tabParagraph()
        for section in metadata.sections {
            let title = "▍\(section.title)\n"
            attributed.append(NSAttributedString(string: title, attributes: [
                .font: NSFont.boldSystemFont(ofSize: 12),
                .foregroundColor: NSColor.controlAccentColor,
                .paragraphStyle: headerParagraph()
            ]))
            plain += title

            for row in section.rows {
                let key = NSAttributedString(string: row.key + "\t", attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: rowParagraph
                ])
                let value = NSAttributedString(string: row.value + "\n", attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: rowParagraph
                ])
                attributed.append(key)
                attributed.append(value)
                plain += "\(row.key)\t\(row.value)\n"
            }
            attributed.append(NSAttributedString(string: "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 8),
                .paragraphStyle: headerParagraph()
            ]))
            plain += "\n"
        }

        if let gps = metadata.gps {
            let gpsText = String(format: "📍 定位：%.6f°, %.6f°  (%@)\n", gps.latitude, gps.longitude, gps.source)
            attributed.append(NSAttributedString(string: gpsText, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: headerParagraph()
            ]))
            plain += gpsText
        }

        plainText = plain
        textView.textStorage?.setAttributedString(attributed)
        textView.scrollToBeginningOfDocument(nil)
        stateLabel.stringValue = metadata.gps == nil ? "无 GPS 坐标" : "含 GPS 坐标"
    }

    private func renderEmpty(fileName: String?) {
        let text = fileName.map { "「\($0)」\n\n暂无可读取的元数据。" } ?? "未选择照片。"
        plainText = text
        textView.string = text
        stateLabel.stringValue = ""
    }

    private func headerParagraph() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        style.paragraphSpacing = 2
        return style
    }

    private func tabParagraph() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .left, location: 165, options: [:])]
        style.headIndent = 165
        style.lineBreakMode = .byCharWrapping
        return style
    }

    func toggle() {
        if window?.isVisible == true {
            close()
        } else {
            showWindow(nil)
            window?.orderFrontRegardless()
        }
    }

    @objc private func copyAll(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(plainText, forType: .string)
        stateLabel.stringValue = "已复制到剪贴板"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self = self else { return }
            if self.stateLabel.stringValue == "已复制到剪贴板" {
                self.stateLabel.stringValue = ""
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        mainController?.infoPanelDidClose()
    }
}
