public struct BinaryParsingNeedsMoreDataError: Error {}

@attached(member, names: named(init), named(serialize))
@attached(extension, conformances: BinaryFormatProtocol)
public macro BinaryFormat() = #externalMacro(module: "SwiftBinMacros", type: "BinaryFormatMacro")

@attached(member, names: named(init), named(serialize), named(Marker))
@attached(extension, conformances: BinaryEnumProtocol)
public macro BinaryEnum() = #externalMacro(module: "SwiftBinMacros", type: "BinaryEnumMacro")

@attached(member, names: named(init), named(serialize), named(Marker))
@attached(extension, conformances: NonFrozenBinaryEnumProtocol)
public macro OpenBinaryEnum() = #externalMacro(module: "SwiftBinMacros", type: "BinaryEnumMacro")

public enum BinarySerializationError: Error {
    case lengthDoesNotFit
}

public enum BinaryParsingError: Error {
    case invalidOrUnknownEnumValue, invalidUTF8
}

public struct BinaryBuffer: ~Copyable {
    internal var pointer: UnsafePointer<UInt8>
    internal var count: Int
    private let release: (() -> Void)?

    public var isDrained: Bool {
        count == 0
    }

    public typealias ReleaseCallback = () -> Void

    public init(pointer: UnsafePointer<UInt8>, count: Int, release: ReleaseCallback?) {
        self.pointer = pointer
        self.count = count
        self.release = release
    }

    public mutating func advance(by length: Int) {
        pointer += length
        count -= length
    }

    public mutating func readInteger<F: FixedWidthInteger>(_ type: F.Type = F.self) throws -> F {
        let size = MemoryLayout<F>.size
        if count < size {
            throw BinaryParsingNeedsMoreDataError()
        }

        let value = UnsafeRawPointer(pointer).loadUnaligned(as: F.self)
        advance(by: size)
        return value
    }

    public mutating func readWithBuffer<T>(length: Int, parse: (inout BinaryBuffer) throws -> T) throws -> T {
        guard count >= length else {
            throw BinaryParsingNeedsMoreDataError()
        }

        var buffer = BinaryBuffer(pointer: pointer, count: length, release: nil)
        let value = try parse(&buffer)
        advance(by: length)
        return value
    }

    @inlinable
    public mutating func readLengthPrefixed<
        LengthPrefix: FixedWidthInteger,
        T
    >(
        lengthPrefix: LengthPrefix.Type = UInt32.self,
        parse: (inout BinaryBuffer) throws -> T
    ) throws -> T {
        let bodySize = try readInteger(LengthPrefix.self)
        return try readWithBuffer(length: Int(bodySize)) { slice in
            return try parse(&slice)
        }
    }

    public mutating func readString(length: Int) throws -> String {
        try readWithBuffer(length: length) { buffer in
            buffer.getString()
        }
    }

    public mutating func withConsumedBuffer<T>(
        parse: (UnsafeBufferPointer<UInt8>) throws -> T
    ) rethrows -> T {
        let value = try parse(UnsafeBufferPointer(start: pointer, count: count))
        advance(by: count)
        return value
    }

    public mutating func getString() -> String {
        withConsumedBuffer { buffer in
            String(decoding: buffer, as: UTF8.self)
        }
    }

    deinit { release?() }
}

public enum Endianness {
    case little, big

    @inlinable
    internal func convert<F: FixedWidthInteger>(_ integer: F) -> F {
        switch self {
        case .little: return integer.littleEndian
        case .big: return integer.bigEndian
        }
    }
}

public struct BinaryWriter: ~Copyable {
    public typealias WriteCallback = (UnsafeRawBufferPointer) throws -> Void

    public var defaultEndianness: Endianness

    @usableFromInline
    internal let write: WriteCallback

    public init(defaultEndianness: Endianness, write: @escaping WriteCallback) {
        self.defaultEndianness = defaultEndianness
        self.write = write
    }

