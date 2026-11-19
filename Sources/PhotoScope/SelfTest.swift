import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 命令行自检：不启动 UI，验证扫描 / 解码 / EXIF / GPS / JPG 导出。
/// 用法：PhotoScope --selftest --dir /path/to/photos
enum SelfTest {

    static func run(directory: String?) -> Int32 {
        let root = URL(fileURLWithPath: directory ?? "/Volumes/machack2/download/test-photo")
        print("=== PhotoScope 自检 ===")
        print("目录: \(root.path)")

        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            print("\(condition ? "PASS" : "FAIL")  \(label)")
            if !condition { failures += 1 }
        }

        // 1. 格式判定
        check(MediaSupport.kind(of: URL(fileURLWithPath: "/tmp/a.ARW")) == .image, "Sony ARW 识别为照片")
        check(MediaSupport.kind(of: URL(fileURLWithPath: "/tmp/a.HEIC")) == .image, "HEIC 识别为照片")
        check(MediaSupport.kind(of: URL(fileURLWithPath: "/tmp/a.DNG")) == .image, "DNG 识别为照片")
        check(MediaSupport.kind(of: URL(fileURLWithPath: "/tmp/a.MP4")) == .video, "MP4 识别为视频")
        check(MediaSupport.kind(of: URL(fileURLWithPath: "/tmp/a.dop")) == nil, "DxO 旁路文件被排除")
        check(MediaSupport.kind(of: URL(fileURLWithPath: "/tmp/a.gpx")) == nil, "GPX 轨迹被排除")

        let gcj = CoordinateConverter.wgs84ToGCJ02(latitude: 34.2312667, longitude: 117.160083)
        let delta = abs(gcj.latitude - 34.2312667) + abs(gcj.longitude - 117.160083)
        check(delta > 0.0001 && delta < 0.05, "WGS-84 → GCJ-02 偏移在合理范围 (Δ=\(String(format: "%.5f", delta)))")
        let overseas = CoordinateConverter.wgs84ToGCJ02(latitude: 35.6895, longitude: 139.6917)
        check(overseas.latitude == 35.6895 && overseas.longitude == 139.6917, "境外坐标不做偏移")

        // 1.5 高德地图页面结构（不发起网络请求，不内含任何真实密钥）
        check(!AMapHTMLBuilder.isValidKey(AMapHTMLBuilder.placeholderKey), "Key 占位符不会被当作有效密钥")
        check(AMapHTMLBuilder.baseURL.host == "photoscope.local", "WKWebView origin 与域名白名单一致")
        let sampleHTML = AMapHTMLBuilder.onlineHTML(key: "DUMMY_KEY", securityCode: "DUMMY_CODE",
                                                    latitude: 34.2312667, longitude: 117.160083,
                                                    fileName: "O'Brien <test>.jpg")
        check(sampleHTML.contains("webapi.amap.com/maps?v=2.0&key="), "高德 JS API 2.0 SDK URL")
        check(sampleHTML.contains("callback=onAMapLoaded"), "SDK 异步回调已声明")
        check(sampleHTML.contains("_AMapSecurityConfig") && sampleHTML.contains("DUMMY_CODE"),
              "安全密钥在 SDK 引入之前配置")
        check(sampleHTML.contains("AMap.Marker") && sampleHTML.contains("AMap.InfoWindow"),
              "高德标注与信息窗体 API")
        check(sampleHTML.contains("[117.1600830, 34.2312667]"), "GCJ-02 坐标按 [经度, 纬度] 传入")
        check(sampleHTML.contains("O\\'Brien") && sampleHTML.contains("&lt;test&gt;"),
              "文件名中的引号与尖括号已转义")
        check(!sampleHTML.localizedCaseInsensitiveContains("map.qq.com") && !sampleHTML.contains("TMap."),
              "底图仅使用高德 SDK")
        let noSecretHTML = AMapHTMLBuilder.onlineHTML(key: "DUMMY_KEY", securityCode: "",
                                                      latitude: 34.0, longitude: 117.0, fileName: "a.jpg")
        check(!noSecretHTML.contains("_AMapSecurityConfig"), "老 Key 可省略安全密钥")
        let offline = AMapHTMLBuilder.offlineHTML(wgsLatitude: 34.0, wgsLongitude: 117.0,
                                                 gcjLatitude: 34.001, gcjLongitude: 117.005,
                                                 fileName: "a.jpg", source: "EXIF GPS")
        check(offline.contains("lbs.amap.com") && offline.contains("photoscope.local"),
              "离线卡片包含高德申请指引与域名白名单说明")

        // 1.6 JPG 导出质量设置
        check(JPEGExporter.clamped(2.0) == 1.0, "质量上限约束为 100%")
        check(JPEGExporter.clamped(-1.0) == JPEGExporter.minimumQuality, "质量下限约束为 10%")
        check(JPEGExporter.percent(0.90) == 90, "质量百分比换算（默认 90%）")

