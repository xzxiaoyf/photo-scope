import Foundation

/// EXIF GPS 记录的是 WGS-84 坐标；国内合规底图（高德地图等）使用 GCJ-02。
/// 在国内区域必须做偏移转换，否则标注会偏离实际位置数百米。
enum CoordinateConverter {

    private static let pi = 3.1415926535897932384626
    private static let semiMajorAxis = 6378245.0
    private static let eccentricitySquared = 0.00669342162296594323

    static func wgs84ToGCJ02(latitude: Double, longitude: Double) -> (latitude: Double, longitude: Double) {
        guard !outOfChina(latitude: latitude, longitude: longitude) else {
            return (latitude, longitude)
        }
        var deltaLatitude = transformLatitude(x: longitude - 105.0, y: latitude - 35.0)
        var deltaLongitude = transformLongitude(x: longitude - 105.0, y: latitude - 35.0)

        let radianLatitude = latitude / 180.0 * pi
        var magic = sin(radianLatitude)
        magic = 1 - eccentricitySquared * magic * magic
        let sqrtMagic = sqrt(magic)

        deltaLatitude = (deltaLatitude * 180.0) /
            ((semiMajorAxis * (1 - eccentricitySquared)) / (magic * sqrtMagic) * pi)
        deltaLongitude = (deltaLongitude * 180.0) /
            (semiMajorAxis / sqrtMagic * cos(radianLatitude) * pi)

        return (latitude + deltaLatitude, longitude + deltaLongitude)
    }

    private static func outOfChina(latitude: Double, longitude: Double) -> Bool {
        !(longitude > 73.66 && longitude < 135.05 && latitude > 3.86 && latitude < 53.55)
    }

    private static func transformLatitude(x: Double, y: Double) -> Double {
        var result = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(abs(x))
        result += (20.0 * sin(6.0 * x * pi) + 20.0 * sin(2.0 * x * pi)) * 2.0 / 3.0
        result += (20.0 * sin(y * pi) + 40.0 * sin(y / 3.0 * pi)) * 2.0 / 3.0
        result += (160.0 * sin(y / 12.0 * pi) + 320.0 * sin(y * pi / 30.0)) * 2.0 / 3.0
        return result
    }

    private static func transformLongitude(x: Double, y: Double) -> Double {
        var result = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(abs(x))
        result += (20.0 * sin(6.0 * x * pi) + 20.0 * sin(2.0 * x * pi)) * 2.0 / 3.0
        result += (20.0 * sin(x * pi) + 40.0 * sin(x / 3.0 * pi)) * 2.0 / 3.0
        result += (150.0 * sin(x / 12.0 * pi) + 300.0 * sin(x / 30.0 * pi)) * 2.0 / 3.0
        return result
    }
}
