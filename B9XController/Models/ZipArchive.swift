import Compression
import Foundation

/// 最小 ZIP 读写（不引第三方库；对标原包用的 ZIPFoundation 0.9.20 的子集）。
///
/// 读：定位中央目录（EOCD），支持 stored（0）与 deflate（8，系统 Compression 框架解压）。
/// 写：仅 stored（供以后备份导出用），不压缩。
/// 解析失败一律抛 `ZipError`，错误信息是人话，可直接显示给用户。
/// 解出的内容一律用中央目录里的 CRC32 校验，解错了直接报损坏，不静默放行。
enum ZipError: LocalizedError {
    case emptyData
    case notAZipFile
    case truncated
    case unsupportedCompressionMethod(UInt16)
    case unsupportedFeature(String)
    case corruptEntry(String)
    case decompressionFailed(String)
    case entryNotFound(String)
    case tooManyEntries(Int)

    var errorDescription: String? {
        switch self {
        case .emptyData:
            return "文件是空的，读不到任何内容。"
        case .notAZipFile:
            return "这不是一个 ZIP 文件（找不到 ZIP 结束标记）。"
        case .truncated:
            return "ZIP 文件不完整，可能下载或传输时被截断了。"
        case .unsupportedCompressionMethod(let method):
            return "不支持的压缩方式（方法 \(method)），只支持不压缩和 deflate。"
        case .unsupportedFeature(let what):
            return "ZIP 里用了不支持的特性：\(what)。"
        case .corruptEntry(let name):
            return "ZIP 里的文件“\(name)”已损坏，解不出来。"
        case .decompressionFailed(let name):
            return "解压“\(name)”失败，文件可能已损坏。"
        case .entryNotFound(let name):
            return "ZIP 里找不到“\(name)”这个文件。"
        case .tooManyEntries(let count):
            return "ZIP 里的文件太多（\(count) 个），拒绝解包以防异常包。"
        }
    }
}

/// ZIP 中央目录里的一项。
struct ZipEntry: Equatable {
    let name: String
    let method: UInt16
    let crc32: UInt32
    let compressedSize: UInt64
    let uncompressedSize: UInt64
    let localHeaderOffset: UInt64
    let isDirectory: Bool

    var isStored: Bool { method == 0 }
    var isDeflated: Bool { method == 8 }
}

struct ZipArchive {
    /// 单个包里最多允许的条目数（防 zip 炸弹式的异常包）。
    static let maxEntries = 4096
    /// 解包后单个文件最大允许字节数（防 zip 炸弹）。
    static let maxEntrySize: UInt64 = 200 * 1024 * 1024

    let entries: [ZipEntry]
    private let data: Data

    // ------------------------------------------------------------ 读

    init(data: Data) throws {
        guard !data.isEmpty else { throw ZipError.emptyData }
        self.data = data
        self.entries = try Self.parseCentralDirectory(data: data)
    }

    init(url: URL) throws {
        let data = try Data(contentsOf: url)
        try self.init(data: data)
    }

    func entry(named name: String) -> ZipEntry? {
        entries.first { $0.name == name }
    }

    func contains(_ name: String) -> Bool {
        entry(named: name) != nil
    }

    /// 读出某一项的解压后内容（stored 直接取，deflate 用系统 Compression 解压）。
    func read(_ entry: ZipEntry) throws -> Data {
        guard entry.uncompressedSize <= Self.maxEntrySize else {
            throw ZipError.corruptEntry(entry.name)
        }
        // 定位本地文件头：签名 PK\x03\x04 + 固定 26 字节 + 文件名 + 附加字段。
        let offset = Int(entry.localHeaderOffset)
        guard offset + 30 <= data.count,
              data[offset] == 0x50, data[offset + 1] == 0x4B,
              data[offset + 2] == 0x03, data[offset + 3] == 0x04 else {
            throw ZipError.corruptEntry(entry.name)
        }
        let nameLen = Int(Self.u16(data, at: offset + 26))
        let extraLen = Int(Self.u16(data, at: offset + 28))
        let payloadStart = offset + 30 + nameLen + extraLen
        let payloadEnd = payloadStart + Int(entry.compressedSize)
        guard payloadStart <= data.count, payloadEnd <= data.count else {
            throw ZipError.truncated
        }
        let payload = data.subdata(in: payloadStart..<payloadEnd)
        let decoded: Data
        switch entry.method {
        case 0:
            decoded = payload
        case 8:
            decoded = try Self.inflate(payload, expectedSize: Int(entry.uncompressedSize), entryName: entry.name)
        default:
            throw ZipError.unsupportedCompressionMethod(entry.method)
        }
        guard decoded.count == Int(entry.uncompressedSize),
              Self.crc32(decoded) == entry.crc32 else {
            throw ZipError.corruptEntry(entry.name)
        }
        return decoded
    }

