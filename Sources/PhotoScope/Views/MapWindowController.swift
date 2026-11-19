import AppKit
import WebKit

/// 拍摄位置窗口。
///
/// 合规说明：底图使用高德地图 JS API 2.0（合规白名单内），不使用 Apple Maps / Google Maps /
/// OpenStreetMap 等境外底图。EXIF 的 WGS-84 坐标会先转换为 GCJ-02 再标注。
/// 独立分发的 macOS 应用无法使用密钥代理，因此「Web端 (JS API)」Key 与安全密钥由使用者
/// 自行在高德开放平台申请后填入窗口顶部（仅保存在本机 UserDefaults，不会写进源码）。
final class MapWindowController: NSWindowController {

    static let keyDefaultsKey = "PhotoScope.amapKey"
    static let secretDefaultsKey = "PhotoScope.amapSecurityCode"

    private let webView = WKWebView()
    private let keyField = NSTextField()
    private let secretField = NSTextField()
    private let applyButton = NSButton(title: "应用", target: nil, action: nil)
    private let keyLabel = NSTextField(labelWithString: "高德 Key：")
    private let secretLabel = NSTextField(labelWithString: "安全密钥：")
    private let infoLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")

    private var currentLocation: GPSLocation?
    private var currentFileName = ""

    convenience init() {
        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "拍摄位置 — 高德地图"
        panel.minSize = NSSize(width: 560, height: 460)
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.setFrameAutosaveName("PhotoScope.MapPanel")
        self.init(window: panel)
        setupViews()
    }

    private func setupViews() {
        guard let content = window?.contentView else { return }

        let topBar = NSView()
        topBar.translatesAutoresizingMaskIntoConstraints = false
        topBar.wantsLayer = true
        topBar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        keyLabel.font = NSFont.systemFont(ofSize: 11)
        keyLabel.textColor = .secondaryLabelColor
        keyLabel.translatesAutoresizingMaskIntoConstraints = false
        secretLabel.font = NSFont.systemFont(ofSize: 11)
        secretLabel.textColor = .secondaryLabelColor
        secretLabel.translatesAutoresizingMaskIntoConstraints = false

        keyField.font = NSFont.systemFont(ofSize: 11)
        keyField.placeholderString = "请填入高德「Web端 (JS API)」Key"
        keyField.stringValue = savedKey()
        keyField.translatesAutoresizingMaskIntoConstraints = false
        keyField.lineBreakMode = .byTruncatingHead
        keyField.target = self
        keyField.action = #selector(applyKey(_:))

        secretField.font = NSFont.systemFont(ofSize: 11)
        secretField.placeholderString = "jscode（2021-12-02 后申请的 Key 必填，老 Key 可留空）"
        secretField.stringValue = savedSecret()
        secretField.translatesAutoresizingMaskIntoConstraints = false
        secretField.lineBreakMode = .byTruncatingHead
        secretField.target = self
        secretField.action = #selector(applyKey(_:))

        applyButton.bezelStyle = .rounded
        applyButton.font = NSFont.systemFont(ofSize: 11)
        applyButton.target = self
        applyButton.action = #selector(applyKey(_:))
        applyButton.translatesAutoresizingMaskIntoConstraints = false
        applyButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 56).isActive = true

        topBar.addSubview(keyLabel)
        topBar.addSubview(keyField)
        topBar.addSubview(secretLabel)
        topBar.addSubview(secretField)
        topBar.addSubview(applyButton)

        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.allowsBackForwardNavigationGestures = false
        webView.uiDelegate = self

        infoLabel.font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
        infoLabel.textColor = .labelColor
        infoLabel.lineBreakMode = .byTruncatingMiddle
        infoLabel.translatesAutoresizingMaskIntoConstraints = false

        hintLabel.font = NSFont.systemFont(ofSize: 10)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.lineBreakMode = .byTruncatingTail
        hintLabel.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(topBar)
        content.addSubview(webView)
        content.addSubview(infoLabel)
        content.addSubview(hintLabel)

        NSLayoutConstraint.activate([
            topBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            topBar.topAnchor.constraint(equalTo: content.topAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 68),

            keyLabel.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 12),
            keyLabel.topAnchor.constraint(equalTo: topBar.topAnchor, constant: 12),
            keyLabel.widthAnchor.constraint(equalToConstant: 76),
            keyField.leadingAnchor.constraint(equalTo: keyLabel.trailingAnchor, constant: 6),
            keyField.centerYAnchor.constraint(equalTo: keyLabel.centerYAnchor),
            keyField.trailingAnchor.constraint(equalTo: applyButton.leadingAnchor, constant: -8),
            applyButton.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -12),
            applyButton.centerYAnchor.constraint(equalTo: keyLabel.centerYAnchor),

