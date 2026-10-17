import XCTest
@testable import TandemAPI
@testable import TandemCore

/// Keeps the agent guide honest: docs/AGENTS.md (the entry point) and its
/// topic files in docs/agents/. Every edit command is in the command index,
/// every JSON example decodes, every link between the files resolves, and
/// the entry point stays small enough to read whole. Each command's
/// arguments and example live in the schema (`tandem help <command>`),
/// which SchemaTests checks.
final class DocsTests: XCTestCase {
    static let docs = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("docs")
    static let entry = docs.appendingPathComponent("AGENTS.md")
    static let topics = docs.appendingPathComponent("agents")

    /// The entry point and every topic file.
    func guideFiles() throws -> [URL] {
        let topics = try FileManager.default.contentsOfDirectory(at: Self.topics, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(topics.isEmpty, "docs/agents/ has no topic files")
        return [Self.entry] + topics
    }

    func text(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    func name(_ url: URL) -> String {
        url == Self.entry ? "docs/AGENTS.md" : "docs/agents/\(url.lastPathComponent)"
    }

    /// The contents of every ```json block.
    func jsonBlocks(in text: Substring) -> [String] {
        var blocks: [String] = []
        var rest = text
        while let open = rest.range(of: "```json\n") {
            guard let close = rest.range(of: "\n```", range: open.upperBound..<rest.endIndex) else { break }
            blocks.append(String(rest[open.upperBound..<close.lowerBound]))
            rest = rest[close.upperBound...]
        }
        return blocks
    }

    func testEveryCommandIsInTheCommandIndex() throws {
        let text = try text(Self.topics.appendingPathComponent("edit-commands.md"))
        let start = try XCTUnwrap(text.range(of: "## Every command"))
        let index = text[start.upperBound...]
        for command in CommandCase.allCases {
            XCTAssertTrue(index.contains("`\(command.rawValue)`"), "docs/agents/edit-commands.md doesn't list \(command.rawValue) under \"Every command\"")
        }
    }

    func testEveryJSONExampleInTheGuideDecodes() throws {
        var count = 0
        for file in try guideFiles() {
            for block in jsonBlocks(in: try text(file)[...]) {
                count += 1
                let value = try json(block)
                switch value {
                case .object(let fields) where fields["commands"] != nil:
                    XCTAssertNoThrow(try ServiceJSON.decodeRequest(ApplyRequest.self, from: Data(block.utf8)), "\(name(file)): \(block)")
                case .object(let fields) where fields.count == 1 && CommandCase(rawValue: fields.keys.first!) != nil:
                    XCTAssertNoThrow(try CommandJSON.decodeAll(value), "\(name(file)): \(block)")
                default:
                    XCTFail("unexpected JSON example in \(name(file)): \(block)")
                }
            }
        }
        XCTAssertGreaterThan(count, 15, "the guide should still have its examples")
    }

    /// Relative links like [x](agents/cutting.md#cut-a-phrase) point at a
    /// file that exists and, with a fragment, a heading in it.
    func testLinksBetweenTheGuideFilesResolve() throws {
        let link = try NSRegularExpression(pattern: #"\]\(([^)\s]+)\)"#)
        for file in try guideFiles() {
            let text = try text(file)
            let matches = link.matches(in: text, range: NSRange(text.startIndex..., in: text))
            for match in matches {
                let target = String(text[Range(match.range(at: 1), in: text)!])
                if target.hasPrefix("http") { continue }
                let parts = target.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                let path = parts[0]
                let destination = path.isEmpty ? file : file.deletingLastPathComponent().appendingPathComponent(path).standardizedFileURL
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory) else {
                    XCTFail("\(name(file)) links to \(target), which doesn't exist")
                    continue
                }
                guard parts.count == 2, !isDirectory.boolValue else { continue }
                let anchors = Self.anchors(in: try self.text(destination))
                XCTAssertTrue(anchors.contains(parts[1]), "\(name(file)) links to \(target), but there's no heading #\(parts[1])")
            }
        }
    }

    /// GitHub's heading anchors: lower case, punctuation dropped, spaces to dashes.
    static func anchors(in text: String) -> Set<String> {
        var result = Set<String>()
        var inCode = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("```") { inCode.toggle(); continue }
            guard !inCode, line.hasPrefix("#") else { continue }
            let title = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
            let slug = title.lowercased().compactMap { c -> Character? in
                if c == " " { return "-" }
                if c.isLetter || c.isNumber || c == "-" || c == "_" { return c }
                return nil
            }
            result.insert(String(slug))
        }
        return result
    }

    func testTheEntryPointStaysSmall() throws {
        let size = try Data(contentsOf: Self.entry).count
        XCTAssertLessThan(size, 25_000, "docs/AGENTS.md is meant to be read whole; move detail into docs/agents/")
    }

    func testEveryTopicFileSaysWhatsInIt() throws {
        for file in try guideFiles().dropFirst() {
            let lines = try text(file).split(separator: "\n", omittingEmptySubsequences: true)
            XCTAssertTrue(lines.first?.hasPrefix("# ") == true, "\(name(file)) should start with a title")
            XCTAssertGreaterThan(lines.dropFirst().first?.count ?? 0, 30, "\(name(file)) should say what's in it on the line after its title")
        }
    }

    func testTheGuideHasNoLongDashes() throws {
        for file in try guideFiles() {
            XCTAssertFalse(try text(file).contains("\u{2014}"), "no em dashes in \(name(file))")
        }
    }
}
