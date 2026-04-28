import Foundation
import SwiftBin
import SwiftBinMacros
import SwiftSyntax
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacrosGenericTestSupport
import Testing

@BinaryFormat
private struct SingleBytePacket: Equatable {
    let byte: UInt8

    init(byte: UInt8) {
        self.byte = byte
    }
}

@BinaryFormat
private struct MultiBytePacket: Equatable {
    let number: UInt16
    let text: String

    init(number: UInt16, text: String) {
        self.number = number
        self.text = text
    }
}

@BinaryFormat
private struct EmptyPacket: Equatable {
    init() {}
}

@BinaryFormat
public struct PublicPacket: Equatable {
    public let byte: UInt8

    public init(byte: UInt8) {
        self.byte = byte
    }
}

@BinaryEnum
private enum TestEvent: Equatable {
    case foreground
    case search(UInt8)
    case send(UInt8, toUserId: UInt8)
}

@OpenBinaryEnum
private enum OpenEvent: Equatable {
    case unknown
    case known(UInt8)
}

@OpenBinaryEnum
private enum OpenEventWithStaticUnknown: Equatable {
    static var unknown: Self { .future }

    case future
    case known(UInt8)
}

private enum RawMarker: UInt8, BinaryFormatProtocol {
    case known = 1
}

private enum ExpectedError: Error {
    case failure
}

@Test
func bufferTracksConsumptionAndReadsIntegers() throws {
    let result = try parseBytes([0x01, 0x12, 0x34, 0xff]) { buffer in
        let initialConsumed = buffer.consumed
        let initiallyDrained = buffer.isDrained
        #expect(initialConsumed == 0)
        #expect(!initiallyDrained)

        let first: UInt8 = try buffer.readInteger()
        let second: UInt16 = try buffer.readInteger()

        #expect(first == 0x01)
        #expect(second == 0x1234)
        let consumedAfterReads = buffer.consumed
        #expect(consumedAfterReads == 3)

        try buffer.advance(by: 1)
        let finallyDrained = buffer.isDrained
        #expect(finallyDrained)
        return (first, second)
    }

    #expect(result.0 == 0x01)
    #expect(result.1 == 0x1234)
}

@Test
func bufferThrowsWhenReadingPastAvailableBytes() throws {
    do {
        _ = try parseBytes([0x01]) { buffer in
            try buffer.readInteger(UInt16.self)
        }
        Issue.record("Expected BinaryParsingNeedsMoreDataError")
    } catch is BinaryParsingNeedsMoreDataError {
    }
}

@Test
func bufferCanReadIsolatedSlices() throws {
    let remainingByte = try parseBytes([0x01, 0x02, 0x03]) { buffer in
        let sliceBytes = try buffer.readWithBuffer(length: 2) { slice in
            slice.withConsumedBuffer { Array($0) }
        }

        #expect(sliceBytes == [0x01, 0x02])
        let consumedAfterSlice = buffer.consumed
        #expect(consumedAfterSlice == 2)

        return try buffer.readInteger(UInt8.self)
    }

    #expect(remainingByte == 0x03)
}

@Test
func bufferReadsLengthPrefixedSlicesUsingBigEndianLengthBytesByDefault() throws {
    let bytes = bigEndianBytes(of: UInt16(3)) + [0x0a, 0x0b, 0x0c, 0xff]

    let payload = try parseBytes(bytes) { buffer in
        let payload = try buffer.readLengthPrefixed(lengthPrefix: UInt16.self) { slice in
            slice.withConsumedBuffer { Array($0) }
        }

        let consumedAfterPayload = buffer.consumed
        #expect(consumedAfterPayload == 5)
        return payload
    }

    #expect(payload == [0x0a, 0x0b, 0x0c])
}

@Test
func bufferRejectsTrailingBytesInStrictSlices() throws {
    do {
        _ = try parseBytes(bigEndianBytes(of: UInt16(2)) + [0x0a, 0x0b]) { buffer in
            try buffer.readLengthPrefixed(lengthPrefix: UInt16.self) { slice in
                try slice.readInteger(UInt8.self)
            }
        }
        Issue.record("Expected trailingData")
    } catch BinaryParsingError.trailingData {
    }
}