            secretLabel.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 12),
            secretLabel.topAnchor.constraint(equalTo: keyLabel.bottomAnchor, constant: 12),
            secretLabel.widthAnchor.constraint(equalToConstant: 76),
            secretField.leadingAnchor.constraint(equalTo: secretLabel.trailingAnchor, constant: 6),
            secretField.centerYAnchor.constraint(equalTo: secretLabel.centerYAnchor),
            secretField.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -12),

            webView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            webView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            webView.bottomAnchor.constraint(equalTo: infoLabel.topAnchor, constant: -6),

            infoLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            infoLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            infoLabel.bottomAnchor.constraint(equalTo: hintLabel.topAnchor, constant: -2),

            hintLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            hintLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            hintLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8)
        ])
    }

    // MARK: - 展示

    func show(location: GPSLocation, fileName: String) {
        currentLocation = location
        currentFileName = fileName
        window?.title = "拍摄位置 — \(fileName)"

        let converted = CoordinateConverter.wgs84ToGCJ02(latitude: location.latitude,
                                                          longitude: location.longitude)
        var text = String(format: "WGS-84 %.6f°, %.6f°   →   GCJ-02 %.6f°, %.6f°   来源：%@",
                          location.latitude, location.longitude,
                          converted.latitude, converted.longitude, location.source)
        if let altitude = location.altitude {
            text += String(format: "   海拔 %.1f m", altitude)
        }
        infoLabel.stringValue = text
        hintLabel.stringValue = configuredKey == nil
            ? "底图：高德地图 JS API 2.0（GCJ-02）· 尚未配置 Key，填入后点「应用」即可启用"
            : "底图：高德地图 JS API 2.0（GCJ-02）· 域名白名单请放行 photoscope.local 或留空 · 密钥仅存本机"

        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        // WKWebView 在窗口可见之前发起的导航可能落空，显示后再加载
        DispatchQueue.main.async { [weak self] in
            self?.reloadMap()
        }
    }

    func debugDumpHTML() {
        let script = """
        JSON.stringify({
          href: document.location.href,
          state: document.readyState,
          len: document.documentElement.outerHTML.length,
          amap: typeof AMap,
          sdk: (document.querySelector('script[src*="webapi.amap.com"]') || {}).src || 'none',
          text: (document.body ? document.body.innerText : 'NO BODY').slice(0, 400)
        })
        """
        webView.evaluateJavaScript(script) { result, error in
            if let text = result as? String {
                NSLog("PhotoScope map DOM: %@", text)
            } else {
                NSLog("PhotoScope map DOM result: %@ | error: %@",
                      String(describing: result), String(describing: error))
            }
        }
    }

    @objc private func applyKey(_ sender: Any?) {
        UserDefaults.standard.set(keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                                  forKey: Self.keyDefaultsKey)
        UserDefaults.standard.set(secretField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                                  forKey: Self.secretDefaultsKey)
        hintLabel.stringValue = configuredKey == nil
            ? "底图：高德地图 JS API 2.0（GCJ-02）· 尚未配置有效 Key"
            : "底图：高德地图 JS API 2.0（GCJ-02）· 已应用，若加载失败请检查 Key 类型与安全密钥"
        reloadMap()
    }

    private func savedKey() -> String {
        UserDefaults.standard.string(forKey: Self.keyDefaultsKey) ?? ""
    }

    private func savedSecret() -> String {
        UserDefaults.standard.string(forKey: Self.secretDefaultsKey) ?? ""
    }

    private var configuredKey: String? {
        let key = savedKey()
        guard AMapHTMLBuilder.isValidKey(key) else { return nil }
        return key
    }

    private func reloadMap() {
        guard let location = currentLocation else { return }
        let converted = CoordinateConverter.wgs84ToGCJ02(latitude: location.latitude,
                                                          longitude: location.longitude)
        let html: String
        if let key = configuredKey {
            html = AMapHTMLBuilder.onlineHTML(key: key, securityCode: savedSecret(),
                                              latitude: converted.latitude,
                                              longitude: converted.longitude,
                                              fileName: currentFileName)
        } else {
            html = AMapHTMLBuilder.offlineHTML(wgsLatitude: location.latitude,
                                               wgsLongitude: location.longitude,
                                               gcjLatitude: converted.latitude,
                                               gcjLongitude: converted.longitude,
                                               fileName: currentFileName,
                                               source: location.source)
        }
        if let data = html.data(using: .utf8) {
            webView.load(data, mimeType: "text/html", characterEncodingName: "UTF-8",
                         baseURL: AMapHTMLBuilder.baseURL)
        }
    }
}

// MARK: - WKUIDelegate

/// 高德 SDK 在 Key / 安全密钥无效时会用 JS alert 报错；弹窗会暂停页面脚本，
/// 导致超时兜底无法出现。这里把提示转到窗口底部，让页面继续运行。
extension MapWindowController: WKUIDelegate {
    func webView(_ webView: WKWebView,
                 runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        NSLog("PhotoScope AMap JS alert: %@", message)
        hintLabel.stringValue = "高德地图提示：\(message)（请检查 Key 类型与安全密钥）"
        completionHandler()
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        completionHandler(false)
    }
}
