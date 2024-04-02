public struct BinaryParsingNeedsMoreDataError: Error {}

@attached(member, names: named(init), named(serialize))
@attached(extension, conformances: BinaryFormatProtocol)
public macro BinaryFormat() = #externalMacro(module: "SwiftBinMacros", type: "BinaryFormatMacro")

@attached(member, names: named(init), named(serialize), named(Marker))
@attached(extension, conformances: BinaryEnumProtocol)
public macro BinaryEnum() = #externalMacro(module: "SwiftBinMacros", type: "BinaryEnumMacro")

@attached(member, names: named(init), named(serialize), named(Marker))
@attached(extension, conformances: BinaryNonFrozenEnumProtocol)
public macro OpenBinaryEnum() = #externalMacro(module: "SwiftBinMacros", type: "BinaryEnumMacro")

public enum BinarySerializationError: Error {
    case lengthDoesNotFit
}

public enum BinaryParsingError: Error {
    case invalidOrUnknownEnumValue
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
        data.withUnsafeMutableBytes { buffer in
            let payloadSize = LengthPrefix(buffer.count - prefixSize)
            buffer.baseAddress!.assumingMemoryBound(to: LengthPrefix.self).pointee = payloadSize
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

public protocol BinaryNonFrozenEnumProtocol: BinaryEnumProtocol {
    static var unknown: Self { get }
}

public protocol BinaryFormatWithLength: BinaryFormatProtocol {
    var byteSize: Int { get }
}

@propertyWrapper public struct LengthEncoded<Length: FixedWidthInteger, Value: BinaryFormatWithLength>: BinaryFormatProtocol {
    public var wrappedValue: Value
    public var projectedValue: Self { self }
    public init(wrappedValue: Value) {
        self.wrappedValue = wrappedValue
    }

    public init(consuming buffer: inout BinaryBuffer) throws {
        let length = try Int(buffer.readInteger(Length.self))
        guard buffer.count >= length else {
            throw BinaryParsingNeedsMoreDataError()
        }

        self.wrappedValue = try buffer.readWithBuffer(length: length) { buffer in
            try Value(consuming: &buffer)
        }
    }

    public func serialize(into writer: inout BinaryWriter) throws {
        let byteSize = wrappedValue.byteSize

        guard byteSize <= Length.max else {
            throw BinarySerializationError.lengthDoesNotFit
        }

        try writer.writeInteger(Length(byteSize))
        try wrappedValue.serialize(into: &writer)
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

import Foundation

extension Data: BinaryFormatWithLength {
    public var byteSize: Int { count }
    public func serialize(into writer: inout BinaryWriter) throws {
        try withUnsafeBytes { buffer in
            try writer.writeBytes(
                buffer.baseAddress!.assumingMemoryBound(to: UInt8.self),
                size: buffer.count
            )
        }
    }

    public init(consuming buffer: inout BinaryBuffer) throws {
        self = buffer.withConsumedBuffer { buffer in
            Data(bytes: buffer.baseAddress!, count: buffer.count)
        }
    }
}
