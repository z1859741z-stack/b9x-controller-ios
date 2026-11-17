import CoreBluetooth
import Foundation

/// 红魔传输与编解码脚手架（DEEP-DIVE §1.1 `RedMagicCodec`）。
///
/// 未验证，无硬件可测：拆解笔记只确认了服务组 UUID（归属为推断），
/// 没有任何帧字节实测结论。以下所有帧结构（握手、
/// 曲线、音频律动、魔方灯效）均按最合理的假设实现，仅作占位；
/// 失败时只记日志、不崩溃、不乱发。真机验证前不要当成已确认的协议。
enum RedMagicCodec {
    /// 服务组（归属未验证）。
    static var serviceUUIDs: [CBUUID] {
        Secrets.redMagicServiceUUIDs.map { CBUUID(string: $0) }
    }

    /// 假设分工（未验证）：服务组第一项为服务，第二项通知，第三项写。
    static var serviceUUID: CBUUID { serviceUUIDs[0] }
    static var notifyUUID: CBUUID { serviceUUIDs[1] }
    static var writeUUID: CBUUID { serviceUUIDs[2] }

    /// 握手帧（假设，未验证）。
    static func handshake() -> Data {
        Data([0xA5, 0x00])
    }

    /// 制冷曲线帧（假设，未验证）：
    /// [0xC2，点数，档位…，checksum8]，档位钳到 1..8。
    static func encodeCoolingCurve(_ levels: [Int]) -> Data {
        let clamped = levels.map { max(1, min($0, 8)) }
        var frame = Data([0xC2, UInt8(clamped.count & 0xFF)])
        frame.append(contentsOf: clamped.map { UInt8($0 & 0xFF) })
        var sum = 0
        for byte in frame { sum += Int(byte) }
        frame.append(UInt8(sum & 0xFF))
        return frame
    }

    /// 音频律动 pattern 帧（假设，未验证）：[0xC3，pattern 索引]。
    static func encodeAudioPattern(_ index: Int) -> Data {
        Data([0xC3, UInt8(max(0, min(index, 255)) & 0xFF)])
    }

    /// 魔方灯效逐帧（假设，未验证）：每像素 0xRRGGBB，
    /// 帧结构 [0xB1，分包序号，总包数，R,G,B…]，每包载荷不超过 16 字节。
    /// 返回分包后的帧数组；像素为空返回空数组。
    static func cubeFrame(pixels: [UInt32]) -> [Data] {
        guard !pixels.isEmpty else { return [] }
        var rgb = Data(capacity: pixels.count * 3)
        for pixel in pixels {
            rgb.append(UInt8((pixel >> 16) & 0xFF))
            rgb.append(UInt8((pixel >> 8) & 0xFF))
            rgb.append(UInt8(pixel & 0xFF))
        }
        let chunkSize = 16
        let total = (rgb.count + chunkSize - 1) / chunkSize
        return (0..<total).map { index in
            let start = index * chunkSize
            let end = min(start + chunkSize, rgb.count)
            var packet = Data([0xB1, UInt8(index & 0xFF), UInt8(total & 0xFF)])
            packet.append(rgb.subdata(in: start..<end))
            return packet
        }
    }

    /// 遥测解析：帧布局未知，无法解析，返回 nil（未验证）。
    struct RedMagicTelemetry {
        var temperature: Double?
        var speed: Int?
        var level: Int?
    }

    static func decode(_ data: Data) -> RedMagicTelemetry? {
        // 未验证：红魔状态帧结构未从拆解笔记恢复，不猜字段。
        nil
    }
}
