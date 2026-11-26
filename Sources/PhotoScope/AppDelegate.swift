import AppKit
import CoreGraphics

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var mainWindowController: MainWindowController?
    private var qualityPreviewWindow: NSWindow?
    private var sortMenu: NSMenu?
    private var viewMenu: NSMenu?
    /// Finder / Launch Services 可能在 applicationDidFinishLaunching 之前就把文件路径送进来。
    private var pendingOpenFileURL: URL?

    private enum MenuTag: Int {
        case fileName = 101, captureDate, model, lens, ascending, descending
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let wc = MainWindowController()
        mainWindowController = wc
        NSApp.mainMenu = buildMainMenu(target: wc)
        wc.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)

        let args = CommandLine.arguments

        // --dir <path>：启动时直接打开指定目录，便于自动化验证
        if let i = args.firstIndex(of: "--dir"), i + 1 < args.count {
            wc.openDirectory(URL(fileURLWithPath: args[i + 1]))
        }

        // 启动时由 Finder / Launch Services 传入的文件（openFile 可能早于本回调）。
        if let pending = pendingOpenFileURL {
            pendingOpenFileURL = nil
            DispatchQueue.main.async {
                _ = wc.revealFromFinder(pending)
                NSApp.activate(ignoringOtherApps: true)
            }
        }

        // --open-file <path>：模拟访达「打开方式」，用于无交互地验证同一条链路。
        if let i = args.firstIndex(of: "--open-file"), i + 1 < args.count {
            let url = URL(fileURLWithPath: args[i + 1])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                let ok = wc.revealFromFinder(url)
                NSLog("PhotoScope --open-file %@ -> %@", url.path, ok ? "accepted" : "rejected")
            }
        }

        // --view-mode grid|single|compare：启动时直接进入指定视图（不改用户偏好）。
        if let i = args.firstIndex(of: "--view-mode"), i + 1 < args.count {
            let raw = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak wc] in
                wc?.debugSetViewMode(raw)
                NSLog("PhotoScope --view-mode %@", raw)
            }
        }
        if args.contains("--dump-view-mode") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak wc] in
                wc?.debugDumpViewMode()
            }
        }
        if let i = args.firstIndex(of: "--compare-side"), i + 1 < args.count {
            let raw = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak wc] in
                wc?.debugActivateCompareSide(raw)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak wc] in
                wc?.debugDumpViewMode()
            }
        }

        if args.contains("--dump-layout") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak wc] in
                wc?.dumpLayout()
            }
        }

        // 自动化验证：选中指定文件、打开 EXIF 面板、打开地图面板
        if let i = args.firstIndex(of: "--select"), i + 1 < args.count {
            let name = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak wc] in
                wc?.selectItem(named: name)
            }
        }
        // 诊断：打印缩略图右键菜单树（含子菜单与勾选状态）
        if args.contains("--dump-context-menu") {
            let menu = ThumbnailContextMenu.build(
                target: wc,
                action: #selector(MainWindowController.openFolder(_:)),
                indexes: [0], hasRotation: true, containsVideo: false)
            print("=== PhotoScope 缩略图右键菜单 ===")
            ThumbnailContextMenu.describe(menu).forEach { print($0) }
        }

        // 诊断：--rotate <n>，正数顺时针 n 次 90°，负数逆时针；配合 --screenshot 验证旋转链路
        if let i = args.firstIndex(of: "--rotate"), i + 1 < args.count,
           let turns = Int(args[i + 1]), turns != 0 {
            let clockwise = turns > 0
            let count = min(abs(turns), 4)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { [weak wc] in
                for _ in 0..<count {
                    wc?.debugApply(clockwise
                                   ? ThumbnailContextAction.rotateClockwise
                                   : ThumbnailContextAction.rotateCounterClockwise)
                }
            }
        }

        // 诊断：--sort-by <fileName|captureDate|model|lens> 以降序重排并打印结果
        if let i = args.firstIndex(of: "--sort-by"), i + 1 < args.count {
            let key = MediaSortKey(rawValue: args[i + 1]) ?? .fileName
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak wc] in
                wc?.debugDumpOrder()                         // 排序前
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.7) { [weak wc] in
                wc?.debugApply(ThumbnailContextAction.sort(key: key, order: .descending))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak wc] in
                wc?.debugDumpOrder()                         // 排序后
            }
        }

        var panelDelay = 2.0
        if args.contains("--show-info") {
            DispatchQueue.main.asyncAfter(deadline: .now() + panelDelay) { [weak wc] in
                wc?.toggleInfo(nil)
            }
            panelDelay += 0.4
        }
        if args.contains("--show-map") {
            DispatchQueue.main.asyncAfter(deadline: .now() + panelDelay) { [weak wc] in
                wc?.showMap(nil)
            }
        }
        if let i = args.firstIndex(of: "--dump-quality"), i + 1 < args.count {
            wc.qualityDumpPath = args[i + 1]
        }
        // 诊断预览：把质量控件放进普通窗口，便于用窗口截图核对文字排版
        if args.contains("--show-quality-preview") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                let panel = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 470, height: 112),
                    styleMask: [.titled, .closable], backing: .buffered, defer: false
                )
                panel.title = "JPG 导出质量（诊断预览）"
                let accessory = JPEGQualityAccessoryView(quality: JPEGExporter.preferredQuality)
                accessory.frame.origin = NSPoint(x: 12, y: 14)
                panel.contentView?.addSubview(accessory)
                panel.center()
                panel.makeKeyAndOrderFront(nil)
                self?.qualityPreviewWindow = panel
            }
        }
        if args.contains("--show-save") {
            DispatchQueue.main.asyncAfter(deadline: .now() + panelDelay + 0.4) { [weak wc] in
                wc?.saveAsJPEG(nil)
            }
        }
        if args.contains("--map-debug") {
            // 两次采样：加载初期与 12 秒 SDK 超时兜底之后
            for delay in [panelDelay + 3.0, panelDelay + 13.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak wc] in
                    wc?.debugMapHTML()
                }
            }
        }
        if let i = args.firstIndex(of: "--capture-windows"), i + 1 < args.count {
            let prefix = args[i + 1]
            var delay = panelDelay + 2.5
            if let j = args.firstIndex(of: "--capture-delay"), j + 1 < args.count,
               let custom = Double(args[j + 1]) {
                delay = custom
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                var index = 0
                for window in NSApp.windows where window.isVisible {
                    guard let cg = CGWindowListCreateImage(
                        .null, .optionIncludingWindow,
                        CGWindowID(window.windowNumber), [.boundsIgnoreFraming]
                    ) else { continue }
                    let rep = NSBitmapImageRep(cgImage: cg)
                    let url = URL(fileURLWithPath: String(format: "%@-%d.png", prefix, index))
                    if let data = rep.representation(using: .png, properties: [:]) {
                        try? data.write(to: url)
                    }
                    index += 1
                }
                NSLog("PhotoScope captured %d windows", index)
            }
        }

        // 轨迹写入 GPS 页面诊断：--show-gps-writer [--gps-track <path>] [--gps-xiaomi]
        //                       [--gps-scope selected|all] [--gps-dry-run] [--gps-run]
        if args.contains("--show-gps-writer") || args.contains("--gps-run") {
            let track = valueAfter("--gps-track", in: args)
            let scopeRaw = valueAfter("--gps-scope", in: args) ?? "all"
            let scope = GPSWriteScope(rawValue: scopeRaw) ?? .all
            let xiaomi = args.contains("--gps-xiaomi")
            let dryRun = args.contains("--gps-dry-run")
            let autoRun = args.contains("--gps-run")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak wc] in
                wc?.debugOpenGPSWriter(track: track, xiaomi: xiaomi, scope: scope,
                                       dryRun: dryRun, autoRun: autoRun)
                NSLog("PhotoScope --gps-writer track=%@ xiaomi=%d scope=%@ dryRun=%d autoRun=%d",
                      track ?? "none", xiaomi, scope.rawValue, dryRun, autoRun)
            }
        }

        // --screenshot <path> [--delay <sec>] [--quit-after-screenshot]
        // 用于无交互地抓取主窗口渲染结果（不依赖屏幕录制权限）
        if let i = args.firstIndex(of: "--screenshot"), i + 1 < args.count {
            let path = args[i + 1]
            var delay = 1.5
            if let j = args.firstIndex(of: "--delay"), j + 1 < args.count,
               let d = Double(args[j + 1]) {
                delay = d
            }
            let shouldQuit = args.contains("--quit-after-screenshot")
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak wc] in
                let ok = wc?.captureScreenshot(to: URL(fileURLWithPath: path)) ?? false
                NSLog("PhotoScope screenshot: %@ (%@)", ok ? "ok" : "failed", path)
                if shouldQuit {
                    // 存在 modal sheet 时 NSApp.terminate 可能被拦截，诊断模式直接结束进程
                    Darwin.exit(0)
                }
            }
        }
    }

    /// 访达右键「打开方式」/ 双击文件 / `open -a` 都会走这里。
    ///
    /// Info.plist 声明了 public.image / public.movie 的 Viewer 角色，Launch Services
    /// 因此会把「打开文档」事件发给本程序。若不实现本回调，AppKit 会回绝打开并弹出
    /// “cannot open files in the ... format”。程序本身是目录浏览器，所以这里把单个
    /// 媒体文件换算成「打开所在目录 + 在列表中定位到这个文件」。
    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              OpenFileRouter.request(for: url, isDirectory: isDirectory.boolValue) != nil else {
            NSLog("PhotoScope openFile rejected: %@", filename)
            return false
        }
        NSLog("PhotoScope openFile accepted: %@", filename)

        if let wc = mainWindowController {
            let accepted = wc.revealFromFinder(url)
            NSApp.activate(ignoringOtherApps: true)
            return accepted
        }
        // 窗口尚未创建：先记下来，applicationDidFinishLaunching 里再消费。
        pendingOpenFileURL = url
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: - 主菜单（后续新增功能时在此挂载入口即可）

    private func buildMainMenu(target: MainWindowController) -> NSMenu {
        let mainMenu = NSMenu()

        // 应用菜单
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 PhotoScope", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let hide = appMenu.addItem(withTitle: "隐藏 PhotoScope", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        hide.target = NSApp
        let quit = appMenu.addItem(withTitle: "退出 PhotoScope", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        // 文件
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "文件")
        add(fileMenu, "打开文件夹…", #selector(MainWindowController.openFolder(_:)), "o", target)
        fileMenu.addItem(.separator())
        add(fileMenu, "另存为 JPG…", #selector(MainWindowController.saveAsJPEG(_:)), "s", target)
        add(fileMenu, "JPG 导出质量…", #selector(MainWindowController.configureJPEGQuality(_:)), "", target)
        fileMenu.addItem(.separator())
        add(fileMenu, "移到废纸篓…", #selector(MainWindowController.deleteSelectedPhoto(_:)), "", target)
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        // 编辑（保留标准快捷键，便于复制 EXIF 文本）
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        // 显示
        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "显示")
        let modeSelectors = [#selector(MainWindowController.switchToGridView(_:)),
                             #selector(MainWindowController.switchToSingleView(_:)),
                             #selector(MainWindowController.switchToCompareView(_:))]
        for (index, mode) in ViewMode.allCases.enumerated() {
            let item = NSMenuItem(title: mode.title, action: modeSelectors[index],
                                  keyEquivalent: mode.shortcut)
            item.target = target
            item.keyEquivalentModifierMask = [.command, .option]
            item.toolTip = mode.toolTip
            item.tag = 300 + index
            viewMenu.addItem(item)
        }
        viewMenu.addItem(.separator())
        viewMenu.delegate = self
        self.viewMenu = viewMenu
        add(viewMenu, "放大", #selector(MainWindowController.zoomIn(_:)), "+", target)
        add(viewMenu, "缩小", #selector(MainWindowController.zoomOut(_:)), "-", target)
        add(viewMenu, "适合窗口", #selector(MainWindowController.fitToWindow(_:)), "0", target)
        add(viewMenu, "实际大小", #selector(MainWindowController.actualSize(_:)), "1", target)
        viewMenu.addItem(.separator())
        add(viewMenu, "上一张", #selector(MainWindowController.previousPhoto(_:)), "", target)
        add(viewMenu, "下一张", #selector(MainWindowController.nextPhoto(_:)), "", target)
        viewMenu.addItem(.separator())
        add(viewMenu, "顺时针旋转 90°", #selector(MainWindowController.rotateClockwise(_:)), "]", target)
        add(viewMenu, "逆时针旋转 90°", #selector(MainWindowController.rotateCounterClockwise(_:)), "[", target)
        add(viewMenu, "恢复原始方向", #selector(MainWindowController.resetPhotoRotation(_:)), "", target)
        viewMenu.addItem(.separator())
        let sortItem = NSMenuItem(title: "排序方式", action: nil, keyEquivalent: "")
        let sort = NSMenu(title: "排序方式")
        sort.delegate = self
        tagged(sort, "按文件名", #selector(MainWindowController.sortByFileName(_:)), .fileName, "doc.text", target)
        tagged(sort, "按拍摄日期及时间", #selector(MainWindowController.sortByCaptureDate(_:)), .captureDate, "calendar", target)
        tagged(sort, "按型号名", #selector(MainWindowController.sortByModel(_:)), .model, "camera", target)
        tagged(sort, "按镜头名", #selector(MainWindowController.sortByLens(_:)), .lens, "camera.viewfinder", target)
        sort.addItem(.separator())
        tagged(sort, "升序排序", #selector(MainWindowController.sortAscending(_:)), .ascending, "arrow.up", target)
        tagged(sort, "降序排序", #selector(MainWindowController.sortDescending(_:)), .descending, "arrow.down", target)
        sortItem.submenu = sort
        sortMenu = sort
        viewMenu.addItem(sortItem)
        viewMenu.addItem(.separator())
        add(viewMenu, "照片信息 (EXIF)", #selector(MainWindowController.toggleInfo(_:)), "i", target)
        add(viewMenu, "在地图上显示", #selector(MainWindowController.showMap(_:)), "m", target)
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        // 工具
        let toolsItem = NSMenuItem()
        let toolsMenu = NSMenu(title: "工具")
        let gpsItem = NSMenuItem(title: "轨迹匹配写入 GPS…",
                                 action: #selector(MainWindowController.showGPSWriter(_:)),
                                 keyEquivalent: "g")
        gpsItem.target = target
        gpsItem.keyEquivalentModifierMask = [.command, .option]
        gpsItem.toolTip = "用 GPX / TCX 轨迹按拍摄时间给照片写入 GPS"
        toolsMenu.addItem(gpsItem)
        toolsItem.submenu = toolsMenu
        mainMenu.addItem(toolsItem)

        // 窗口
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        let mini = windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        mini.target = NSApp
        windowMenu.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        return mainMenu
    }

    private func valueAfter(_ flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String, _ target: AnyObject?) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target
        menu.addItem(item)
    }

    private func tagged(_ menu: NSMenu, _ title: String, _ action: Selector,
                        _ tag: MenuTag, _ symbol: String, _ target: AnyObject?) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target
        item.tag = tag.rawValue
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) {
            image.size = NSSize(width: 16, height: 16)
            item.image = image
        }
        menu.addItem(item)
    }

    /// 排序子菜单与视图模式菜单每次展开前刷新勾选状态。
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === viewMenu {
            for (index, mode) in ViewMode.allCases.enumerated() {
                menu.item(withTag: 300 + index)?.state = mode == ViewMode.current ? .on : .off
            }
            return
        }
        guard menu === sortMenu else { return }
        let options = MediaSortOptions.current
        for item in menu.items {
            guard let tag = MenuTag(rawValue: item.tag) else { continue }
            let selected: Bool
            switch tag {
            case .fileName: selected = options.key == .fileName
            case .captureDate: selected = options.key == .captureDate
            case .model: selected = options.key == .model
            case .lens: selected = options.key == .lens
            case .ascending: selected = options.order == .ascending
            case .descending: selected = options.order == .descending
            }
            item.state = selected ? .on : .off
        }
    }
}
