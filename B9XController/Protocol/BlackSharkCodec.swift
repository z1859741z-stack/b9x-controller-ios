import CoreBluetooth
import Foundation
import UIKit

/// 黑鲨传输与编解码脚手架（DEEP-DIVE §1.1 `BlackSharkCodec`）。
///
/// 未验证，无硬件可测：拆解笔记只确认了服务 UUID（归属为推断），
/// 没有任何帧字节实测结论。以下所有帧结构（握手、
/// LCD 上传）均按最合理的假设实现，仅作占位；失败时只记日志、
/// 不崩溃、不乱发。真机验证前不要当成已确认的协议。
enum BlackSharkCodec {
    /// 黑鲨服务（归属未验证）。
    static var serviceUUID: CBUUID { CBUUID(string: Secrets.blackSharkServiceUUID) }
    /// 黑鲨第二服务（归属未验证）。
    static var serviceUUID2: CBUUID { CBUUID(string: Secrets.blackSharkServiceUUID2) }

    /// LCD 屏默认尺寸（假设，未验证）：240×320。
    static let lcdWidth = 240
    static let lcdHeight = 320

    /// 握手帧（假设，未验证）。
    static func handshake() -> Data {
        Data([0xA5, 0x01])
    }

    /// 图片转 RGB565（大端，每像素 2 字节）。转换本身是确定的；
    /// 目标尺寸与上传协议未验证。
    static func rgb565(from image: UIImage, width: Int = lcdWidth, height: Int = lcdHeight) -> Data? {
        guard let cgImage = image.cgImage else { return nil }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &rgba,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        var out = Data(capacity: width * height * 2)
        for i in 0..<(width * height) {
            let r = UInt16(rgba[i * 4]) >> 3
            let g = UInt16(rgba[i * 4 + 1]) >> 2
            let b = UInt16(rgba[i * 4 + 2]) >> 3
            let value = (r << 11) | (g << 5) | b
            out.append(UInt8((value >> 8) & 0xFF))
            out.append(UInt8(value & 0xFF))
        }
        return out
    }

    /// LCD 上传分包（假设，未验证）：
    /// 每包 [0xA6，分包序号，总包数，RGB565 载荷 ≤16 字节]。
    static func lcdUploadPackets(rgb565: Data, width: Int = lcdWidth, height: Int = lcdHeight) -> [Data] {
        guard !rgb565.isEmpty else { return [] }
        let chunkSize = 16
        let total = (rgb565.count + chunkSize - 1) / chunkSize
        return (0..<total).map { index in
            let start = index * chunkSize
            let end = min(start + chunkSize, rgb565.count)
            var packet = Data([0xA6, UInt8(index & 0xFF), UInt8(total & 0xFF)])
            packet.append(rgb565.subdata(in: start..<end))
            return packet
        }
    }

    /// 遥测解析：帧布局未知，无法解析，返回 nil（未验证）。
    struct BlackSharkTelemetry {
        var temperature: Double?
        var speed: Int?
        var batteryLevel: Int?
    }

    static func decode(_ data: Data) -> BlackSharkTelemetry? {
        // 未验证：黑鲨状态帧结构未从拆解笔记恢复，不猜字段。
        nil
    }
}