        // 1.7 旋转、排序与右键菜单
        check(RotationStore.normalized(-1) == 3 && RotationStore.normalized(5) == 1, "旋转角度归一化到 0…3")
        let rotationProbe = URL(fileURLWithPath: "/tmp/PhotoScope-Rotation-\(UUID().uuidString).jpg")
        RotationStore.purge([rotationProbe])
        check(RotationStore.quarterTurns(for: rotationProbe) == 0, "旋转记录初始为空")
        check(RotationStore.add(1, for: rotationProbe) == 1, "顺时针旋转写入覆盖")
        check(RotationStore.add(-1, for: rotationProbe) == 0, "顺 / 逆旋转相互抵消")
        check(RotationStore.add(-1, for: rotationProbe) == 3 && RotationStore.degrees(for: rotationProbe) == 270,
              "逆时针 90° 记为 270°")
        RotationStore.purge([rotationProbe])
        check(RotationStore.quarterTurns(for: rotationProbe) == 0, "删除文件后清除旋转记录")

        if let base = makeStripImage() {
            let cw = ImageDecoder.rotated(base, quarterTurns: 1)
            check(cw.width == 1 && cw.height == 2, "顺时针 90° 交换宽高 2×1 → 1×2")
            if let top = pixel(of: cw, x: 0, y: 0), let bottom = pixel(of: cw, x: 0, y: 1) {
                check(isRed(top) && isGreen(bottom), "顺时针 90° 方向正确（左红→上，右绿→下）")
            } else { check(false, "顺时针 90° 像素可读") }

            let ccw = ImageDecoder.rotated(base, quarterTurns: -1)
            if let top = pixel(of: ccw, x: 0, y: 0), let bottom = pixel(of: ccw, x: 0, y: 1) {
                check(isGreen(top) && isRed(bottom), "逆时针 90° 方向正确（右绿→上，左红→下）")
            } else { check(false, "逆时针 90° 像素可读") }

            let half = ImageDecoder.rotated(base, quarterTurns: 2)
            check(half.width == 2 && half.height == 1, "180° 不改变宽高")
            if let left = pixel(of: half, x: 0, y: 0), let right = pixel(of: half, x: 1, y: 0) {
                check(isGreen(left) && isRed(right), "180° 左右互换")
            }
            check(ImageDecoder.rotated(base, quarterTurns: 4).width == 2, "旋转 4 次回到原始方向")
        } else {
            check(false, "生成旋转测试图")
        }

        check(MediaSortIndex.compareNames("a.jpg", "b.jpg", order: .ascending) == .orderedAscending, "文件名升序")
        check(MediaSortIndex.compareNames("a.jpg", "b.jpg", order: .descending) == .orderedDescending, "文件名降序")
        check(MediaSortIndex.compareString(nil, "X", order: .ascending) == .orderedDescending, "空型号 / 镜头升序置底")
        check(MediaSortIndex.compareString(nil, "X", order: .descending) == .orderedDescending, "空型号 / 镜头降序仍置底")
        let d1 = Date(timeIntervalSince1970: 1000), d2 = Date(timeIntervalSince1970: 2000)
        check(MediaSortIndex.compareDate(d1, d2, order: .ascending) == .orderedAscending, "拍摄时间升序")
        check(MediaSortIndex.compareDate(d1, d2, order: .descending) == .orderedDescending, "拍摄时间降序")
        check(MediaSortIndex.compareDate(nil, d1, order: .descending) == .orderedDescending, "无拍摄时间恒置底")
        check(MediaSortKey.allCases.count == 4 && MediaSortOrder.allCases.count == 2, "4 种排序字段 / 2 种方向")

        let probeTarget = MenuProbe()
        let probeAction = #selector(MenuProbe.tapped(_:))
        let menu = ThumbnailContextMenu.build(target: probeTarget, action: probeAction,
                                              indexes: [0, 1], hasRotation: true, containsVideo: false)
        let titles = menu.items.map(\.title)
        check(titles.contains("顺时针旋转 90°") && titles.contains("逆时针旋转 90°"), "菜单含顺 / 逆时针旋转")
        check(titles.contains("恢复原始方向"), "菜单含恢复原始方向")
        check(titles.contains(where: { $0.hasPrefix("移到废纸篓") }), "菜单含移到废纸篓")
        check(titles.contains("在 Finder 中显示") && titles.contains("复制文件路径"), "菜单含额外实用操作")
        check(menu.items.filter { !$0.isSeparatorItem }.allSatisfy { $0.image != nil }, "菜单项均带图标")
        if let sub = menu.items.first(where: { $0.submenu != nil })?.submenu {
            let subTitles = sub.items.map(\.title)
            for field in ["按文件名", "按拍摄日期及时间", "按型号名", "按镜头名", "升序排序", "降序排序"] {
                check(subTitles.contains(field), "排序子菜单含「\(field)」")
            }
            let on = sub.items.filter { $0.state == .on }.map(\.title)
            let options = MediaSortOptions.current
            check(on.count == 2
                  && on.contains(options.key.menuTitle)
                  && on.contains(options.order == .ascending ? "升序排序" : "降序排序"),
                  "排序子菜单勾选与当前偏好一致")
            check(sub.items.filter { !$0.isSeparatorItem }.allSatisfy { $0.representedObject is ThumbnailContextActionBox },
                  "排序项均绑定动作")
        } else {
            check(false, "排序子菜单存在")
        }
        let videoMenu = ThumbnailContextMenu.build(target: probeTarget, action: probeAction,
                                                   indexes: [0], hasRotation: false, containsVideo: true)
        check(videoMenu.items.first(where: { $0.title == "顺时针旋转 90°" })?.isEnabled == false,
              "视频禁用旋转（播放器方向不可覆盖）")