    @inlinable
    public mutating func writeInteger<F: FixedWidthInteger>(_ integer: F, endianness: Endianness? = nil) throws {
        let endianness = endianness ?? defaultEndianness
        let converted = endianness.convert(integer)
        try withUnsafeBytes(of: converted, write)
    }

    @inlinable
    public mutating func writeLengthPrefixed<
        LengthPrefix: FixedWidthInteger
    >(
        lengthPrefix: LengthPrefix.Type = UInt32.self,
        write: (inout BinaryWriter) throws -> Void
    ) throws {
        let prefixSize = MemoryLayout<LengthPrefix>.size
        var data = Data(repeating: 0x00, count: prefixSize)
        var writer = BinaryWriter(defaultEndianness: defaultEndianness) { buffer in
            let buffer = buffer.bindMemory(to: UInt8.self)
            data.append(buffer.baseAddress!, count: buffer.count)
        }
        try write(&writer)
        try data.withUnsafeMutableBytes { buffer in
            let payloadSize = LengthPrefix(buffer.count - prefixSize)
            buffer.baseAddress!.assumingMemoryBound(to: LengthPrefix.self).pointee = payloadSize
            try self.write(UnsafeRawBufferPointer(buffer))
        }
    }

    @inlinable
    public mutating func writeLengthPrefixed<
        LengthPrefix: FixedWidthInteger,
        Value: BinaryFormatProtocol
    >(
        lengthPrefix: LengthPrefix.Type = UInt32.self,
        value: Value
    ) throws {
        try writeLengthPrefixed(lengthPrefix: LengthPrefix.self) { writer in
            try value.serialize(into: &writer)
        }
    }

    @inlinable
    public mutating func writeBytes(_ pointer: UnsafePointer<UInt8>, size: Int) throws {
        try write(UnsafeRawBufferPointer(start: pointer, count: size))
    }

    @inlinable
    public mutating func writeString(_ string: String) throws {
        try writeBytes(string, size: string.utf8.count)
    }
}

public enum BinaryParsingResult<T> {
    case parsed(T)
    case needsMoreData

    public func map<N>(_ map: (T) -> N) -> BinaryParsingResult<N> {
        switch self {
        case .parsed(let value): return .parsed(map(value))
        case .needsMoreData: return .needsMoreData
        }
    }
}

public protocol BinaryFormatProtocol {
    init(consuming buffer: inout BinaryBuffer) throws
    func serialize(into writer: inout BinaryWriter) throws
}

public protocol BinaryEnumProtocol: BinaryFormatProtocol {
//    associatedtype Marker: RawRepresentable where Marker.RawValue: FixedWidthInteger
}

public protocol NonFrozenBinaryEnumProtocol: BinaryEnumProtocol {
    static var unknown: Self { get }
}

public protocol BinaryFormatWithLength: BinaryFormatProtocol {
    var byteSize: Int { get }

    init(consumingWithoutLength buffer: inout BinaryBuffer) throws
    func serializeWithoutLength(into writer: inout BinaryWriter) throws
}

extension BinaryFormatWithLength {
    public init(consuming buffer: inout BinaryBuffer) throws {
        let length = try Int(buffer.readInteger(Int.self))
        guard buffer.count >= length else {
            throw BinaryParsingNeedsMoreDataError()
        }

        self = try buffer.readWithBuffer(length: length) { buffer in
            try Self(consumingWithoutLength: &buffer)
        }
    }

    public func serialize(into writer: inout BinaryWriter) throws {
        try writer.writeInteger(byteSize)
        try serializeWithoutLength(into: &writer)
    }
}

extension FixedWidthInteger where Self: BinaryFormatProtocol {
    public func serialize(into writer: inout BinaryWriter) throws {
        try writer.writeInteger(self)
    }

    public init(consuming buffer: inout BinaryBuffer) throws {
        self = try buffer.readInteger()
    }
}

