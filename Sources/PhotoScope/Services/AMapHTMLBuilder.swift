import Foundation

/// 高德地图 JS API 2.0 页面生成。
///
/// 合规说明：
/// - 底图使用高德地图（合规白名单内），不使用 Apple Maps / Google Maps / OSM 等境外底图。
/// - 本程序为独立分发的 macOS 应用，无法使用 WorkBuddy 的密钥代理，属于「非默认场景」：
///   源码中不内置任何可用密钥，SDK URL 的 `key` 参数只允许来自使用者在运行期输入。
///   源码中的显式占位符为：
///   key="Please apply for your own key at the 高德开放平台 Open Platform and replace this placeholder"
/// - EXIF 的 WGS-84 坐标由 CoordinateConverter 转为 GCJ-02 后再标注（高德使用 GCJ-02）。
enum AMapHTMLBuilder {

    /// 显式占位符：仅用于提示与判定，绝不作为可用 Key 参与网络请求。
    static let placeholderKey =
        "Please apply for your own key at the 高德开放平台 Open Platform and replace this placeholder"

    /// WKWebView 页面的 origin。若高德 Key 启用了域名白名单，需放行此 host（或留空白名单）。
    static let baseURL = URL(string: "https://photoscope.local/")!

    static func isValidKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != placeholderKey
    }

    /// 在线地图页面。securityCode 可为空（仅 2021-12-02 之前申请的老 Key 支持省略）。
    static func onlineHTML(key: String, securityCode: String,
                           latitude: Double, longitude: Double,
                           fileName: String) -> String {
        let encodedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
        // 安全密钥必须在引入 JS API 之前设置
        let securityLine: String
        if securityCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            securityLine = "// 未填写安全密钥：仅 2021-12-02 之前申请的老 Key 可省略"
        } else {
            securityLine = "window._AMapSecurityConfig = { securityJsCode: \(javaScriptString(securityCode)) };"
        }

        let latText = String(format: "%.7f", latitude)
        let lngText = String(format: "%.7f", longitude)
        let nameLiteral = javaScriptString(fileName)
        let tipHTML = javaScriptString(
            "<div class='tip'><b>" + htmlEscaped(fileName) + "</b><br><span>拍摄位置 · GCJ-02</span></div>"
        )

        return """
        <!DOCTYPE html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          html,body{margin:0;padding:0;width:100%;height:100%;overflow:hidden}
          #map{width:100%;height:100%}
          .tip{font:13px/1.5 -apple-system,"PingFang SC",sans-serif;padding:2px 6px;white-space:nowrap}
          .tip span{font-size:11px;color:#888}
          .err{font:13px/1.6 -apple-system,"PingFang SC",sans-serif;color:#b3261e;padding:28px;max-width:600px}
        </style>
        <script>\(securityLine)</script>
        <script>
          window.__amapReady = false;
          // 回调声明必须位于引入 JS API 之前
          window.onAMapLoaded = function () {
            window.__amapReady = true;
            try {
              if (typeof AMap === 'undefined') { throw new Error('AMap 对象未生成'); }
              var center = [\(lngText), \(latText)];
              var map = new AMap.Map('map', { zoom: 15, center: center, viewMode: '2D' });
              var marker = new AMap.Marker({ position: center, title: \(nameLiteral) });
              map.add(marker);
              var info = new AMap.InfoWindow({
                content: \(tipHTML), anchor: 'bottom-center', offset: new AMap.Pixel(0, -6)
              });
              info.open(map, center);
              marker.on('click', function () { info.open(map, center); });
            } catch (e) {
              document.getElementById('map').innerHTML =
                '<div class="err">地图初始化失败：' + e.message + '</div>';
            }
          };
          // Key 无效 / 网络不通时 callback 不会触发，给出明确指引而不是空白地图
          setTimeout(function () {
            if (!window.__amapReady) {
              document.getElementById('map').innerHTML =
                '<div class="err"><b>高德地图 SDK 未加载完成</b><br>' +
                '请检查：网络是否可用；Key 的服务平台是否为「Web端 (JS API)」；' +
                '2021-12-02 之后申请的 Key 是否同时填写了安全密钥；' +
                'Key 的域名白名单是否放行 photoscope.local（或留空白名单）。</div>';
            }
          }, 12000);
        </script>
        <script src="https://webapi.amap.com/maps?v=2.0&key=\(encodedKey)&callback=onAMapLoaded"
                charset="utf-8"></script>
        </head><body><div id="map"></div></body></html>
        """
    }

    /// 未配置 Key 时的离线兜底：仍然清楚呈现坐标与申请步骤，不出现空白地图。
    static func offlineHTML(wgsLatitude: Double, wgsLongitude: Double,
                            gcjLatitude: Double, gcjLongitude: Double,
                            fileName: String, source: String) -> String {
        let wgs = String(format: "%.6f°, %.6f°", wgsLatitude, wgsLongitude)
        let gcj = String(format: "%.6f°, %.6f°", gcjLatitude, gcjLongitude)
        return """
        <!DOCTYPE html><html><head><meta charset="utf-8">
        <style>
          :root { color-scheme: light dark; }
          html,body{margin:0;padding:0;width:100%;height:100%;font-family:-apple-system,"PingFang SC",sans-serif}
          body{display:flex;align-items:center;justify-content:center;background:#f5f5f7;color:#1d1d1f}
          @media (prefers-color-scheme: dark){body{background:#1e1e1e;color:#f2f2f7}}
          .card{max-width:600px;padding:26px 32px;border-radius:14px;background:rgba(127,127,127,.10);
                box-shadow:0 1px 8px rgba(0,0,0,.08)}
          h2{margin:0 0 14px;font-size:18px} p{margin:6px 0;font-size:13px;line-height:1.6}
          .mono{font-family:ui-monospace,Menlo,monospace;font-size:12px}
          .small{font-size:12px;opacity:.75} hr{border:none;border-top:1px solid rgba(127,127,127,.35);margin:16px 0}
          .target{width:64px;height:64px;border-radius:50%;border:2px dashed #e4433c;position:relative;margin:0 auto 16px}
          .target::before,.target::after{content:"";position:absolute;background:#e4433c}
          .target::before{left:50%;top:-8px;width:2px;height:80px;transform:translateX(-50%)}
          .target::after{top:50%;left:-8px;height:2px;width:80px;transform:translateY(-50%)}
        </style></head><body>
        <div class="card">
          <div class="target"></div>
          <h2>📍 \(htmlEscaped(fileName))</h2>
          <p class="mono">WGS-84（EXIF）：\(wgs)</p>
          <p class="mono">GCJ-02（高德底图）：\(gcj)</p>
          <p class="small">来源：\(htmlEscaped(source))</p>
          <hr>
          <p><b>底图尚未启用。</b>本程序使用高德地图 JS API 2.0，请在上方填入你已申请的
          「Web端 (JS API)」Key，2021-12-02 之后申请的 Key 还需同时填入安全密钥，然后点击「应用」。</p>
          <p class="small">申请入口：高德开放平台 lbs.amap.com → 控制台 → 应用管理 → 创建新应用 →
          添加 Key（服务平台选「Web端 (JS API)」），同一页面可查看「安全密钥 jscode」。
          若 Key 启用了域名白名单，请放行 <b>photoscope.local</b> 或留空白名单。
          Key 与安全密钥只保存在本机 UserDefaults，不会写入源码或随程序分发。</p>
        </div></body></html>
        """
    }

    // MARK: - 转义

    private static func htmlEscaped(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func javaScriptString(_ string: String) -> String {
        let escaped = string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "</", with: "<\\/")
        return "'" + escaped + "'"
    }
}