    func read(named name: String) throws -> Data {
        guard let entry = entry(named: name) else { throw ZipError.entryNotFound(name) }
        return try read(entry)
    }

    /// 读出全部文件项（跳过目录项）。某一项失败即整体失败并报出该项。
    func readAllFiles() throws -> [String: Data] {
        var result: [String: Data] = [:]
        result.reserveCapacity(entries.count)
        for entry in entries where !entry.isDirectory {
            result[entry.name] = try read(entry)
        }
        return result
    }

    // ------------------------------------------------------------ 中央目录解析

    private static func parseCentralDirectory(data: Data) throws -> [ZipEntry] {
        // EOCD（PK\x05\x06）在文件尾部：先在最后 64KB + 22 字节里找签名。
        let eocdSignature: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
        let searchStart = data.count > 65_557 ? data.count - 65_557 : 0
        var eocdOffset: Int?
        var i = data.count - 22
        while i >= searchStart {
            if data[i] == eocdSignature[0], data[i + 1] == eocdSignature[1],
               data[i + 2] == eocdSignature[2], data[i + 3] == eocdSignature[3] {
                eocdOffset = i
                break
            }
            i -= 1
        }
        guard let eocd = eocdOffset, eocd + 22 <= data.count else {
            throw ZipError.notAZipFile
        }
        let diskEntries = Int(u16(data, at: eocd + 10))
        let totalEntries = Int(u16(data, at: eocd + 8))
        let cdSize = Int(u32(data, at: eocd + 12))
        let cdOffset = Int(u32(data, at: eocd + 16))
        let count = max(diskEntries, totalEntries)
        guard count <= maxEntries else { throw ZipError.tooManyEntries(count) }
        guard cdOffset + cdSize <= data.count else { throw ZipError.truncated }

        var entries: [ZipEntry] = []
        entries.reserveCapacity(count)
        var cursor = cdOffset
        for _ in 0..<count {
            // 中央目录项签名 PK\x01\x02，固定 46 字节。
            guard cursor + 46 <= data.count,
                  data[cursor] == 0x50, data[cursor + 1] == 0x4B,
                  data[cursor + 2] == 0x01, data[cursor + 3] == 0x02 else {
                throw ZipError.truncated
            }
            let flags = u16(data, at: cursor + 8)
            if flags & 0x0001 != 0 {
                throw ZipError.unsupportedFeature("加密 ZIP（需要密码）")
            }
            let method = u16(data, at: cursor + 10)
            let crc = u32(data, at: cursor + 16)
            let compressedSize = UInt64(u32(data, at: cursor + 20))
            let uncompressedSize = UInt64(u32(data, at: cursor + 24))
            let nameLen = Int(u16(data, at: cursor + 28))
            let extraLen = Int(u16(data, at: cursor + 30))
            let commentLen = Int(u16(data, at: cursor + 32))
            let localOffset = UInt64(u32(data, at: cursor + 42))
            guard cursor + 46 + nameLen <= data.count else { throw ZipError.truncated }
            let nameData = data.subdata(in: (cursor + 46)..<(cursor + 46 + nameLen))
            // 文件名按 UTF-8 解，失败时按 Latin-1 兜底（老式 ZIP 常见）。
            let name = String(data: nameData, encoding: .utf8)
                ?? String(nameData.map { Character(UnicodeScalar($0)) })
            entries.append(ZipEntry(
                name: name,
                method: method,
                crc32: crc,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: localOffset,
                isDirectory: name.hasSuffix("/")
            ))
            cursor += 46 + nameLen + extraLen + commentLen
        }
        return entries
    }

    // ------------------------------------------------------------ deflate 解压（系统 Compression）
    //
    // ZIP 里的 deflate 是裸 deflate 流（RFC 1951，无 zlib 包裹），而系统
    // Compression 框架的 COMPRESSION_ZLIB 要的是 zlib 包裹流（RFC 1950）。
    // 做法：在流前补 2 字节合法 zlib 头（0x78 0x01），流后补 4 字节假 Adler32；
    // 用流式 API 解，输出缓冲区恰好是期望大小，解满即收——哪怕结尾的假校验
    // 没被消费也不影响；最后用中央目录里的 CRC32 验算，解错直接报损坏。