        // 1.8 EXIF 迁移的纯函数行为
        let syntheticGPS = EXIFPreserver.gpsDictionary(
            GPSLocation(latitude: -33.865, longitude: 151.209, altitude: -12, source: "自检"))
        check(syntheticGPS[kCGImagePropertyGPSLatitudeRef as String] as? String == "S"
              && syntheticGPS[kCGImagePropertyGPSLongitudeRef as String] as? String == "E",
              "GPS 兜底字典正确写入 N/S/E/W")
        check((syntheticGPS[kCGImagePropertyGPSLatitude as String] as? Double) == 33.865
              && syntheticGPS[kCGImagePropertyGPSAltitudeRef as String] as? Int == 1,
              "GPS 兜底字典取绝对值并标注负海拔")
        check(syntheticGPS[kCGImagePropertyGPSMapDatum as String] as? String == "WGS-84",
              "EXIF 写入 WGS-84（不做 GCJ-02 偏移）")
        if let strip = makeStripImage() {
            let probeItem = MediaItem(url: URL(fileURLWithPath: "/tmp/PhotoScope-EXIF-Probe-\(UUID().uuidString).jpg"),
                                      kind: .image, byteCount: 0, modifiedAt: nil)
            let props = EXIFPreserver.properties(for: probeItem, image: strip, quality: 0.9)
            check(ImageDecoder.numberValue(props[kCGImagePropertyOrientation as String]) == 1,
                  "导出属性把顶层方向重置为 1")
            let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
            check(ImageDecoder.numberValue(tiff[kCGImagePropertyTIFFOrientation as String]) == 1,
                  "导出属性把 TIFF 方向重置为 1（避免二次旋转）")
            let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
            check((props[kCGImagePropertyPixelWidth as String] as? Int) == 2
                  && (props[kCGImagePropertyPixelHeight as String] as? Int) == 1
                  && (exif[kCGImagePropertyExifPixelXDimension as String] as? Int) == 2
                  && (exif[kCGImagePropertyExifPixelYDimension as String] as? Int) == 1,
                  "导出属性按真实像素重写四类尺寸字段")
            check(tiff[kCGImagePropertyTIFFCompression as String] == nil
                  && exif[kCGImagePropertyExifCompressedBitsPerPixel as String] == nil,
                  "导出属性剔除随压缩质量变化的失效字段")
            let core = EXIFPreserver.coreProperties(props)
            check(core.keys.allSatisfy { key in
                [kCGImagePropertyExifDictionary as String,
                 kCGImagePropertyTIFFDictionary as String,
                 kCGImagePropertyGPSDictionary as String,
                 kCGImagePropertyOrientation as String,
                 kCGImagePropertyPixelWidth as String,
                 kCGImagePropertyPixelHeight as String,
                 kCGImageDestinationLossyCompressionQuality as String].contains(key)
            }, "写入失败时的核心元数据降级集合")
            check(EXIFPreserver.minimalProperties(quality: 0.9).count == 1,
                  "最终兜底仅保留压缩质量")
        } else {
            check(false, "生成 EXIF 属性测试图")
        }

