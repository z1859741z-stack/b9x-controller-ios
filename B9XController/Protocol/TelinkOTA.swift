import CoreBluetooth
import Foundation

/// 泰凌芯片固件 OTA（DEEP-DIVE §5.2 `TelinkOTA`）。
///
/// 未验证说明：拆解笔记只确认了成员名（packet / crc16 / storedCRC32 /
/// validate / startRequests / end / maximumImageSize），没有逐字节的
/// 帧结构实测结论。以下分包大小、包头布局、起始/结束命令、CRC-16
/// 多项式全部按最保守的假设实现，仅红魔 8 Pro 通路会走到这里；
/// 真机验证前不要当成已确认的协议。
enum TelinkOTA {
    static var service: CBUUID { CBUUID(string: Secrets.telinkOTAServiceUUID) }
    static var characteristic: CBUUID { CBUUID(string: Secrets.telinkOTACharacteristicUUID) }

    /// 镜像上限。保守值，未验证。
    static let maximumImageSize = 256 * 1024

    /// 每包有效载荷。保守值：默认 ATT MTU 23 字节能稳过，未验证。
    static let packetSize = 20

    /// 每包完整长度（含包头与校验）。
    static let packetLength = packetSize + 4

    static func packetCount(for image: Data) -> Int {
        guard !image.isEmpty else { return 0 }
        return (image.count + packetSize - 1) / packetSize
    }

    /// CRC-16/CCITT-FALSE（poly 0x1021，init 0xFFFF）。多项式未验证。
    static func crc16(_ data: Data) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in data {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1
            }
        }
        return crc
    }

    /// CRC-32/IEEE（zlib 同款），用于镜像整体校验。
    static func storedCRC32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1
            }
        }
        return crc ^ 0xFFFFFFFF
    }

    /// 镜像基础校验：非空、不超上限、CRC32 可算。
    /// 注意：镜像头 magic / 版本字段的校验方式未从拆解笔记恢复，
    /// 这里不做头校验，真机验证时再补。
    static func validate(_ image: Data) -> Bool {
        guard !image.isEmpty, image.count <= maximumImageSize else { return false }
        return storedCRC32(image) != 0
    }

    /// 单包：[序号低字节，序号高字节，载荷（不足补 0xFF），CRC16 低字节，CRC16 高字节]。
    /// 包头布局未验证。
    static func packet(index: Int, chunk: Data) -> Data {
        var out = Data(count: packetLength)
        out[0] = UInt8(index & 0xFF)
        out[1] = UInt8((index >> 8) & 0xFF)
        var payload = chunk
        if payload.count < packetSize {
            payload.append(contentsOf: [UInt8](repeating: 0xFF, count: packetSize - payload.count))
        }
        out.replaceSubrange(2..<(2 + packetSize), with: payload)
        let crc = crc16(Data(out[0..<(2 + packetSize)]))
        out[2 + packetSize] = UInt8(crc & 0xFF)
        out[2 + packetSize + 1] = UInt8((crc >> 8) & 0xFF)
        return out
    }

    /// 镜像切包（按 packetSize 切分，最后一包不足补 0xFF）。
    static func packets(for image: Data) -> [Data] {
        let count = packetCount(for: image)
        return (0..<count).map { index in
            let start = index * packetSize
            let end = min(start + packetSize, image.count)
            return packet(index: index, chunk: image.subdata(in: start..<end))
        }
    }

    /// 开始刷写请求：起始命令（假设布局，未验证）。
    /// [0x01，镜像总长 4 字节小端，CRC32 4 字节小端，包数 2 字节小端]。
    static func startRequests(imageSize: Int, crc32: UInt32) -> [GATTRequest] {
        var payload = Data(count: 11)
        payload[0] = 0x01
        payload[1] = UInt8(imageSize & 0xFF)
        payload[2] = UInt8((imageSize >> 8) & 0xFF)
        payload[3] = UInt8((imageSize >> 16) & 0xFF)
        payload[4] = UInt8((imageSize >> 24) & 0xFF)
        payload[5] = UInt8(crc32 & 0xFF)
        payload[6] = UInt8((crc32 >> 8) & 0xFF)
        payload[7] = UInt8((crc32 >> 16) & 0xFF)
        payload[8] = UInt8((crc32 >> 24) & 0xFF)
        let count = packetCount(for: Data(count: imageSize))
        payload[9] = UInt8(count & 0xFF)
        payload[10] = UInt8((count >> 8) & 0xFF)
        return [GATTRequest(isOTA: true, payload: payload, responseRequired: true)]
    }

    /// 结束刷写请求：提交命令（假设布局，未验证）。
    static func end() -> GATTRequest {
        GATTRequest(isOTA: true, payload: Data([0x02]), responseRequired: true)
    }

    /// 设备回执解析。回执格式未验证：仅识别首字节 0x00 为成功，
    /// 其余一律按失败处理，调用方只记日志、不据此崩溃。
    enum DeviceResult {
        case success
        case failure(Int)
    }

    static func deviceResult(_ data: Data) -> DeviceResult? {
        guard let first = data.first else { return nil }
        if first == 0x00 { return .success }
        return .failure(Int(first))
    }
}
