import Foundation
import XCTest

@testable import MoxuCore

final class ParserRegressionTests: XCTestCase {
    func testBarePrefaceAndEpilogueKeepTheirSingleParagraph() throws {
        for heading in ["序章", "楔子", "序幕", "引子", "尾声", "终章", "后记", "番外"] {
            let body = "林舟走进书店，苏禾抬起头来。"
            let source = heading + "\n" + body
            let chapters = try ChapterParser.parse(source, title: "书")
            XCTAssertEqual(chapters.count, 1, heading)
            let chapter = try XCTUnwrap(chapters.first)
            XCTAssertEqual(chapter.title, heading)
            XCTAssertEqual(chapter.text, body)
            assertOriginalBody(chapter, source: source)
        }
    }

    func testPrefaceBeforeFirstChapterKeepsBothBodies() throws {
        let source = "序章\n林舟走进书店。\n\n第一章 雨\n苏禾抬起头来。"
        let chapters = try ChapterParser.parse(source, title: "书")
        XCTAssertEqual(chapters.map(\.title), ["序章", "第一章 雨"])
        XCTAssertEqual(chapters.map(\.text), ["林舟走进书店。\n\n", "苏禾抬起头来。"])
        for chapter in chapters { assertOriginalBody(chapter, source: source) }
    }

    func testBlankLinesAfterPrefaceDoNotJoinTheHeading() throws {
        let source = "序章\n\n\n林舟走进书店。\n\n"
        let chapter = try XCTUnwrap(ChapterParser.parse(source, title: "书").first)
        XCTAssertEqual(chapter.title, "序章")
        XCTAssertEqual(chapter.text, "\n\n林舟走进书店。\n\n")
        assertOriginalBody(chapter, source: source)
    }

    func testHorizontalChineseWhitespaceAndSubtitlesStillMatch() throws {
        let source = "\t　序章　夜雨　\t\n林舟走进书店。\n　第　 一　章　初遇　\n苏禾抬起头来。"
        let chapters = try ChapterParser.parse(source, title: "书")
        XCTAssertEqual(chapters.map(\.title), ["序章　夜雨", "第　 一　章　初遇"])
        XCTAssertEqual(chapters.map(\.text), ["林舟走进书店。\n", "苏禾抬起头来。"])
        for chapter in chapters { assertOriginalBody(chapter, source: source) }
    }

    func testWrappedHeadingPrefixesDoNotConsumeSourceLines() throws {
        for source in ["第\n一章\n林舟走进书店。", "Chapter\n1\n林舟走进书店。"] {
            let chapters = try ChapterParser.parse(source, title: "书")
            XCTAssertEqual(chapters.count, 1)
            let chapter = try XCTUnwrap(chapters.first)
            XCTAssertEqual(chapter.title, "书")
            XCTAssertEqual(chapter.text, source)
            assertOriginalBody(chapter, source: source)
        }
    }

    private func assertOriginalBody(
        _ chapter: RawChapter, source: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let range = NSRange(location: chapter.sourceStart, length: chapter.text.utf16.count)
        XCTAssertEqual((source as NSString).substring(with: range), chapter.text, file: file, line: line)
    }
}
