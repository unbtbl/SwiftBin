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

private enum RawMarker: UInt8, BinaryFormatProtocol {
    case known = 1
}

private enum ExpectedError: Error {
    case failure
}

@Test
func bufferTracksConsumptionAndReadsIntegers() throws {
    let result = try parseBytes([0x01, 0x34, 0x12, 0xff]) { buffer in
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

        buffer.advance(by: 1)
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
func bufferReadsLengthPrefixedSlicesUsingNativeLengthBytes() throws {
    let bytes = nativeBytes(of: UInt16(3)) + [0x0a, 0x0b, 0x0c, 0xff]

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
func writerWritesRawBytesStringsAndNativeLengthPrefixes() throws {
    let bytes = try writtenBytes { writer in
        try writer.writeLengthPrefixed(lengthPrefix: UInt16.self) { nestedWriter in
            try nestedWriter.writeString("Hi")
        }
    }

    #expect(bytes == nativeBytes(of: UInt16(2)) + [0x48, 0x69])
}

@Test
func fixedWidthIntegersSerializeAndParseUsingCurrentSemantics() throws {
    let serialized = try serializedBytes(UInt16(0x1234))
    let parsed = try parseValue(UInt16.self, from: nativeBytes(of: UInt16(0x1234)))

    #expect(serialized == [0x12, 0x34])
    #expect(parsed == 0x1234)
}

@Test
func floatingPointValuesSerializeBitPatternsAndParseNativeBitPatterns() throws {
    let float = Float(bitPattern: 0x3f800000)
    let double = Double(bitPattern: 0x3ff0000000000000)

    #expect(try serializedBytes(float) == [0x3f, 0x80, 0x00, 0x00])
    #expect(try serializedBytes(double) == [0x3f, 0xf0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
    #expect(try parseValue(Float.self, from: nativeBytes(of: UInt32(0x3f800000))) == 1.0)
    #expect(try parseValue(Double.self, from: nativeBytes(of: UInt64(0x3ff0000000000000))) == 1.0)
}

@Test
func arraysSerializeBigEndianCountAndParseNativeCount() throws {
    let serialized = try serializedBytes([UInt8(0x01), UInt8(0x02), UInt8(0x03)])
    let parsed = try parseValue([UInt8].self, from: nativeBytes(of: Int(3)) + [0x01, 0x02, 0x03])

    #expect(serialized == bigEndianBytes(of: Int(3)) + [0x01, 0x02, 0x03])
    #expect(parsed == [0x01, 0x02, 0x03])
}

@Test
func stringsSerializeBigEndianLengthAndParseNativeLength() throws {
    let serialized = try serializedBytes("Hi")
    let parsed = try parseValue(String.self, from: nativeBytes(of: Int(2)) + [0x48, 0x69])
    let invalidUTF8 = try parseValue(String.self, from: nativeBytes(of: Int(1)) + [0xff])

    #expect(serialized == bigEndianBytes(of: Int(2)) + [0x48, 0x69])
    #expect(parsed == "Hi")
    #expect(invalidUTF8 == "\u{fffd}")
}

@Test
func dataSerializesBigEndianLengthAndParsesNativeLength() throws {
    let data = Data([0xde, 0xad, 0xbe, 0xef])
    let serialized = try serializedBytes(data)
    let parsed = try parseValue(Data.self, from: nativeBytes(of: Int(data.count)) + Array(data))

    #expect(serialized == bigEndianBytes(of: Int(data.count)) + Array(data))
    #expect(parsed == data)
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
func binaryEnumMacroAddsConformanceAndSerializesCases() throws {
    let conforming: any BinaryEnumProtocol = TestEvent.foreground
    let foregroundData = try TestEvent.foreground.writeData()
    let searchBytes = try serializedBytes(TestEvent.search(0x2a))
    let sendBytes = try serializedBytes(TestEvent.send(0x01, toUserId: 0x02))

    #expect(foregroundData == Data(nativeBytes(of: UInt16(0)) + nativeBytes(of: UInt32(0))))
    #expect(searchBytes == [0x00, 0x01] + nativeBytes(of: UInt32(1)) + [0x2a])
    #expect(sendBytes == [0x00, 0x02] + nativeBytes(of: UInt32(2)) + [0x01, 0x02])
    _ = conforming
}

@Test
func binaryEnumMacroParsesNativeMarkerAndLengthBytes() throws {
    let searchBytes = nativeBytes(of: UInt16(1)) + nativeBytes(of: UInt32(1)) + [0x2a]
    let sendBytes = nativeBytes(of: UInt16(2)) + nativeBytes(of: UInt32(2)) + [0x01, 0x02]

    #expect(try parseValue(TestEvent.self, from: searchBytes) == .search(0x2a))
    #expect(try parseValue(TestEvent.self, from: sendBytes) == .send(0x01, toUserId: 0x02))
}

@Test
func openBinaryEnumMapsUnknownMarkersToUnknownCase() throws {
    let conforming: any NonFrozenBinaryEnumProtocol = OpenEvent.unknown
    let bytes = nativeBytes(of: UInt16(999)) + nativeBytes(of: UInt32(0))

    #expect(try parseValue(OpenEvent.self, from: bytes) == .unknown)
    _ = conforming
}

@Test
func binaryFormatMacroExpansionIncludesGeneratedMembersAndConformance() {
    assertMacroExpansionWithTesting(
        """
        @BinaryFormat
        struct Packet {
            let id: UInt8
            var name: String
        }
        """,
        expandedSource: """
        struct Packet {
            let id: UInt8
            var name: String

            init(consuming buffer: inout BinaryBuffer) throws {
                self.id = try .init(consuming: &buffer)
                self.name = try .init(consuming: &buffer)
            }

            func serialize(into writer: inout BinaryWriter) throws {
                try self.id.serialize(into: &writer)
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

            public enum Marker: UInt16, Hashable, BinaryFormatProtocol {
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

            public enum Marker: UInt16, Hashable, BinaryFormatProtocol {
                case unknown = 0
                case known = 1
            }

            init(consuming buffer: inout BinaryBuffer) throws {
                let marker = (try? Marker(consuming: &buffer)) ?? .unknown
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
    _ parse: (inout BinaryBuffer) throws -> T
) throws -> T {
    try bytes.withUnsafeBufferPointer { pointer in
        var buffer = BinaryBuffer(
            pointer: pointer.baseAddress!,
            count: pointer.count,
            release: nil
        )
        return try parse(&buffer)
    }
}

private func parseValue<T: BinaryFormatProtocol>(
    _ type: T.Type,
    from bytes: [UInt8]
) throws -> T {
    try parseBytes(bytes) { buffer in
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

private func nativeBytes<T>(of value: T) -> [UInt8] {
    var value = value
    return withUnsafeBytes(of: &value) { Array($0) }
}

private func bigEndianBytes<T: FixedWidthInteger>(of value: T) -> [UInt8] {
    var value = value.bigEndian
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
