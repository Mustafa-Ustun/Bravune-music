import Foundation

enum FlacPicture {
    private static let maxBlockLength = 32 * 1024 * 1024
    private static let frontCover: UInt32 = 3

    static func extract(from url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let magic = try? handle.read(upToCount: 4), magic == Data("fLaC".utf8) else { return nil }
        var fallback: Data?
        while let header = try? handle.read(upToCount: 4), header.count == 4 {
            let isLast = header[header.startIndex] & 0x80 != 0
            let type = header[header.startIndex] & 0x7F
            let length = header.dropFirst().reduce(0) { ($0 << 8) | Int($1) }
            guard length <= maxBlockLength else { return fallback }
            if type == 6 {
                guard let block = try? handle.read(upToCount: length), block.count == length else { return fallback }
                if let picture = parsePicture(block) {
                    if picture.type == frontCover { return picture.data }
                    fallback = fallback ?? picture.data
                }
            } else {
                guard let position = try? handle.offset(), (try? handle.seek(toOffset: position + UInt64(length))) != nil else {
                    return fallback
                }
            }
            if isLast { break }
        }
        return fallback
    }

    static func parsePicture(_ block: Data) -> (type: UInt32, data: Data)? {
        let bytes = [UInt8](block)
        var offset = 0

        func readUInt32() -> Int? {
            guard offset + 4 <= bytes.count else { return nil }
            let value = bytes[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
            offset += 4
            return value
        }

        guard let type = readUInt32(),
              let mimeLength = readUInt32(), offset + mimeLength <= bytes.count else { return nil }
        offset += mimeLength
        guard let descriptionLength = readUInt32(), offset + descriptionLength <= bytes.count else { return nil }
        offset += descriptionLength
        guard offset + 16 <= bytes.count else { return nil }
        offset += 16
        guard let dataLength = readUInt32(), dataLength > 0, offset + dataLength <= bytes.count else { return nil }
        return (UInt32(type), Data(bytes[offset..<offset + dataLength]))
    }
}