        // 1.9 访达「打开方式」路由（解决 “cannot open files in the JPEG image format”）
        let openDir = URL(fileURLWithPath: "/tmp")
        if let dirRequest = OpenFileRouter.request(for: openDir, isDirectory: true) {
            check(dirRequest.directory.path == "/tmp" && dirRequest.selectedFile == nil,
                  "访达打开目录 → 直接作为根目录")
        } else { check(false, "访达打开目录 → 直接作为根目录") }
        let jpegFile = URL(fileURLWithPath: "/tmp/DSC07599-1.jpeg")
        if let fileRequest = OpenFileRouter.request(for: jpegFile, isDirectory: false) {
            check(fileRequest.directory.path == "/tmp"
                  && fileRequest.selectedFile?.lastPathComponent == "DSC07599-1.jpeg",
                  "访达打开 .jpeg → 打开所在目录并定位该文件")
        } else { check(false, "访达打开 .jpeg → 打开所在目录并定位该文件") }
        check(OpenFileRouter.request(for: URL(fileURLWithPath: "/tmp/DSC01955.ARW"),
                                     isDirectory: false)?.selectedFile?.pathExtension == "ARW",
              "访达打开 RAW → 同样受理")
        check(OpenFileRouter.request(for: URL(fileURLWithPath: "/tmp/a.txt"), isDirectory: false) == nil
              && OpenFileRouter.request(for: URL(fileURLWithPath: "/tmp/a.mkv"), isDirectory: false) == nil,
              "访达打开不支持的文件 → 明确回绝")
        check(AppDelegate().responds(to: NSSelectorFromString("application:openFile:")),
              "AppDelegate 实现 Launch Services 打开文档回调")

        // 2. 目录扫描
        let items = MediaScanner.scan(directory: root)
        check(!items.isEmpty, "扫描到 \(items.count) 个媒体文件")
        let images = items.filter { !$0.isVideo }
        let videos = items.filter { $0.isVideo }

        // 2.5 真实目录排序（同步路径，覆盖 EXIF 读取与缓存）
        if items.count > 1 {
            let asc = MediaSortIndex.shared.sortedSync(items, options: MediaSortOptions(key: .fileName, order: .ascending))
            let desc = MediaSortIndex.shared.sortedSync(items, options: MediaSortOptions(key: .fileName, order: .descending))
            check(asc.map(\.name) == desc.reversed().map(\.name), "文件名升序 / 降序互为逆序")
            let byDate = MediaSortIndex.shared.sortedSync(items, options: MediaSortOptions(key: .captureDate, order: .ascending))
            let byModel = MediaSortIndex.shared.sortedSync(items, options: MediaSortOptions(key: .model, order: .ascending))
            let byLens = MediaSortIndex.shared.sortedSync(items, options: MediaSortOptions(key: .lens, order: .ascending))
            check(byDate.count == items.count && byModel.count == items.count && byLens.count == items.count,
                  "拍摄日期 / 型号 / 镜头排序均不丢失条目")
            if let sample = images.first {
                let facts = MediaSortIndex.shared.facts(for: sample)
                check(facts.captureDate != nil || facts.model != nil || facts.lens != nil,
                      "EXIF 排序字段提取成功（\(sample.name)）")
            }
        } else {
            print("SKIP  目录文件不足，跳过排序对比")
        }

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoScope-SelfTest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        // 3. 按扩展名抽样：解码 + 元数据 + JPG 导出
        var seenExtensions = Set<String>()
        var exported = 0
        var gpsFound = 0
        for item in images {
            let ext = item.url.pathExtension.lowercased()
            if seenExtensions.contains(ext) { continue }
            seenExtensions.insert(ext)

            let decoded = ImageDecoder.bounded(url: item.url, maxPixel: 1200)
            check(decoded?.cgImage.width ?? 0 > 0, "解码 \(item.name) -> \(decoded?.cgImage.width ?? 0)×\(decoded?.cgImage.height ?? 0)")

            let metadata = MetadataReader.read(item)
            check(!metadata.sections.isEmpty, "EXIF 分组 \(metadata.sections.count) 组 / \(item.name)")
            if metadata.gps != nil { gpsFound += 1 }

            let destination = scratch.appendingPathComponent("export-\(ext).jpg")
            do {
                let output = try JPEGExporter.export(item, to: destination)
                let data = try Data(contentsOf: output)
                let isJPEG = data.count > 2 && data[0] == 0xFF && data[1] == 0xD8
                let readable = ImageDecoder.imageProperties(for: output) != nil
                let size = ImageDecoder.pixelSize(for: output)
                let sizeText = size.map { "\(Int($0.width))×\(Int($0.height))" } ?? "未知尺寸"
                check(isJPEG && readable, "导出 JPG \(item.name) -> \(sizeText) / \(MetadataReader.byteString(Int64(data.count)))")
                if isJPEG { exported += 1 }
                compareEXIF(source: item.url, output: output, name: item.name, check: check)
            } catch {
                check(false, "导出 JPG \(item.name): \(error.localizedDescription)")
            }

            if seenExtensions.count >= 8 { break }
        }
        print("INFO 覆盖扩展名: \(seenExtensions.sorted().joined(separator: ", "))")
        print("INFO 检出 GPS 的照片: \(gpsFound)")

