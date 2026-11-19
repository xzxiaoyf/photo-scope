import Foundation

/// 非破坏性旋转：按文件路径记录用户附加的 90° 旋转（顺时针为正）。
///
/// 为什么不直接改文件：
///  - RAW / HEIC / 视频无法通用地「写回方向」，改写原文件风险高且不可逆；
///  - 覆盖记录只存在本机 UserDefaults，随时可撤销；
///  - 大图显示、缩略图、JPG 导出三条链路在 ImageDecoder 中统一叠加，
///    因此「另存为 JPG」会得到与屏幕一致的朝向。
enum RotationStore {

    private static let defaultsKey = "PhotoScope.rotations"

    /// 归一化到 0…3（0 = 原始方向，1 = 顺时针 90°，2 = 180°，3 = 逆时针 90°）。
    static func normalized(_ turns: Int) -> Int {
        ((turns % 4) + 4) % 4
    }

    private static var storage: [String: Int] {
        (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Int]) ?? [:]
    }

    private static func path(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    static func quarterTurns(for url: URL) -> Int {
        guard let value = storage[path(url)] else { return 0 }
        return normalized(value)
    }

    static func degrees(for url: URL) -> Int {
        quarterTurns(for: url) * 90
    }

    @discardableResult
    static func add(_ delta: Int, for url: URL) -> Int {
        var map = storage
        let next = normalized(quarterTurns(for: url) + delta)
        if next == 0 {
            map.removeValue(forKey: path(url))
        } else {
            map[path(url)] = next
        }
        save(map)
        return next
    }

    static func reset(for url: URL) {
        var map = storage
        map.removeValue(forKey: path(url))
        save(map)
    }

    /// 文件被移动/删除后清掉残留记录，避免路径复用时出现幽灵旋转。
    static func purge(_ urls: [URL]) {
        var map = storage
        for url in urls { map.removeValue(forKey: path(url)) }
        save(map)
    }

    private static func save(_ map: [String: Int]) {
        // 全部恢复原始方向时删掉整个键，不在偏好里留空字典
        if map.isEmpty {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        } else {
            UserDefaults.standard.set(map, forKey: defaultsKey)
        }
    }
}
