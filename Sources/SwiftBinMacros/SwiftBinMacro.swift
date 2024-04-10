import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

struct EnumCase {
    let name: String
    let members: [String?]
    var memberCount: Int { members.count }

    var parameters: [String] {
        (1...memberCount).map { index in
            "c\(index)"
        }
    }

    var labels: [String] {
        members.map { member in
            if let member {
                return "\(member): "
            } else {
                return ""
            }
        }
    }

    var captureParameters: String {
        if memberCount == 0 { return "" }
        let captures = parameters.map { "let \($0)" }
        return "(\(captures.joined(separator: ", ")))"
    }

    var captureParametersSerializeStatements: [String] {
        if memberCount == 0 { return [] }
        return parameters.map { "try \($0).serialize(into: &writer)" }
    }

    var parseParameters: String {
        if memberCount == 0 { return "" }
        let captures = labels.map { label in
            return "\(label)try .init(consuming: &buffer)"
        }
        return "(\(captures.joined(separator: ", ")))"
    }
}

public struct BinaryEnumMacro: MemberMacro, ExtensionMacro {
    enum Error: Swift.Error, CustomDebugStringConvertible {
        case notAnEnum, unsupportedEnumCasesCount

        var debugDescription: String {
            switch self {
            case .notAnEnum:
                return "Type is not an enum"
            case .unsupportedEnumCasesCount:
                return "BinaryEnum supports only \(UInt16.max) cases per enum"
            }
        }
    }

    public static var formatMode: FormatMode { .auto }

    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        let isFrozen = !node.description.contains("OpenBinaryEnum")
        guard declaration.is(EnumDeclSyntax.self) else {
            throw Error.notAnEnum
        }

        let memberList = declaration.memberBlock.members

        let enumCases = memberList.flatMap { member -> [EnumCase] in
            guard
                let enumCase = member
                    .decl
                    .as(EnumCaseDeclSyntax.self)
            else {
                return []
            }

            return enumCase.elements.map { element in
                guard let parameterClause = element.parameterClause else {
                    return EnumCase(
                        name: element.name.text,
                        members: []
                    )
                }

                return EnumCase(
                    name: element.name.text,
                    members: parameterClause.parameters.map(\.firstName?.text)
                )
            }
        }

        if enumCases.count > Int(UInt16.max) {
            throw Error.unsupportedEnumCasesCount
        }

        let markerCases = enumCases.enumerated().map { (index, enumCase) in
            "case \(enumCase.name) = \(index)"
        }

        let parseStatements = enumCases.map { enumCase in
            if enumCase.memberCount == 0 {
                return """
                case .\(enumCase.name):
                    self = .\(enumCase.name)
                    try buffer.readLengthPrefixed { _ in }
                """
            } else {
                return """
                case .\(enumCase.name):
                    self = try buffer.readLengthPrefixed { buffer in
                        .\(enumCase.name)\(enumCase.parseParameters)
                    }
                """
            }
        }

        let serializeStatements = enumCases.map { enumCase in
            if enumCase.memberCount == 0 {
                return """
                case .\(enumCase.name)\(enumCase.captureParameters):
                    try Marker.\(enumCase.name).serialize(into: &writer)
                    try writer.writeLengthPrefixed { _ in }
                """
            } else {
                return """
                case .\(enumCase.name)\(enumCase.captureParameters):
                    try Marker.\(enumCase.name).serialize(into: &writer)
                    try writer.writeLengthPrefixed { writer in
                        \(enumCase.captureParametersSerializeStatements.joined(separator: "\n"))
                    }
                """
            }
        }

        let parseMarker: String

        if isFrozen {
            parseMarker = """
            let marker = try Marker(consuming: &buffer)
            """
        } else {
            parseMarker = """
            let marker = (try? Marker(consuming: &buffer)) ?? .unknown
            """
        }

        return [
            """
            public enum Marker: UInt16, Hashable, BinaryFormatProtocol {
                \(raw: markerCases.joined(separator: "\n"))
            }
            """,
            """
            init(consuming buffer: inout BinaryBuffer) throws {
                \(raw: parseMarker)
                switch marker {
                    \(raw: parseStatements.joined(separator: "\n"))
                }
            }
            """,
            """
            func serialize(into writer: inout BinaryWriter) throws {
                switch self {
                    \(raw: serializeStatements.joined(separator: "\n"))
                }
            }
            """
        ]
    }

    public static func expansion(of node: AttributeSyntax, attachedTo declaration: some DeclGroupSyntax, providingExtensionsOf type: some TypeSyntaxProtocol, conformingTo protocols: [TypeSyntax], in context: some MacroExpansionContext) throws -> [ExtensionDeclSyntax] {
        []
    }
}

public struct BinaryFormatMacro: MemberMacro, ExtensionMacro {
    public static var formatMode: FormatMode { .auto }

    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        let memberList = declaration.memberBlock.members

        let properties = memberList.compactMap { member -> String? in
            guard
                let propertyName = member
                    .decl
                    .as(VariableDeclSyntax.self)?
                    .bindings
                    .first?
                    .pattern
                    .as(IdentifierPatternSyntax.self)?
                    .identifier
                    .text
            else {
                return nil
            }

            if member.decl.as(VariableDeclSyntax.self)?.attributes.isEmpty == false {
                return "_" + propertyName
            } else {
                return propertyName
            }
        }

        let parseStatements = properties.map { property in
            "self.\(property) = try .init(consuming: &buffer)"
        }

        let serializeStatements = properties.map { property in
            "try self.\(property).serialize(into: &writer)"
        }

        return [
            """
            init(consuming buffer: inout BinaryBuffer) throws {
                \(raw: parseStatements.joined(separator: "\n"))
            }
            """,
            """
            func serialize(into writer: inout BinaryWriter) throws {
                \(raw: serializeStatements.joined(separator: "\n"))
            }
            """
        ]
    }
    
    public static func expansion(of node: AttributeSyntax, attachedTo declaration: some DeclGroupSyntax, providingExtensionsOf type: some TypeSyntaxProtocol, conformingTo protocols: [TypeSyntax], in context: some MacroExpansionContext) throws -> [ExtensionDeclSyntax] {
        []
    }
}

@main
struct testPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        BinaryFormatMacro.self,
        BinaryEnumMacro.self,
    ]
}