        // 3.5 质量参数确实影响输出体积（显式传参，不改动使用者偏好）
        if let probe = images.first {
            do {
                let low = try JPEGExporter.export(probe, to: scratch.appendingPathComponent("quality-30.jpg"),
                                                  quality: 0.30)
                let high = try JPEGExporter.export(probe, to: scratch.appendingPathComponent("quality-98.jpg"),
                                                   quality: 0.98)
                let lowSize = (try? Data(contentsOf: low).count) ?? 0
                let highSize = (try? Data(contentsOf: high).count) ?? 0
                check(lowSize > 0 && highSize > lowSize,
                      "质量 30% / 98% 生效（\(MetadataReader.byteString(Int64(lowSize))) → \(MetadataReader.byteString(Int64(highSize)))）")
            } catch {
                check(false, "不同质量导出 \(probe.name): \(error.localizedDescription)")
            }
        } else {
            print("SKIP  目录中没有可用于质量对比的照片")
        }

        // 3.6 旋转覆盖必须同样作用于 JPG 导出，而不只是屏幕显示
        if let probe = images.first,
           let small = ImageDecoder.bounded(url: probe.url, maxPixel: 640)?.cgImage {
            let source = scratch.appendingPathComponent("rotation-source.jpg")
            let rotationSourceProps: [String: Any] = [
                "{TIFF}": ["Make": "PhotoScope 自检", "Model": "Rotation-EXIF"],
                "{Exif}": ["DateTimeOriginal": "2024:01:02 03:04:05", "LensModel": "Test Lens 50mm"],
                "{GPS}": ["Latitude": 34.2312667, "LatitudeRef": "N",
                          "Longitude": 117.160083, "LongitudeRef": "E", "MapDatum": "WGS-84"],
                kCGImageDestinationLossyCompressionQuality as String: 0.95
            ]
            if let writer = CGImageDestinationCreateWithURL(
                source as CFURL, UTType.jpeg.identifier as CFString, 1, nil
            ) {
                CGImageDestinationAddImage(writer, small, rotationSourceProps as CFDictionary)
                if CGImageDestinationFinalize(writer) {
                    let item = MediaItem(url: source, kind: .image, byteCount: 0, modifiedAt: nil)
                    do {
                        let plainURL = try JPEGExporter.export(item, to: scratch.appendingPathComponent("no-rotation.jpg"))
                        RotationStore.add(1, for: source)
                        let turnedURL = try JPEGExporter.export(item, to: scratch.appendingPathComponent("with-rotation.jpg"))
                        let plain = ImageDecoder.pixelSize(for: plainURL)
                        let turned = ImageDecoder.pixelSize(for: turnedURL)
                        let swapped = plain.flatMap { a in turned.map { b in
                            Int(a.width) == Int(b.height) && Int(a.height) == Int(b.width)
                        }} ?? false
                        let sizeText = { (size: CGSize?) in
                            size.map { "\(Int($0.width))×\(Int($0.height))" } ?? "?"
                        }
                        check(swapped, "旋转覆盖作用于 JPG 导出（\(sizeText(plain)) → \(sizeText(turned))）")
                        let turnedProps = ImageDecoder.imageProperties(for: turnedURL) ?? [:]
                        let turnedExif = turnedProps["{Exif}"] as? [String: Any] ?? [:]
                        let turnedTIFF = turnedProps["{TIFF}"] as? [String: Any] ?? [:]
                        let turnedGPS = turnedProps["{GPS}"] as? [String: Any] ?? [:]
                        check(turnedExif["DateTimeOriginal"] as? String == "2024:01:02 03:04:05"
                              && turnedExif["LensModel"] as? String == "Test Lens 50mm"
                              && turnedTIFF["Make"] as? String == "PhotoScope 自检"
                              && ImageDecoder.numberValue(turnedGPS[kCGImagePropertyGPSLatitude as String]) != nil,
                              "旋转后导出仍保留 EXIF / GPS")
                        check(ImageDecoder.numberValue(turnedProps[kCGImagePropertyOrientation as String]) == 1
                              && Int(ImageDecoder.numberValue(turnedExif[kCGImagePropertyExifPixelXDimension as String] ?? -1) ?? -1) == Int(turned?.width ?? 0)
                              && Int(ImageDecoder.numberValue(turnedExif[kCGImagePropertyExifPixelYDimension as String] ?? -1) ?? -1) == Int(turned?.height ?? 0),
                              "旋转后导出的方向与尺寸元数据同步修正")
                    } catch {
                        check(false, "旋转导出 \(probe.name): \(error.localizedDescription)")
                    }
                    RotationStore.purge([source])
                } else {
                    print("SKIP  无法生成旋转测试源图")
                }
            }
        }

