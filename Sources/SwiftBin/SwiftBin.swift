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

    public typealias ReleaseCallback = () -> Void

    public init(pointer: UnsafePointer<UInt8>, count: Int, release: ReleaseCallback?) {
        self.pointer = pointer
        self.count = count
        self.release = release
    }

    private mutating func advance(by length: Int) {
        pointer += length
        count -= length
    }

    internal mutating func readInteger<F: FixedWidthInteger>(_ type: F.Type = F.self) throws -> F {
        let size = MemoryLayout<F>.size
        if count < size {
            throw BinaryParsingNeedsMoreDataError()
        }

        let value = pointer.withMemoryRebound(to: F.self, capacity: 1) { $0.pointee }
        advance(by: size)
        return value
    }

    internal mutating func readWithBuffer<T>(length: Int, parse: (inout BinaryBuffer) throws -> T) throws -> T {
        guard count >= length else {
            throw BinaryParsingNeedsMoreDataError()
        }

        var buffer = BinaryBuffer(pointer: pointer, count: length, release: nil)
        let value = try parse(&buffer)
        advance(by: length)
        return value
    }

    internal mutating func readString(length: Int) throws -> String {
        try readWithBuffer(length: length) { buffer in
            buffer.getString()
        }
    }

    internal mutating func withConsumedBuffer<T>(
        parse: (UnsafeBufferPointer<UInt8>) throws -> T
    ) rethrows -> T {
        let value = try parse(UnsafeBufferPointer(start: pointer, count: count))
        advance(by: count)
        return value
    }

    internal mutating func getString() -> String {
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