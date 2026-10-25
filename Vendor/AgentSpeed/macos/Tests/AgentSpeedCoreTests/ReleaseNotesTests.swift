import Foundation
import Testing
@testable import AgentSpeedCore

@Suite("Release notes")
struct ReleaseNotesTests {
    typealias Block = ReleaseNotesBlock

    static func bullet(_ text: String, depth: Int = 0) -> Block {
        .listItem(marker: "•", depth: depth, text: text)
    }

    @Test func githubGeneratedNotes() {
        let markdown = """
        <!-- Release notes generated using configuration in .github/release.yml at main -->

        ## What's Changed
        * Fix x by @y in https://github.com/o/r/pull/1
        * Add `z` by @w in https://github.com/o/r/pull/2

        ## New Contributors
        * @w made their first contribution in https://github.com/o/r/pull/2

        **Full Changelog**: https://github.com/o/r/compare/v1.0.0...v1.0.1
        """
        #expect(ReleaseNotes.blocks(from: markdown) == [
            .heading(level: 2, text: "What's Changed"),
            Self.bullet("Fix x by @y in https://github.com/o/r/pull/1"),
            Self.bullet("Add `z` by @w in https://github.com/o/r/pull/2"),
            .heading(level: 2, text: "New Contributors"),
            Self.bullet("@w made their first contribution in https://github.com/o/r/pull/2"),
            .paragraph("**Full Changelog**: https://github.com/o/r/compare/v1.0.0...v1.0.1"),
        ])
    }

    @Test func minimalGitHubSample() {
        let markdown = "## What's Changed\n* Fix x by @y in https://github.com/o/r/pull/1\n\n**Full Changelog**: https://github.com/o/r/compare/v1.0.0...v1.0.1"
        #expect(ReleaseNotes.blocks(from: markdown) == [
            .heading(level: 2, text: "What's Changed"),
            Self.bullet("Fix x by @y in https://github.com/o/r/pull/1"),
            .paragraph("**Full Changelog**: https://github.com/o/r/compare/v1.0.0...v1.0.1"),
        ])
    }

    @Test func releaseWorkflowTemplate() {
        let markdown = """
        ## Install / 安裝 / 安装 / インストール

        **macOS 14+** (Apple Silicon & Intel)

        ```sh
        curl -fsSL https://raw.githubusercontent.com/zoefix/agent-speed/main/install.sh | sh
        ```

        Run the same command again to update. Every download is verified against `SHA256SUMS.txt`.

        Agent Speed v1.2.0 reads local transcripts only.
        No network, no telemetry.
        """
        #expect(ReleaseNotes.blocks(from: markdown) == [
            .heading(level: 2, text: "Install / 安裝 / 安装 / インストール"),
            .paragraph("**macOS 14+** (Apple Silicon & Intel)"),
            .code("curl -fsSL https://raw.githubusercontent.com/zoefix/agent-speed/main/install.sh | sh"),
            .paragraph("Run the same command again to update. Every download is verified against `SHA256SUMS.txt`."),
            .paragraph("Agent Speed v1.2.0 reads local transcripts only.\nNo network, no telemetry."),
        ])
    }

    @Test(arguments: [
        ("# One", [ReleaseNotesBlock.heading(level: 1, text: "One")]),
        ("###### Six", [.heading(level: 6, text: "Six")]),
        ("####### Seven", [.paragraph("####### Seven")]),
        ("#NoSpace", [.paragraph("#NoSpace")]),
        ("#", [.paragraph("#")]),
        ("## Closing ##", [.heading(level: 2, text: "Closing")]),
        ("### Closing   #####   ", [.heading(level: 3, text: "Closing")]),
        ("#\tTab", [.heading(level: 1, text: "Tab")]),
        ("   ## Indented", [.heading(level: 2, text: "Indented")]),
        ("## **Bold** `code`", [.heading(level: 2, text: "**Bold** `code`")]),
        ("# C#", [.heading(level: 1, text: "C#")]),
        ("## Support for F# and C#", [.heading(level: 2, text: "Support for F# and C#")]),
        ("## Issue #12", [.heading(level: 2, text: "Issue #12")]),
        ("## Ends with hash# ##", [.heading(level: 2, text: "Ends with hash#")]),
    ] as [(String, [ReleaseNotesBlock])])
    func atxHeadings(markdown: String, expected: [Block]) {
        #expect(ReleaseNotes.blocks(from: markdown) == expected)
    }

    @Test(arguments: [
        ("Title\n=====", [ReleaseNotesBlock.heading(level: 1, text: "Title")]),
        ("Title\n=", [.heading(level: 1, text: "Title")]),
        ("Sub\n---", [.heading(level: 2, text: "Sub")]),
        ("  Sub  \n  ------  ", [.heading(level: 2, text: "Sub")]),
        ("Title\n===\n\nSub\n---\nBody", [.heading(level: 1, text: "Title"), .heading(level: 2, text: "Sub"), .paragraph("Body")]),
        ("Two\nlines\n---", [.paragraph("Two\nlines"), .rule]),
        ("---", [.rule]),
        ("===", [.paragraph("===")]),
        ("- item\n---", [bullet("item"), .rule]),
        ("- item\n===", [bullet("item ===")]),
        ("Text\n- - -", [.paragraph("Text"), .rule]),
        ("Text\n\n---", [.paragraph("Text"), .rule]),
    ] as [(String, [ReleaseNotesBlock])])
    func setextHeadingsAndRules(markdown: String, expected: [Block]) {
        #expect(ReleaseNotes.blocks(from: markdown) == expected)
    }

    @Test func nestedBullets() {
        let markdown = """
        - level zero
          - level one
            - level two
              - level three
                - deeper is capped
        * star
        + plus
           - three spaces
        \t- tab
        """
        #expect(ReleaseNotes.blocks(from: markdown) == [
            Self.bullet("level zero"),
            Self.bullet("level one", depth: 1),
            Self.bullet("level two", depth: 2),
            Self.bullet("level three", depth: 3),
            Self.bullet("deeper is capped", depth: 3),
            Self.bullet("star"),
            Self.bullet("plus"),
            Self.bullet("three spaces", depth: 1),
            Self.bullet("tab", depth: 2),
        ])
    }

    @Test func numberedLists() {
        let markdown = """
        1. First
        2) Second
        10. Tenth
          3. Nested
        123456789. Long
        """
        #expect(ReleaseNotes.blocks(from: markdown) == [
            .listItem(marker: "1.", depth: 0, text: "First"),
            .listItem(marker: "2.", depth: 0, text: "Second"),
            .listItem(marker: "10.", depth: 0, text: "Tenth"),
            .listItem(marker: "3.", depth: 1, text: "Nested"),
            .listItem(marker: "123456789.", depth: 0, text: "Long"),
        ])
    }

    @Test(arguments: [
        "1.5 is faster", "2024.Year", "1234567890. Too long", "3.", "-not a bullet", "*emphasis*", "+1 from me",
        "1)no space", "-", "- ", "1. ", "• Unicode bullet",
    ])
    func notListItems(markdown: String) {
        let blocks = ReleaseNotes.blocks(from: markdown)
        #expect(blocks == [.paragraph(markdown.trimmingCharacters(in: .whitespaces))])
    }

    @Test func continuationLinesJoinTheirItem() {
        let markdown = """
        - Fixes the meter
          when idle
        and keeps going
        - Next
        1. Numbered
           continued
        """
        #expect(ReleaseNotes.blocks(from: markdown) == [
            Self.bullet("Fixes the meter when idle and keeps going"),
            Self.bullet("Next"),
            .listItem(marker: "1.", depth: 0, text: "Numbered continued"),
        ])
    }

    @Test func paragraphsKeepSingleLineBreaks() {
        let markdown = "  Line one  \nLine two\n\n\n\nSecond paragraph\nIntro:\n- item\n\nAfter"
        #expect(ReleaseNotes.blocks(from: markdown) == [
            .paragraph("Line one\nLine two"),
            .paragraph("Second paragraph\nIntro:"),
            Self.bullet("item"),
            .paragraph("After"),
        ])
    }

    @Test func fencedCodeKeepsItsLinesVerbatim() {
        let markdown = """
        Text
        ```swift
        let x = 1

          indented()
        # not a heading
        - not an item
        ```
        After
        """
        #expect(ReleaseNotes.blocks(from: markdown) == [
            .paragraph("Text"),
            .code("let x = 1\n\n  indented()\n# not a heading\n- not an item"),
            .paragraph("After"),
        ])
    }

    @Test(arguments: [
        ("~~~\ncode\n~~~", [ReleaseNotesBlock.code("code")]),
        ("~~~\n```\n~~~", [.code("```")]),
        ("```\n~~~\n```", [.code("~~~")]),
        ("```\n```", [.code("")]),
        ("```\nopen\n\nfence", [.code("open\n\nfence")]),
        ("- item\n  ```\n  code\n  ```", [bullet("item"), .code("  code")]),
        ("```\n<b>raw</b>\n```", [.code("<b>raw</b>")]),
    ] as [(String, [ReleaseNotesBlock])])
    func fenceVariants(markdown: String, expected: [Block]) {
        #expect(ReleaseNotes.blocks(from: markdown) == expected)
    }

    @Test func quotes() {
        let markdown = """
        > **Note**
        > second line
        >
        >no space
        Paragraph after
        > again
        """
        #expect(ReleaseNotes.blocks(from: markdown) == [
            .quote("**Note**\nsecond line\n\nno space"),
            .paragraph("Paragraph after"),
            .quote("again"),
        ])
    }

    @Test func quoteEndsListAndParagraph() {
        #expect(ReleaseNotes.blocks(from: "- item\n> quote\n\nText\n> quote two") == [
            Self.bullet("item"), .quote("quote"), .paragraph("Text"), .quote("quote two"),
        ])
    }

    @Test(arguments: ["***", "---", "___", "* * *", "- - -", "_ _ _", "-----", "  ***  ", "*****"])
    func rules(markdown: String) {
        #expect(ReleaseNotes.blocks(from: "Above\n\n\(markdown)\n\nBelow") == [
            .paragraph("Above"), .rule, .paragraph("Below"),
        ])
    }

    @Test(arguments: ["**", "*-*", "-*-", "***bold***", "__init__"])
    func notRules(markdown: String) {
        #expect(!ReleaseNotes.blocks(from: markdown).contains(.rule))
    }

    @Test(arguments: [
        ("Before <!-- hidden --> after", [ReleaseNotesBlock.paragraph("Before  after")]),
        ("Keep\n<!--\nhidden\n## not a heading\n-->\nAlso", [.paragraph("Keep"), .paragraph("Also")]),
        ("<!-- a --><!-- b -->Only", [.paragraph("Only")]),
        ("Text <!-- never closed\n## Hidden", [.paragraph("Text")]),
        ("<!---->Empty comment", [.paragraph("Empty comment")]),
        ("-->stray close", [.paragraph("-->stray close")]),
    ] as [(String, [ReleaseNotesBlock])])
    func htmlCommentsAreRemoved(markdown: String, expected: [Block]) {
        #expect(ReleaseNotes.blocks(from: markdown) == expected)
    }

    @Test func windowsAndClassicMacLineEndings() {
        let crlf = "## Title\r\n\r\n- one\r\n- two\r\n\r\nLine a\r\nLine b\r\n```\r\ncode\r\n```\r\n"
        #expect(ReleaseNotes.blocks(from: crlf) == [
            .heading(level: 2, text: "Title"), Self.bullet("one"), Self.bullet("two"),
            .paragraph("Line a\nLine b"), .code("code"),
        ])
        #expect(ReleaseNotes.blocks(from: "a\rb\r\rc") == [.paragraph("a\nb"), .paragraph("c")])
    }

    @Test(arguments: ["", " ", "\n\n", "\r\n\t\r\n", "<!-- only a comment -->"])
    func emptyNotes(markdown: String) {
        #expect(ReleaseNotes.blocks(from: markdown).isEmpty)
    }

    @Test func inlineMarkdownStaysInText() {
        let line = "Use `code`, **bold**, _em_ and [links](https://github.com/zoefix/agent-speed) 🚀"
        #expect(ReleaseNotes.blocks(from: line) == [.paragraph(line)])
    }

    @Test func mixedRealisticNotes() {
        let markdown = """
        # Agent Speed 1.2.0

        Highlights:
        - Automatic updates
          with one click
        - Faster dashboard

        1. Download
        2. Run

        > Requires macOS 14.

        ---
        """
        #expect(ReleaseNotes.blocks(from: markdown) == [
            .heading(level: 1, text: "Agent Speed 1.2.0"),
            .paragraph("Highlights:"),
            Self.bullet("Automatic updates with one click"),
            Self.bullet("Faster dashboard"),
            .listItem(marker: "1.", depth: 0, text: "Download"),
            .listItem(marker: "2.", depth: 0, text: "Run"),
            .quote("Requires macOS 14."),
            .rule,
        ])
    }

    static func numberedLines(_ range: ClosedRange<Int>) -> [String] {
        range.map { "Line " + String(repeating: "0", count: 4 - String($0).count) + String($0) }
    }

    @Test func notesAtTheLimitAreNotTruncated() {
        let lines = Self.numberedLines(1...2000)
        let markdown = lines.joined(separator: "\n") + "\n"
        #expect(markdown.count == ReleaseNotes.maxCharacters)
        #expect(ReleaseNotes.blocks(from: markdown) == [.paragraph(lines.joined(separator: "\n"))])
    }

    @Test func longNotesAreCutAtALineBoundary() {
        let markdown = Self.numberedLines(1...3000).joined(separator: "\n")
        #expect(markdown.count > ReleaseNotes.maxCharacters)
        #expect(ReleaseNotes.blocks(from: markdown) == [
            .paragraph(Self.numberedLines(1...2000).joined(separator: "\n") + "\n…"),
        ])
    }

    @Test func partialLastLineIsDropped() {
        let markdown = "Head\n" + Self.numberedLines(1...3000).joined(separator: "\n")
        #expect(ReleaseNotes.blocks(from: markdown) == [
            .paragraph((["Head"] + Self.numberedLines(1...1999)).joined(separator: "\n") + "\n…"),
        ])
    }

    @Test func truncationKeepsEarlierBlocksAndMarksTheEnd() {
        let markdown = "## Notes\n\n" + (1...5000).map { "- Change \($0)" }.joined(separator: "\n")
        let blocks = ReleaseNotes.blocks(from: markdown)
        #expect(blocks.first == .heading(level: 2, text: "Notes"))
        let characters = blocks.reduce(0) { total, block in
            switch block {
            case .heading(_, let text), .paragraph(let text), .listItem(_, _, let text), .code(let text), .quote(let text):
                total + text.count
            case .rule:
                total
            }
        }
        #expect(characters < ReleaseNotes.maxCharacters)
        guard case .listItem(_, _, let last) = blocks.last else {
            Issue.record("Expected the truncated notes to end in a list item, got \(String(describing: blocks.last))")
            return
        }
        #expect(last.hasSuffix(" …"))
        #expect(blocks.count < 5001)
    }

    @Test func commentsDoNotCountTowardsTheLimit() {
        let markdown = "<!--" + String(repeating: "x", count: 50_000) + "-->Short notes"
        #expect(ReleaseNotes.blocks(from: markdown) == [.paragraph("Short notes")])
    }

    @Test func singleHugeLineIsCutAtTheLimit() {
        let markdown = String(repeating: "a", count: 30_000)
        #expect(ReleaseNotes.blocks(from: markdown) == [
            .paragraph(String(repeating: "a", count: ReleaseNotes.maxCharacters) + "\n…"),
        ])
    }
}