    private static func inflate(_ payload: Data, expectedSize: Int, entryName: String) throws -> Data {
        guard expectedSize >= 0 else { throw ZipError.corruptEntry(entryName) }
        if payload.isEmpty {
            guard expectedSize == 0 else { throw ZipError.decompressionFailed(entryName) }
            return Data()
        }
        var input = Data([0x78, 0x01])
        input.append(payload)
        input.append(contentsOf: [0, 0, 0, 0])
        var output = Data(count: expectedSize)
        var stream = compression_stream()
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) != COMPRESSION_STATUS_ERROR else {
            throw ZipError.decompressionFailed(entryName)
        }
        defer { compression_stream_destroy(&stream) }
        var decoded = 0
        input.withUnsafeBytes { inPtr in
            output.withUnsafeMutableBytes { outPtr in
                guard let inBase = inPtr.baseAddress, let outBase = outPtr.baseAddress else { return }
                stream.src_ptr = inBase.assumingMemoryBound(to: UInt8.self)
                stream.src_size = input.count
                stream.dst_ptr = outBase.assumingMemoryBound(to: UInt8.self)
                stream.dst_size = expectedSize
                var status = compression_stream_decode(&stream, 0)
                while status == COMPRESSION_STATUS_OK && stream.src_size > 0 && stream.dst_size > 0 {
                    status = compression_stream_decode(&stream, 0)
                }
                decoded = expectedSize - stream.dst_size
            }
        }
        guard decoded == expectedSize else { throw ZipError.decompressionFailed(entryName) }
        return output
    }

    // ------------------------------------------------------------ 写（仅 stored）

    /// 把若干文件打包成一个 stored（不压缩）ZIP。供以后备份导出用。
    static func writeStored(files: [(name: String, data: Data)]) throws -> Data {
        var out = Data()
        var central: [(name: String, crc: UInt32, size: UInt32, offset: UInt32)] = []
        for file in files {
            guard let nameData = file.name.data(using: .utf8) else {
                throw ZipError.unsupportedFeature("文件名无法用 UTF-8 编码：\(file.name)")
            }
            guard file.data.count <= UInt32.max else {
                throw ZipError.unsupportedFeature("单个文件超过 4GB：\(file.name)")
            }
            let offset = UInt32(out.count)
            let crc = crc32(file.data)
            let size = UInt32(file.data.count)
            // 本地文件头 PK\x03\x04。
            out.append(contentsOf: [0x50, 0x4B, 0x03, 0x04])
            out.append(contentsOf: withBytes(UInt16(20))) // 解压所需版本
            out.append(contentsOf: withBytes(UInt16(0x0800))) // 标志：UTF-8 文件名
            out.append(contentsOf: withBytes(UInt16(0))) // 方法 stored
            out.append(contentsOf: withBytes(UInt16(0))) // 时间
            out.append(contentsOf: withBytes(UInt16(0))) // 日期
            out.append(contentsOf: withBytes(crc))
            out.append(contentsOf: withBytes(size))
            out.append(contentsOf: withBytes(size))
            out.append(contentsOf: withBytes(UInt16(nameData.count)))
            out.append(contentsOf: withBytes(UInt16(0))) // 附加字段长度
            out.append(nameData)
            out.append(file.data)
            central.append((file.name, crc, size, offset))
        }
        let cdOffset = UInt32(out.count)
        for entry in central {
            guard let nameData = entry.name.data(using: .utf8) else { continue }
            out.append(contentsOf: [0x50, 0x4B, 0x01, 0x02])
            out.append(contentsOf: withBytes(UInt16(20))) // 制作版本
            out.append(contentsOf: withBytes(UInt16(20))) // 解压所需版本
            out.append(contentsOf: withBytes(UInt16(0x0800)))
            out.append(contentsOf: withBytes(UInt16(0)))
            out.append(contentsOf: withBytes(UInt16(0)))
            out.append(contentsOf: withBytes(UInt16(0)))
            out.append(contentsOf: withBytes(entry.crc))
            out.append(contentsOf: withBytes(entry.size))
            out.append(contentsOf: withBytes(entry.size))
            out.append(contentsOf: withBytes(UInt16(nameData.count)))
            out.append(contentsOf: withBytes(UInt16(0))) // 附加
            out.append(contentsOf: withBytes(UInt16(0))) // 注释
            out.append(contentsOf: withBytes(UInt16(0))) // 磁盘号
            out.append(contentsOf: withBytes(UInt16(0))) // 内部属性
            out.append(contentsOf: withBytes(UInt32(0))) // 外部属性
            out.append(contentsOf: withBytes(entry.offset))
            out.append(nameData)
        }
        let cdSize = UInt32(out.count) - cdOffset
        // EOCD PK\x05\x06。
        out.append(contentsOf: [0x50, 0x4B, 0x05, 0x06])
        out.append(contentsOf: withBytes(UInt16(0)))
        out.append(contentsOf: withBytes(UInt16(0)))
        out.append(contentsOf: withBytes(UInt16(central.count)))
        out.append(contentsOf: withBytes(UInt16(central.count)))
        out.append(contentsOf: withBytes(cdSize))
        out.append(contentsOf: withBytes(cdOffset))
        out.append(contentsOf: withBytes(UInt16(0)))
        return out
    }

    // ------------------------------------------------------------ 小工具

    private static func u16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func u32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
    }

    private static func withBytes<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian) { Array($0) }
    }

    /// 标准 CRC-32（IEEE 802.3，多项式 0xEDB88320）。
    static func crc32(_ data: Data) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            table[i] = c
        }
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}
