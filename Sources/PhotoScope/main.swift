import AppKit

// PhotoScope 入口。
// 保留命令行自检模式，便于在不启动 UI 的情况下验证扫描 / 解码 / EXIF / 导出逻辑。
let arguments = CommandLine.arguments

if arguments.contains("--selftest") {
    var directory: String?
    if let i = arguments.firstIndex(of: "--dir"), i + 1 < arguments.count {
        directory = arguments[i + 1]
    }
    exit(SelfTest.run(directory: directory))
}

let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.setActivationPolicy(.regular)
application.run()