@Test
func bufferCanSkipTrailingBytesWhenRequested() throws {
    let value = try parseBytes(bigEndianBytes(of: UInt16(2)) + [0x0a, 0x0b]) { buffer in
        try buffer.readLengthPrefixed(lengthPrefix: UInt16.self, allowingTrailingBytes: true) { slice in
            try slice.readInteger(UInt8.self)
        }
    }

    #expect(value == 0x0a)
}

@Test
func bufferResetsConsumedBytesWhenRequestedBodyFails() throws {
    let values = try parseBytes([0x01, 0x02]) { buffer in
        let first = try buffer.readInteger(UInt8.self)
        let failedValue: UInt8? = buffer.withResetOnFailure { innerBuffer in
            let second = try innerBuffer.readInteger(UInt8.self)
            #expect(second == 0x02)
            throw ExpectedError.failure
        }

        #expect(failedValue == nil)
        let consumedAfterFailure = buffer.consumed
        #expect(consumedAfterFailure == 1)

        let second = try buffer.readInteger(UInt8.self)
        let finallyDrained = buffer.isDrained
        #expect(finallyDrained)
        return [first, second]
    }

    #expect(values == [0x01, 0x02])
}

@Test
func writerSerializesIntegersWithConfiguredEndianness() throws {
    let bigEndianBytes = try writtenBytes(defaultEndianness: .big) { writer in
        try writer.writeInteger(UInt16(0x1234))
    }

    let littleEndianBytes = try writtenBytes(defaultEndianness: .little) { writer in
        try writer.writeInteger(UInt16(0x1234))
    }

    #expect(bigEndianBytes == [0x12, 0x34])
    #expect(littleEndianBytes == [0x34, 0x12])
}

@Test
func writerWritesLengthPrefixesUsingConfiguredEndianness() throws {
    let bigEndianBytes = try writtenBytes(defaultEndianness: .big) { writer in
        try writer.writeLengthPrefixed(lengthPrefix: UInt16.self) { nestedWriter in
            try nestedWriter.writeString("Hi")
        }
    }

    let littleEndianBytes = try writtenBytes(defaultEndianness: .little) { writer in
        try writer.writeLengthPrefixed(lengthPrefix: UInt16.self) { nestedWriter in
            try nestedWriter.writeString("Hi")
        }
    }

    #expect(bigEndianBytes == [0x00, 0x02, 0x48, 0x69])
    #expect(littleEndianBytes == [0x02, 0x00, 0x48, 0x69])
}

@Test
func writerThrowsWhenLengthPrefixCannotRepresentPayloadSize() throws {
    do {
        _ = try writtenBytes { writer in
            try writer.writeLengthPrefixed(lengthPrefix: UInt8.self) { nestedWriter in
                for _ in 0...UInt8.max {
                    try nestedWriter.writeInteger(UInt8(0))
                }
            }
        }
        Issue.record("Expected lengthDoesNotFit")
    } catch BinarySerializationError.lengthDoesNotFit {
    }
}

@Test
func fixedWidthIntegersSerializeAndParseBigEndianByDefault() throws {
    let serialized = try serializedBytes(UInt16(0x1234))
    let parsed = try parseValue(UInt16.self, from: [0x12, 0x34])

    #expect(serialized == [0x12, 0x34])
    #expect(parsed == 0x1234)
}

@Test
func floatingPointValuesSerializeAndParseBigEndianBitPatternsByDefault() throws {
    let float = Float(bitPattern: 0x3f800000)
    let double = Double(bitPattern: 0x3ff0000000000000)

    #expect(try serializedBytes(float) == [0x3f, 0x80, 0x00, 0x00])
    #expect(try serializedBytes(double) == [0x3f, 0xf0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
    #expect(try parseValue(Float.self, from: [0x3f, 0x80, 0x00, 0x00]) == 1.0)
    #expect(try parseValue(Double.self, from: [0x3f, 0xf0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]) == 1.0)
}