extension Int: BinaryFormatProtocol {}
extension Int8: BinaryFormatProtocol {}
extension Int16: BinaryFormatProtocol {}
extension Int32: BinaryFormatProtocol {}
extension Int64: BinaryFormatProtocol {}
extension UInt: BinaryFormatProtocol {}
extension UInt8: BinaryFormatProtocol {}
extension UInt16: BinaryFormatProtocol {}
extension UInt32: BinaryFormatProtocol {}
extension UInt64: BinaryFormatProtocol {}

extension RawRepresentable where Self: BinaryFormatProtocol, RawValue: FixedWidthInteger & BinaryFormatProtocol {
    public func serialize(into writer: inout BinaryWriter) throws {
        try writer.writeInteger(rawValue)
    }

    public init(consuming buffer: inout BinaryBuffer) throws {
        let number = try buffer.readInteger(RawValue.self)
        guard let value = Self(rawValue: number) else {
            throw BinaryParsingError.invalidOrUnknownEnumValue
        }

        self = value
    }
}

extension Double: BinaryFormatProtocol {
    public func serialize(into writer: inout BinaryWriter) throws {
        try writer.writeInteger(bitPattern)
    }

    public init(consuming buffer: inout BinaryBuffer) throws {
        try self.init(bitPattern: UInt64(consuming: &buffer))
    }
}

extension Float: BinaryFormatProtocol {
    public func serialize(into writer: inout BinaryWriter) throws {
        try writer.writeInteger(bitPattern)
    }

    public init(consuming buffer: inout BinaryBuffer) throws {
        try self.init(bitPattern: UInt32(consuming: &buffer))
    }
}

extension Array: BinaryFormatProtocol where Element: BinaryFormatProtocol {
    public init(consuming buffer: inout BinaryBuffer) throws {
        let count: Int = try buffer.readInteger()
        var elements = [Element]()
        for _ in 0..<count {
            elements.append(try Element(consuming: &buffer))
        }
        self = elements
    }

    public func serialize(into writer: inout BinaryWriter) throws {
        try writer.writeInteger(count)
        for element in self {
            try element.serialize(into: &writer)
        }
    }
}

extension String: BinaryFormatWithLength {
    public var byteSize: Int { utf8.count }
    public func serializeWithoutLength(into writer: inout BinaryWriter) throws {
        try writer.writeString(self)
    }

    public init(consumingWithoutLength buffer: inout BinaryBuffer) throws {
        self = try buffer.readString(length: buffer.count)
    }
}

#if canImport(Foundation)
import Foundation

extension Data: BinaryFormatWithLength {
    public var byteSize: Int { count }
    public func serializeWithoutLength(into writer: inout BinaryWriter) throws {
        try withUnsafeBytes { buffer in
            try writer.writeBytes(
                buffer.baseAddress!.assumingMemoryBound(to: UInt8.self),
                size: buffer.count
            )
        }
    }

    public init(consumingWithoutLength buffer: inout BinaryBuffer) throws {
        self = buffer.withConsumedBuffer { buffer in
            Data(bytes: buffer.baseAddress!, count: buffer.count)
        }
    }
}

extension BinaryBuffer {
    public static func readContents<T>(
        ofData data: Data,
        parse: (inout BinaryBuffer) throws -> T
    ) rethrows -> T {
        try data.withUnsafeBytes { buffer in
            let buffer = buffer.bindMemory(to: UInt8.self)
            var binary = BinaryBuffer(
                pointer: buffer.baseAddress!,
                count: buffer.count,
                release: nil
            )

            return try parse(&binary)
        }
    }
}

extension BinaryFormatProtocol {
    public init(parseFrom data: Data) throws {
        self = try BinaryBuffer.readContents(ofData: data) { buffer in
            try Self(consuming: &buffer)
        }
    }

    public func writeData() throws -> Data {
        var data = Data()
        data.reserveCapacity(4096)
        try write(into: &data)
        return data
    }

    public func write(into data: inout Data) throws {
        var writeBuffer = data
        var writer = BinaryWriter(
            defaultEndianness: .big
        ) { dataToWrite in
            writeBuffer.append(dataToWrite.bindMemory(to: UInt8.self))
        }
        try serialize(into: &writer)
    
        data = writeBuffer
    }
}
#endif