        // 3.7 源 EXIF 方向非 1 时：像素烘焙 + 方向归一 + 元数据保留 + 不会二次旋转
        if let base = images.first,
           let cg = ImageDecoder.bounded(url: base.url, maxPixel: 640)?.cgImage {
            let orientedSource = scratch.appendingPathComponent("oriented-source.jpg")
            let sourceProps: [String: Any] = [
                kCGImagePropertyOrientation as String: 6,
                "{TIFF}": ["Orientation": 6, "Make": "PhotoScope 自检", "Model": "Orientation-6"],
                "{Exif}": ["DateTimeOriginal": "2024:01:02 03:04:05", "LensModel": "Test Lens 50mm"],
                kCGImageDestinationLossyCompressionQuality as String: 0.95
            ]
            if let writer = CGImageDestinationCreateWithURL(
                orientedSource as CFURL, UTType.jpeg.identifier as CFString, 1, nil
            ) {
                CGImageDestinationAddImage(writer, cg, sourceProps as CFDictionary)
                if CGImageDestinationFinalize(writer) {
                    check(ImageDecoder.orientation(for: orientedSource) == 6, "构造出 EXIF 方向 6 的测试源")
                    let item = MediaItem(url: orientedSource, kind: .image,
                                         byteCount: 0, modifiedAt: nil)
                    do {
                        let first = try JPEGExporter.export(item, to: scratch.appendingPathComponent("oriented-out1.jpg"))
                        let p1 = ImageDecoder.imageProperties(for: first) ?? [:]
                        let e1 = p1["{Exif}"] as? [String: Any] ?? [:]
                        let t1 = p1["{TIFF}"] as? [String: Any] ?? [:]
                        let s1 = ImageDecoder.pixelSize(for: first)
                        check(s1.map { Int($0.width) == cg.height && Int($0.height) == cg.width } ?? false,
                              "EXIF 方向 6 已烘焙进像素（\(cg.width)×\(cg.height) → \(s1.map { "\(Int($0.width))×\(Int($0.height))" } ?? "?")）")
                        check(ImageDecoder.numberValue(p1[kCGImagePropertyOrientation as String]) == 1
                              && ImageDecoder.numberValue(t1["Orientation"]) == 1,
                              "方向 6 导出后归一化为 1")
                        check(e1["DateTimeOriginal"] as? String == "2024:01:02 03:04:05"
                              && e1["LensModel"] as? String == "Test Lens 50mm"
                              && t1["Make"] as? String == "PhotoScope 自检"
                              && t1["Model"] as? String == "Orientation-6",
                              "方向 6 导出后 EXIF / TIFF 自定义字段完整保留")
                        let secondItem = MediaItem(url: first, kind: .image, byteCount: 0, modifiedAt: nil)
                        let second = try JPEGExporter.export(secondItem, to: scratch.appendingPathComponent("oriented-out2.jpg"))
                        let s2 = ImageDecoder.pixelSize(for: second)
                        check(s1.map { a in s2.map { b in Int(a.width) == Int(b.width) && Int(a.height) == Int(b.height) } ?? false } ?? false,
                              "二次导出尺寸不变（无重复旋转）")
                        let e2 = (ImageDecoder.imageProperties(for: second) ?? [:])["{Exif}"] as? [String: Any] ?? [:]
                        check(e2["DateTimeOriginal"] as? String == "2024:01:02 03:04:05",
                              "二次导出仍保留 EXIF")
                    } catch {
                        check(false, "EXIF 方向 6 导出: \(error.localizedDescription)")
                    }
                } else {
                    print("SKIP  无法生成方向 6 的测试源")
                }
            }
        }

        // 3.8 带 GPS 的照片必须单独导出验证（按扩展名抽样可能恰好跳过它）
        if let gpsPhoto = images.first(where: { MetadataReader.gpsLocation(for: $0) != nil }) {
            do {
                let output = try JPEGExporter.export(
                    gpsPhoto, to: scratch.appendingPathComponent("gps-preserved.jpg"))
                compareEXIF(source: gpsPhoto.url, output: output, name: gpsPhoto.name, check: check)
                let props = ImageDecoder.imageProperties(for: output) ?? [:]
                let gps = props["{GPS}"] as? [String: Any] ?? [:]
                check(ImageDecoder.numberValue(gps[kCGImagePropertyGPSLatitude as String]) != nil
                      && ImageDecoder.numberValue(gps[kCGImagePropertyGPSLongitude as String]) != nil
                      && gps[kCGImagePropertyGPSLatitudeRef as String] as? String != nil,
                      "GPS 字典完整写入导出 JPG（\(gpsPhoto.name)）")
            } catch {
                check(false, "GPS 照片导出 \(gpsPhoto.name): \(error.localizedDescription)")
            }
        } else {
            print("SKIP  目录中没有带 GPS 的照片")
        }