@Test
func arraysSerializeAndParseBigEndianCountByDefault() throws {
    let serialized = try serializedBytes([UInt8(0x01), UInt8(0x02), UInt8(0x03)])
    let parsed = try parseValue([UInt8].self, from: bigEndianBytes(of: Int(3)) + [0x01, 0x02, 0x03])

    #expect(serialized == bigEndianBytes(of: Int(3)) + [0x01, 0x02, 0x03])
    #expect(parsed == [0x01, 0x02, 0x03])
}

@Test
func stringsSerializeAndParseBigEndianLengthByDefault() throws {
    let serialized = try serializedBytes("Hi")
    let parsed = try parseValue(String.self, from: bigEndianBytes(of: Int(2)) + [0x48, 0x69])

    #expect(serialized == bigEndianBytes(of: Int(2)) + [0x48, 0x69])
    #expect(parsed == "Hi")
}

@Test
func stringsRejectInvalidUTF8() throws {
    do {
        _ = try parseValue(String.self, from: bigEndianBytes(of: Int(1)) + [0xff])
        Issue.record("Expected invalidUTF8")
    } catch BinaryParsingError.invalidUTF8 {
    }
}

@Test
func dataSerializesAndParsesBigEndianLengthByDefault() throws {
    let data = Data([0xde, 0xad, 0xbe, 0xef])
    let serialized = try serializedBytes(data)
    let parsed = try parseValue(Data.self, from: bigEndianBytes(of: Int(data.count)) + Array(data))

    #expect(serialized == bigEndianBytes(of: Int(data.count)) + Array(data))
    #expect(parsed == data)
}

@Test
func emptyLengthValuesRoundTrip() throws {
    let emptyData = Data()
    let emptyPacket = EmptyPacket()

    #expect(try serializedBytes("") == bigEndianBytes(of: Int(0)))
    #expect(try serializedBytes(emptyData) == bigEndianBytes(of: Int(0)))
    #expect(try String(parseFrom: Data(bigEndianBytes(of: Int(0)))) == "")
    #expect(try Data(parseFrom: Data(bigEndianBytes(of: Int(0)))) == emptyData)
    #expect(try emptyPacket.writeData().isEmpty)
    #expect(try EmptyPacket(parseFrom: Data()) == emptyPacket)
}

@Test
func negativeLengthsAndCountsThrowInvalidLength() throws {
    do {
        _ = try parseValue(String.self, from: bigEndianBytes(of: Int(-1)))
        Issue.record("Expected invalidLength for string")
    } catch BinaryParsingError.invalidLength {
    }

    do {
        _ = try parseValue([UInt8].self, from: bigEndianBytes(of: Int(-1)))
        Issue.record("Expected invalidLength for array")
    } catch BinaryParsingError.invalidLength {
    }
}

@Test
func explicitlyLittleEndianBuffersRoundTripLittleEndianStorage() throws {
    let bytes = try writtenBytes(defaultEndianness: .little) { writer in
        try UInt16(0x1234).serialize(into: &writer)
        try "Hi".serialize(into: &writer)
    }

    let parsed = try parseBytes(bytes, defaultEndianness: .little) { buffer in
        let number = try UInt16(consuming: &buffer)
        let string = try String(consuming: &buffer)
        return (number, string)
    }

    #expect(bytes == [0x34, 0x12] + littleEndianBytes(of: Int(2)) + [0x48, 0x69])
    #expect(parsed.0 == 0x1234)
    #expect(parsed.1 == "Hi")
}

@Test
func rawRepresentableParsingRejectsUnknownValues() throws {
    do {
        _ = try parseValue(RawMarker.self, from: [0xff])
        Issue.record("Expected invalidOrUnknownEnumValue")
    } catch BinaryParsingError.invalidOrUnknownEnumValue {
    }
}

