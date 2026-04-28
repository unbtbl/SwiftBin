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

private func accessPrefix(for declaration: some DeclGroupSyntax) -> String {
    let modifiers: DeclModifierListSyntax
    if let structDeclaration = declaration.as(StructDeclSyntax.self) {
        modifiers = structDeclaration.modifiers
    } else if let enumDeclaration = declaration.as(EnumDeclSyntax.self) {
        modifiers = enumDeclaration.modifiers
    } else if let classDeclaration = declaration.as(ClassDeclSyntax.self) {
        modifiers = classDeclaration.modifiers
    } else if let actorDeclaration = declaration.as(ActorDeclSyntax.self) {
        modifiers = actorDeclaration.modifiers
    } else {
        return ""
    }

    if modifiers.contains(where: { $0.name.text == "public" || $0.name.text == "open" }) {
        return "public "
    }

    return ""
}

private func conformanceExtensions(
    for type: some TypeSyntaxProtocol,
    protocols: [TypeSyntax]
) -> [ExtensionDeclSyntax] {
    protocols.compactMap { `protocol` in
        let declaration: DeclSyntax = """
        extension \(type.trimmed): \(`protocol`) {}
        """
        return declaration.as(ExtensionDeclSyntax.self)
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
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        let isFrozen = node.attributeName.description != "OpenBinaryEnum"
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

        let access = accessPrefix(for: declaration)
        let parseMarker: String

        if isFrozen {
            parseMarker = """
            let marker = try Marker(consuming: &buffer)
            """
        } else {
            parseMarker = """
            let markerValue = try UInt16(consuming: &buffer)
            guard let marker = Marker(rawValue: markerValue) else {
                try buffer.readLengthPrefixed { payload in
                    payload.skipRemaining()
                }
                self = Self.unknown
                return
            }
            """
        }

        return [
            """
            \(raw: access)enum Marker: UInt16, Hashable, BinaryFormatProtocol {
                \(raw: markerCases.joined(separator: "\n"))
            }
            """,
            """
            \(raw: access)init(consuming buffer: inout BinaryBuffer) throws {
                \(raw: parseMarker)
                switch marker {
                    \(raw: parseStatements.joined(separator: "\n"))
                }
            }
            """,
            """
            \(raw: access)func serialize(into writer: inout BinaryWriter) throws {
                switch self {
                    \(raw: serializeStatements.joined(separator: "\n"))
                }
            }
            """
        ]
    }

    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        conformanceExtensions(for: type, protocols: protocols)
    }
}

public struct BinaryFormatMacro: MemberMacro, ExtensionMacro {
    public static var formatMode: FormatMode { .auto }

    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        let memberList = declaration.memberBlock.members

        let properties = memberList.flatMap { member -> [String] in
            guard
                let variable = member
                    .decl
                    .as(VariableDeclSyntax.self)
            else {
                return []
            }

            if variable.modifiers.contains(where: { $0.name.text == "static" || $0.name.text == "class" || $0.name.text == "lazy" }) {
                return []
            }

            return variable.bindings.compactMap { binding in
                guard binding.accessorBlock == nil else {
                    return nil
                }

                return binding
                    .pattern
                    .as(IdentifierPatternSyntax.self)?
                    .identifier
                    .text
            }
        }

        let access = accessPrefix(for: declaration)
        let parseStatements = properties.map { property in
            "self.\(property) = try .init(consuming: &buffer)"
        }

        let serializeStatements = properties.map { property in
            "try self.\(property).serialize(into: &writer)"
        }

        return [
            """
            \(raw: access)init(consuming buffer: inout BinaryBuffer) throws {
                \(raw: parseStatements.joined(separator: "\n"))
            }
            """,
            """
            \(raw: access)func serialize(into writer: inout BinaryWriter) throws {
                \(raw: serializeStatements.joined(separator: "\n"))
            }
            """
        ]
    }
    
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        conformanceExtensions(for: type, protocols: protocols)
    }
}

@main
struct testPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        BinaryFormatMacro.self,
        BinaryEnumMacro.self,
    ]
}