        // 4. 生成一张 HEIC 并验证解码链路（覆盖本机没有 HEIC 样本的情况）
        if let first = images.first, let cg = ImageDecoder.fullSize(url: first.url)?.cgImage {
            let heicURL = scratch.appendingPathComponent("generated.heic")
            if let writer = CGImageDestinationCreateWithURL(
                heicURL as CFURL, UTType.heic.identifier as CFString, 1, nil
            ) {
                CGImageDestinationAddImage(writer, cg, nil)
                if CGImageDestinationFinalize(writer) {
                    let heic = MediaItem(url: heicURL, kind: .image, byteCount: 0, modifiedAt: nil)
                    let decoded = ImageDecoder.bounded(url: heic.url, maxPixel: 1200)
                    check(decoded?.cgImage.width ?? 0 > 0, "HEIC 生成并解码成功")
                    let props = MetadataReader.read(heic)
                    check(!props.sections.isEmpty, "HEIC 元数据读取成功")
                } else {
                    print("SKIP  当前系统不支持 HEIC 编码")
                }
            } else {
                print("SKIP  当前系统不支持 HEIC 编码")
            }
        }

        // 5. 视频：取帧 + 元数据
        if let video = videos.first {
            let poster = ImageDecoder.videoPoster(url: video.url, maxPixel: 600)
            check(poster != nil, "视频取帧 \(video.name)")
            let metadata = MetadataReader.read(video)
            check(!metadata.sections.isEmpty, "视频元数据 \(video.name)")
            do {
                let output = try JPEGExporter.export(video, to: scratch.appendingPathComponent("video-frame.jpg"))
                let props = ImageDecoder.imageProperties(for: output) ?? [:]
                let exif = props["{Exif}"] as? [String: Any] ?? [:]
                check(ImageDecoder.numberValue(props[kCGImagePropertyOrientation as String]) == 1,
                      "视频取帧 JPG 方向为 1")
                if MetadataReader.videoCaptureDate(for: video.url) != nil {
                    check(exif[kCGImagePropertyExifDateTimeOriginal as String] as? String != nil,
                          "视频取帧 JPG 写入原始拍摄时间")
                } else {
                    print("SKIP  视频素材未记录创建时间，跳过拍摄时间断言")
                }
                if metadata.gps != nil {
                    let exported = MediaItem(url: output, kind: .image, byteCount: 0, modifiedAt: nil)
                    let gps = MetadataReader.gpsLocation(for: exported)
                    check(gps != nil, "视频 GPS 写入取帧 JPG 后仍可识别")
                }
            } catch {
                check(false, "视频取帧导出 JPG \(video.name): \(error.localizedDescription)")
            }
        } else {
            print("SKIP  目录中没有视频文件")
        }

        print("=== 结果: \(failures == 0 ? "全部通过" : "\(failures) 项失败")，JPG 导出 \(exported) 张 ===")
        try? FileManager.default.removeItem(at: scratch)
        return failures == 0 ? 0 : 1
    }
}

private final class MenuProbe: NSObject {
    @objc func tapped(_ sender: Any?) {}
}

/// 2×1 测试图：左红右绿，用于验证 90° 旋转的视觉方向。
private func makeStripImage() -> CGImage? {
    guard let context = CGContext(
        data: nil, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
    context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
    context.fill(CGRect(x: 1, y: 0, width: 1, height: 1))
    return context.makeImage()
}

private func pixel(of image: CGImage, x: Int, y: Int) -> (Int, Int, Int)? {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return nil }
    return (Int(color.redComponent * 255), Int(color.greenComponent * 255), Int(color.blueComponent * 255))
}

private func isRed(_ p: (Int, Int, Int)) -> Bool { p.0 > 150 && p.0 > p.1 * 2 }
private func isGreen(_ p: (Int, Int, Int)) -> Bool { p.1 > 150 && p.1 > p.0 * 2 }

// MARK: - EXIF 保留比对

/// 取出需要「原样带过去」的字段。刻意排除方向、尺寸、压缩相关字段——
/// 这些字段由 EXIFPreserver 按本次导出重新计算，另有单独断言。
private func exifSnapshot(_ url: URL) -> [String: Any] {
    guard let props = ImageDecoder.imageProperties(for: url) else { return [:] }
    let groups: [String: [String]] = [
        "{Exif}": ["DateTimeOriginal", "DateTimeDigitized", "LensModel", "LensMake",
                   "ISOSpeedRatings", "FNumber", "ExposureTime", "FocalLength",
                   "FocalLenIn35mmFilm", "LensSpecification", "ExposureBiasValue",
                   "MeteringMode", "ExposureProgram", "Flash", "WhiteBalance",
                   "OffsetTime", "OffsetTimeOriginal", "UserComment", "MakerNote",
                   "BodySerialNumber", "LensSerialNumber", "CameraOwnerName", "ColorSpace",
                   "SensitivityType", "LightSource", "MaxApertureValue", "BrightnessValue"],
        "{TIFF}": ["Make", "Model", "Software", "DateTime", "Artist", "Copyright",
                   "ImageDescription", "XResolution", "YResolution", "ResolutionUnit"],
        "{GPS}": ["Latitude", "Longitude", "LatitudeRef", "LongitudeRef", "Altitude",
                  "AltitudeRef", "MapDatum", "DateStamp", "TimeStamp", "ImgDirection"],
        "{ExifAux}": ["LensModel", "LensID", "ImageStabilization"],
        "{IPTC}": ["Caption/Abstract", "Keywords", "ObjectName"]
    ]
    var snapshot: [String: Any] = [:]
    for (group, keys) in groups {
        guard let dict = props[group] as? [String: Any] else { continue }
        for key in keys where dict[key] != nil {
            snapshot["\(group).\(key)"] = dict[key]
        }
    }
    return snapshot
}