@Test
func parseFromRejectsTrailingData() throws {
    do {
        _ = try UInt8(parseFrom: Data([0x01, 0x02]))
        Issue.record("Expected trailingData")
    } catch BinaryParsingError.trailingData {
    }
}

@Test
func binaryFormatMacroAddsProtocolConformanceAndSupportsUInt8RoundTrip() throws {
    let packet = SingleBytePacket(byte: 0x2a)
    let conforming: any BinaryFormatProtocol = packet
    let data = try packet.writeData()
    let parsed = try SingleBytePacket(parseFrom: data)

    #expect(data == Data([0x2a]))
    #expect(parsed == packet)
    _ = conforming
}

@Test
func binaryFormatMacroSupportsCanonicalRoundTripForMultiByteValues() throws {
    let packet = MultiBytePacket(number: 0x1234, text: "Hi")
    let data = try packet.writeData()
    let parsed = try MultiBytePacket(parseFrom: data)

    #expect(Array(data) == [0x12, 0x34] + bigEndianBytes(of: Int(2)) + [0x48, 0x69])
    #expect(parsed == packet)
}

@Test
func publicBinaryFormatTypesExposePublicProtocolMethods() throws {
    let packet = PublicPacket(byte: 0x2a)
    let conforming: any BinaryFormatProtocol = packet

    #expect(try packet.writeData() == Data([0x2a]))
    _ = conforming
}

@Test
func binaryEnumMacroAddsConformanceAndSerializesCases() throws {
    let conforming: any BinaryEnumProtocol = TestEvent.foreground
    let foregroundData = try TestEvent.foreground.writeData()
    let searchBytes = try serializedBytes(TestEvent.search(0x2a))
    let sendBytes = try serializedBytes(TestEvent.send(0x01, toUserId: 0x02))

    #expect(foregroundData == Data(bigEndianBytes(of: UInt16(0)) + bigEndianBytes(of: UInt32(0))))
    #expect(searchBytes == [0x00, 0x01] + bigEndianBytes(of: UInt32(1)) + [0x2a])
    #expect(sendBytes == [0x00, 0x02] + bigEndianBytes(of: UInt32(2)) + [0x01, 0x02])
    _ = conforming
}

@Test
func binaryEnumMacroParsesBigEndianMarkerAndLengthBytesByDefault() throws {
    let searchBytes = bigEndianBytes(of: UInt16(1)) + bigEndianBytes(of: UInt32(1)) + [0x2a]
    let sendBytes = bigEndianBytes(of: UInt16(2)) + bigEndianBytes(of: UInt32(2)) + [0x01, 0x02]

    #expect(try parseValue(TestEvent.self, from: searchBytes) == .search(0x2a))
    #expect(try parseValue(TestEvent.self, from: sendBytes) == .send(0x01, toUserId: 0x02))
}

@Test
func openBinaryEnumMapsUnknownMarkersToUnknownCase() throws {
    let conforming: any NonFrozenBinaryEnumProtocol = OpenEvent.unknown
    let bytes = bigEndianBytes(of: UInt16(999)) + bigEndianBytes(of: UInt32(2)) + [0xaa, 0xbb]

    #expect(try parseValue(OpenEvent.self, from: bytes) == .unknown)
    _ = conforming
}

@Test
func openBinaryEnumUsesSelfUnknownInsteadOfMarkerUnknown() throws {
    let bytes = bigEndianBytes(of: UInt16(999)) + bigEndianBytes(of: UInt32(1)) + [0xaa]

    #expect(try parseValue(OpenEventWithStaticUnknown.self, from: bytes) == .future)
}

