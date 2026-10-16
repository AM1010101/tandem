import Foundation
import TandemCore

extension CommandSchema {
    /// An edit command explained from its schema entry, for
    /// `tandem help <editCommand>`: its summary, each argument with its type
    /// and description, and the example. A shared model or patch argument is
    /// opened up one level, so `addTransition` shows the transition's fields
    /// too instead of agents learning them by failing.
    public static func help(_ command: CommandCase) -> String {
        guard let entry = entry(command) else { return command.rawValue }
        var lines = ["\(command.rawValue) (an edit command for tandem apply): \(entry.summary)", ""]
        let arguments = properties(of: entry.arguments)
        if arguments.isEmpty {
            lines.append("No arguments.")
        } else {
            lines.append("Arguments:")
            lines += argumentLines(arguments, indent: 2, expand: true)
        }
        lines += ["", "Example:", "  \(entry.example)", "", "`tandem schema` prints the whole JSON schema."]
        return lines.joined(separator: "\n")
    }

    /// An object schema's properties, required ones first in the order the
    /// schema lists them, then the rest alphabetically.
    static func properties(of schema: JSONValue) -> [(name: String, schema: JSONValue, required: Bool)] {
        guard case .object(let fields) = schema, case .object(let properties)? = fields["properties"] else { return [] }
        var required: [String] = []
        if case .array(let names)? = fields["required"] {
            required = names.compactMap { if case .string(let name) = $0 { return name } else { return nil } }
        }
        let rest = properties.keys.filter { !required.contains($0) }.sorted()
        return (required + rest).compactMap { name in properties[name].map { (name, $0, required.contains(name)) } }
    }

    private static func argumentLines(_ arguments: [(name: String, schema: JSONValue, required: Bool)], indent: Int, expand: Bool) -> [String] {
        let width = arguments.map(\.name.count).max() ?? 0
        let pad = String(repeating: " ", count: indent)
        var lines: [String] = []
        for argument in arguments {
            var text = typeText(argument.schema)
            if argument.required { text += ", required" }
            if let description = description(of: argument.schema) { text += ". \(description)" }
            lines.append("\(pad)\(argument.name.padding(toLength: width, withPad: " ", startingAt: 0))  \(text)")
            if expand, let model = openedModel(argument.schema) {
                lines += argumentLines(properties(of: model), indent: indent + 4, expand: false)
            }
        }
        return lines
    }

    private static func field(_ schema: JSONValue, _ key: String) -> JSONValue? {
        guard case .object(let fields) = schema else { return nil }
        return fields[key]
    }

    private static func string(_ value: JSONValue?) -> String? {
        if case .string(let text)? = value { return text }
        return nil
    }

    private static func description(of schema: JSONValue) -> String? {
        string(field(schema, "description"))
    }

    /// The model name of a `$ref` or a patch, like `Transition`.
    private static func modelName(_ schema: JSONValue) -> String? {
        if let ref = string(field(schema, "$ref")) { return String(ref.split(separator: "/").last ?? "") }
        return nil
    }

    private static func typeText(_ schema: JSONValue) -> String {
        if let name = modelName(schema) { return name }
        if let model = string(field(schema, "x-tandem-patch")) { return "patch of \(model)" }
        if case .array(let values)? = field(schema, "enum") {
            return "one of " + values.compactMap(string).joined(separator: " | ")
        }
        if field(schema, "anyOf") != nil || field(schema, "oneOf") != nil { return "one of several shapes" }
        switch field(schema, "type") {
        case .string("array")?:
            return field(schema, "items").map { "array of \(typeText($0))" } ?? "array"
        case .string(let type)?:
            return type
        case .array(let types)?:
            return types.compactMap(string).joined(separator: " or ")
        default:
            return "any"
        }
    }

    /// The object whose fields are worth listing under an argument: a
    /// shared model, a patch's model or an inline object, directly or as an
    /// array's items.
    private static func openedModel(_ schema: JSONValue) -> JSONValue? {
        if let name = modelName(schema) { return definitions[name] }
        if let model = string(field(schema, "x-tandem-patch")) { return definitions[model] ?? patchModels[model] }
        if case .string("array")? = field(schema, "type"), let items = field(schema, "items") { return openedModel(items) }
        if field(schema, "properties") != nil { return schema }
        return nil
    }
}
