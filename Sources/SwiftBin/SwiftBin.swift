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
    case invalidLength, invalidOrUnknownEnumValue, invalidUTF8, trailingData
}

public struct BinaryBuffer: ~Copyable {
    internal var pointer: UnsafePointer<UInt8>
    let total: Int
    public let defaultEndianness: Endianness
    public var consumed: Int {
        total - remaining
    }
    internal var remaining: Int
    private let release: (() -> Void)?

    public var isDrained: Bool {
        remaining == 0
    }

    public typealias ReleaseCallback = () -> Void

    private static var emptyPointer: UnsafePointer<UInt8> {
        UnsafePointer(bitPattern: 1)!
    }

    public mutating func withResetOnFailure<T>(_ body: (inout BinaryBuffer) throws -> T) -> T? {
        let originalConsumed = consumed

        do {
            return try body(&self)
        } catch {
            moveUnchecked(by: originalConsumed - consumed)
            return nil
        }
    }

    public init(pointer: UnsafePointer<UInt8>, count: Int, release: ReleaseCallback?) {
        self.init(
            pointer: pointer,
            count: count,
            defaultEndianness: .big,
            release: release
        )
    }

    public init(
        pointer: UnsafePointer<UInt8>,
        count: Int,
        defaultEndianness: Endianness,
        release: ReleaseCallback?
    ) {
        self.pointer = pointer
        self.total = count
        self.remaining = count
        self.defaultEndianness = defaultEndianness
        self.release = release
    }

    public mutating func advance(by length: Int) throws {
        guard length >= 0, remaining >= length else {
            throw BinaryParsingNeedsMoreDataError()
        }

        moveUnchecked(by: length)
    }

    public mutating func skipRemaining() {
        moveUnchecked(by: remaining)
    }

    private mutating func moveUnchecked(by length: Int) {
        pointer += length
        remaining -= length
    }

    public mutating func readInteger<F: FixedWidthInteger>(
        _ type: F.Type = F.self,
        endianness: Endianness? = nil
    ) throws -> F {
        let size = MemoryLayout<F>.size
        if remaining < size {
            throw BinaryParsingNeedsMoreDataError()
        }

        let value = UnsafeRawPointer(pointer).loadUnaligned(as: F.self)
        moveUnchecked(by: size)
        let endianness = endianness ?? defaultEndianness
        return endianness.convertFromStorage(value)
    }

    public mutating func readWithBuffer<T>(
        length: Int,
        allowingTrailingBytes: Bool = false,
        parse: (inout BinaryBuffer) throws -> T
    ) throws -> T {
        guard length >= 0, remaining >= length else {
            throw BinaryParsingNeedsMoreDataError()
        }

        var buffer = BinaryBuffer(
            pointer: pointer,
            count: length,
            defaultEndianness: defaultEndianness,
            release: nil
        )
        let value = try parse(&buffer)
        guard allowingTrailingBytes || buffer.isDrained else {
            throw BinaryParsingError.trailingData
        }

        moveUnchecked(by: length)
        return value
    }

    @inlinable
    public mutating func readLengthPrefixed<
        LengthPrefix: FixedWidthInteger,
        T
    >(
        lengthPrefix: LengthPrefix.Type = UInt32.self,
        allowingTrailingBytes: Bool = false,
        parse: (inout BinaryBuffer) throws -> T
    ) throws -> T {
        let bodySize = try readInteger(LengthPrefix.self)
        guard let length = Int(exactly: bodySize), length >= 0 else {
            throw BinaryParsingError.invalidLength
        }

        return try readWithBuffer(length: length, allowingTrailingBytes: allowingTrailingBytes) { slice in
            return try parse(&slice)
        }
    }

    public mutating func readString(length: Int) throws -> String {
        try readWithBuffer(length: length) { buffer in
            try buffer.getString()
        }
    }

    public mutating func withConsumedBuffer<T>(
        parse: (UnsafeBufferPointer<UInt8>) throws -> T
    ) rethrows -> T {
        let value = try parse(UnsafeBufferPointer(start: pointer, count: remaining))
        moveUnchecked(by: remaining)
        return value
    }

    public mutating func getString() throws -> String {
        try withConsumedBuffer { buffer in
            guard let string = String(bytes: buffer, encoding: .utf8) else {
                throw BinaryParsingError.invalidUTF8
            }

            return string
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

    @inlinable
    internal func convertFromStorage<F: FixedWidthInteger>(_ integer: F) -> F {
        switch self {
        case .little: return F(littleEndian: integer)
        case .big: return F(bigEndian: integer)
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
        var data = Data()
        var writer = BinaryWriter(defaultEndianness: defaultEndianness) { buffer in
            guard !buffer.isEmpty else { return }
            let buffer = buffer.bindMemory(to: UInt8.self)
            data.append(buffer.baseAddress!, count: buffer.count)
        }
        try write(&writer)
        guard let payloadSize = LengthPrefix(exactly: data.count) else {
            throw BinarySerializationError.lengthDoesNotFit
        }

        try writeInteger(payloadSize)
        if !data.isEmpty {
            try data.withUnsafeBytes { buffer in
                try self.write(buffer)
            }
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
        guard size > 0 else { return }
        try write(UnsafeRawBufferPointer(start: pointer, count: size))
    }

    @inlinable
    public mutating func writeString(_ string: String) throws {
        let bytes = Array(string.utf8)
        try bytes.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            try writeBytes(baseAddress, size: buffer.count)
        }
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
        guard length >= 0 else {
            throw BinaryParsingError.invalidLength
        }

        guard buffer.remaining >= length else {
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
        guard count >= 0 else {
            throw BinaryParsingError.invalidLength
        }

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
        self = try buffer.readString(length: buffer.remaining)
    }
}

#if canImport(Foundation)
import Foundation

extension Data: BinaryFormatWithLength {
    public var byteSize: Int { count }
    public func serializeWithoutLength(into writer: inout BinaryWriter) throws {
        try withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            try writer.writeBytes(
                baseAddress.assumingMemoryBound(to: UInt8.self),
                size: buffer.count
            )
        }
    }

    public init(consumingWithoutLength buffer: inout BinaryBuffer) throws {
        self = buffer.withConsumedBuffer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return Data()
            }

            return Data(bytes: baseAddress, count: buffer.count)
        }
    }
}

extension BinaryBuffer {
    public static func readContents<T>(
        ofData data: Data,
        parse: (inout BinaryBuffer) throws -> T
    ) rethrows -> T {
        try readContents(
            ofData: data,
            defaultEndianness: .big,
            parse: parse
        )
    }

    public static func readContents<T>(
        ofData data: Data,
        defaultEndianness: Endianness,
        parse: (inout BinaryBuffer) throws -> T
    ) rethrows -> T {
        try data.withUnsafeBytes { buffer in
            let buffer = buffer.bindMemory(to: UInt8.self)
            var binary = BinaryBuffer(
                pointer: buffer.baseAddress ?? BinaryBuffer.emptyPointer,
                count: buffer.count,
                defaultEndianness: defaultEndianness,
                release: nil
            )

            return try parse(&binary)
        }
    }
}

extension BinaryFormatProtocol {
    public init(parseFrom data: Data, endianness: Endianness = .big) throws {
        self = try BinaryBuffer.readContents(ofData: data, defaultEndianness: endianness) { buffer in
            let value = try Self(consuming: &buffer)
            guard buffer.isDrained else {
                throw BinaryParsingError.trailingData
            }

            return value
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