@Test
func binaryFormatMacroExpansionIncludesGeneratedMembersAndConformance() {
    assertMacroExpansionWithTesting(
        """
        @BinaryFormat
        struct Packet {
            let id: UInt8, flags: UInt8
            static let version: UInt8 = 1
            var name: String
            var ignored: UInt8 {
                0
            }
        }
        """,
        expandedSource: """
        struct Packet {
            let id: UInt8, flags: UInt8
            static let version: UInt8 = 1
            var name: String
            var ignored: UInt8 {
                0
            }

            init(consuming buffer: inout BinaryBuffer) throws {
                self.id = try .init(consuming: &buffer)
                self.flags = try .init(consuming: &buffer)
                self.name = try .init(consuming: &buffer)
            }

            func serialize(into writer: inout BinaryWriter) throws {
                try self.id.serialize(into: &writer)
                try self.flags.serialize(into: &writer)
                try self.name.serialize(into: &writer)
            }
        }

        extension Packet: BinaryFormatProtocol {
        }
        """,
        macroSpecs: [
            "BinaryFormat": MacroSpec(
                type: BinaryFormatMacro.self,
                conformances: [TypeSyntax("BinaryFormatProtocol")]
            )
        ]
    )
}

@Test
func publicBinaryFormatMacroExpansionUsesPublicWitnesses() {
    assertMacroExpansionWithTesting(
        """
        @BinaryFormat
        public struct Packet {
            public let id: UInt8
        }
        """,
        expandedSource: """
        public struct Packet {
            public let id: UInt8

            public init(consuming buffer: inout BinaryBuffer) throws {
                self.id = try .init(consuming: &buffer)
            }

            public func serialize(into writer: inout BinaryWriter) throws {
                try self.id.serialize(into: &writer)
            }
        }

        extension Packet: BinaryFormatProtocol {
        }
        """,
        macroSpecs: [
            "BinaryFormat": MacroSpec(
                type: BinaryFormatMacro.self,
                conformances: [TypeSyntax("BinaryFormatProtocol")]
            )
        ]
    )
}

@Test
func binaryEnumMacroExpansionIncludesGeneratedMarkerMembersAndConformance() {
    assertMacroExpansionWithTesting(
        """
        @BinaryEnum
        enum Event {
            case foreground
            case search(UInt8)
            case send(UInt8, toUserId: UInt8)
        }
        """,
        expandedSource: """
        enum Event {
            case foreground
            case search(UInt8)
            case send(UInt8, toUserId: UInt8)

            enum Marker: UInt16, Hashable, BinaryFormatProtocol {
                case foreground = 0
                case search = 1
                case send = 2
            }

            init(consuming buffer: inout BinaryBuffer) throws {
                let marker = try Marker(consuming: &buffer)
                switch marker {
                    case .foreground:
                self = .foreground
                try buffer.readLengthPrefixed { _ in
                }
                case .search:
                    self = try buffer.readLengthPrefixed { buffer in
                        .search(try .init(consuming: &buffer))
                    }
                case .send:
                    self = try buffer.readLengthPrefixed { buffer in
                        .send(try .init(consuming: &buffer), toUserId: try .init(consuming: &buffer))
                    }
                }
            }

            func serialize(into writer: inout BinaryWriter) throws {
                switch self {
                    case .foreground:
                try Marker.foreground.serialize(into: &writer)
                try writer.writeLengthPrefixed { _ in
                }
                case .search(let c1):
                    try Marker.search.serialize(into: &writer)
                    try writer.writeLengthPrefixed { writer in
                        try c1.serialize(into: &writer)
                    }
                case .send(let c1, let c2):
                    try Marker.send.serialize(into: &writer)
                    try writer.writeLengthPrefixed { writer in
                        try c1.serialize(into: &writer)
                    try c2.serialize(into: &writer)
                    }
                }
            }
        }

        extension Event: BinaryEnumProtocol {
        }
        """,
        macroSpecs: [
            "BinaryEnum": MacroSpec(
                type: BinaryEnumMacro.self,
                conformances: [TypeSyntax("BinaryEnumProtocol")]
            )
        ]
    )
}