/// JPEG 重写 EXIF 时浮点数会有极小的量化误差（如度分秒往返），用容差比较。
private func sameMetadataValue(_ lhs: Any, _ rhs: Any) -> Bool {
    if let a = ImageDecoder.numberValue(lhs), let b = ImageDecoder.numberValue(rhs) {
        return abs(a - b) <= max(1e-6, max(abs(a), abs(b)) * 1e-5)
    }
    if let a = lhs as? [Any], let b = rhs as? [Any] {
        return a.count == b.count && zip(a, b).allSatisfy { sameMetadataValue($0, $1) }
    }
    if let a = lhs as? String, let b = rhs as? String {
        return a.trimmingCharacters(in: .whitespacesAndNewlines)
            == b.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if let a = lhs as? Data, let b = rhs as? Data { return a == b }
    return String(describing: lhs) == String(describing: rhs)
}

private func compareEXIF(source: URL, output: URL, name: String,
                         check: (Bool, String) -> Void) {
    let before = exifSnapshot(source)
    let after = exifSnapshot(output)
    if !before.isEmpty {
        // 实测：即使把源文件整份 properties 原样回写，ImageIO 的 JPEG 编码器也会丢掉
        // 这两个辅助字段（ExifAux 是只读解析组；RAW 的 ColorSpace 由 ICC profile 表达）。
        let encoderDropped: Set<String> = ["{ExifAux}.ImageStabilization", "{Exif}.ColorSpace"]
        let allMissing = before.keys.filter { after[$0] == nil }.sorted()
        let tolerated = allMissing.filter { encoderDropped.contains($0) }
        let missing = allMissing.filter { !encoderDropped.contains($0) }
        let changed = before.keys.filter { key in
            guard let target = after[key] else { return false }
            return !sameMetadataValue(before[key]!, target)
        }.sorted()
        let detail = (missing.isEmpty ? "" : " / 缺失 \(missing.joined(separator: ","))")
            + (changed.isEmpty ? "" : " / 变化 \(changed.joined(separator: ","))")
        check(missing.isEmpty && changed.isEmpty,
              "EXIF/GPS 逐字段保留 \(name)：\(before.count) 项\(detail)")
        if !tolerated.isEmpty {
            print("INFO 编码器忽略的辅助字段 \(name)：\(tolerated.joined(separator: ","))")
        }
    } else {
        print("SKIP  源文件无 EXIF 字段：\(name)")
    }

    let props = ImageDecoder.imageProperties(for: output) ?? [:]
    let tiff = props["{TIFF}"] as? [String: Any] ?? [:]
    let exif = props["{Exif}"] as? [String: Any] ?? [:]
    let size = ImageDecoder.pixelSize(for: output)
    check(ImageDecoder.numberValue(props[kCGImagePropertyOrientation as String]) == 1
          && ImageDecoder.numberValue(tiff[kCGImagePropertyTIFFOrientation as String]) == 1,
          "导出方向归一化为 1（\(name)）")
    let width = Int(size?.width ?? 0)
    let height = Int(size?.height ?? 0)
    let dimsMatch = width > 0
        && Int(ImageDecoder.numberValue(props[kCGImagePropertyPixelWidth as String]) ?? -1) == width
        && Int(ImageDecoder.numberValue(props[kCGImagePropertyPixelHeight as String]) ?? -1) == height
        && Int(ImageDecoder.numberValue(exif[kCGImagePropertyExifPixelXDimension as String] ?? -1) ?? -1) == width
        && Int(ImageDecoder.numberValue(exif[kCGImagePropertyExifPixelYDimension as String] ?? -1) ?? -1) == height
    check(dimsMatch, "导出尺寸元数据与真实像素一致 \(width)×\(height)（\(name)）")

    let sourceItem = MediaItem(url: source, kind: .image, byteCount: 0, modifiedAt: nil)
    if let original = MetadataReader.gpsLocation(for: sourceItem) {
        let exported = MediaItem(url: output, kind: .image, byteCount: 0, modifiedAt: nil)
        if let preserved = MetadataReader.gpsLocation(for: exported) {
            check(abs(original.latitude - preserved.latitude) < 1e-5
                  && abs(original.longitude - preserved.longitude) < 1e-5,
                  "GPS 坐标保留且仍可被地图按钮识别（\(name)）")
        } else {
            check(false, "GPS 坐标保留（\(name)）")
        }
    }
}