@Test
func openBinaryEnumExpansionUsesFallbackUnknownMarkerAndConformance() {
    assertMacroExpansionWithTesting(
        """
        @OpenBinaryEnum
        enum Event {
            case unknown
            case known(UInt8)
        }
        """,
        expandedSource: """
        enum Event {
            case unknown
            case known(UInt8)

            enum Marker: UInt16, Hashable, BinaryFormatProtocol {
                case unknown = 0
                case known = 1
            }

            init(consuming buffer: inout BinaryBuffer) throws {
                let markerValue = try UInt16(consuming: &buffer)
                guard let marker = Marker(rawValue: markerValue) else {
                    try buffer.readLengthPrefixed { payload in
                        payload.skipRemaining()
                    }
                    self = Self.unknown
                    return
                }
                switch marker {
                    case .unknown:
                self = .unknown
                try buffer.readLengthPrefixed { _ in
                }
                case .known:
                    self = try buffer.readLengthPrefixed { buffer in
                        .known(try .init(consuming: &buffer))
                    }
                }
            }

            func serialize(into writer: inout BinaryWriter) throws {
                switch self {
                    case .unknown:
                try Marker.unknown.serialize(into: &writer)
                try writer.writeLengthPrefixed { _ in
                }
                case .known(let c1):
                    try Marker.known.serialize(into: &writer)
                    try writer.writeLengthPrefixed { writer in
                        try c1.serialize(into: &writer)
                    }
                }
            }
        }

        extension Event: NonFrozenBinaryEnumProtocol {
        }
        """,
        macroSpecs: [
            "OpenBinaryEnum": MacroSpec(
                type: BinaryEnumMacro.self,
                conformances: [TypeSyntax("NonFrozenBinaryEnumProtocol")]
            )
        ]
    )
}

private func parseBytes<T>(
    _ bytes: [UInt8],
    defaultEndianness: Endianness = .big,
    _ parse: (inout BinaryBuffer) throws -> T
) throws -> T {
    try bytes.withUnsafeBufferPointer { pointer in
        var buffer = BinaryBuffer(
            pointer: pointer.baseAddress ?? UnsafePointer(bitPattern: 1)!,
            count: pointer.count,
            defaultEndianness: defaultEndianness,
            release: nil
        )
        return try parse(&buffer)
    }
}

private func parseValue<T: BinaryFormatProtocol>(
    _ type: T.Type,
    from bytes: [UInt8],
    defaultEndianness: Endianness = .big
) throws -> T {
    try parseBytes(bytes, defaultEndianness: defaultEndianness) { buffer in
        try T(consuming: &buffer)
    }
}

private func serializedBytes<T: BinaryFormatProtocol>(_ value: T) throws -> [UInt8] {
    try writtenBytes { writer in
        try value.serialize(into: &writer)
    }
}

private func writtenBytes(
    defaultEndianness: Endianness = .big,
    _ writeBody: (inout BinaryWriter) throws -> Void
) throws -> [UInt8] {
    var output = [UInt8]()
    var writer = BinaryWriter(defaultEndianness: defaultEndianness) { buffer in
        output.append(contentsOf: buffer.bindMemory(to: UInt8.self))
    }

    try writeBody(&writer)
    return output
}

private func bigEndianBytes<T: FixedWidthInteger>(of value: T) -> [UInt8] {
    var value = value.bigEndian
    return withUnsafeBytes(of: &value) { Array($0) }
}

private func littleEndianBytes<T: FixedWidthInteger>(of value: T) -> [UInt8] {
    var value = value.littleEndian
    return withUnsafeBytes(of: &value) { Array($0) }
}

private func assertMacroExpansionWithTesting(
    _ originalSource: String,
    expandedSource expectedExpandedSource: String,
    macroSpecs: [String: MacroSpec],
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
) {
    SwiftSyntaxMacrosGenericTestSupport.assertMacroExpansion(
        originalSource,
        expandedSource: expectedExpandedSource,
        macroSpecs: macroSpecs,
        failureHandler: { failure in
            Issue.record(
                Comment(rawValue: failure.message),
                sourceLocation: Testing.SourceLocation(
                    fileID: failure.location.fileID,
                    filePath: failure.location.filePath,
                    line: failure.location.line,
                    column: failure.location.column
                )
            )
        },
        fileID: fileID,
        filePath: filePath,
        line: line,
        column: column
    )
}
