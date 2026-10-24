import Foundation
import XCTest

#if canImport(CoreGraphics)
    import CoreGraphics
#endif

@testable import MoxuCore

final class ComicPaginationTests: XCTestCase {
    func testEveryModeKeepsEveryPanelOnceAndInOriginalOrder() {
        for perPage in ComicPagination.supportedPanelsPerPage {
            for total in 0...33 {
                let pages = ComicPagination.pages(panelCount: total, panelsPerPage: perPage)
                XCTAssertEqual(pages.flatMap { $0 }, Array(0..<total))
                XCTAssertEqual(pages.count, (total + perPage - 1) / perPage)
                XCTAssertTrue(pages.allSatisfy { !$0.isEmpty && $0.count <= perPage })
                XCTAssertTrue(pages.dropLast().allSatisfy { $0.count == perPage })
            }
        }
    }

    func testFinalPartialPageRetainsUngeneratedPanelPositions() {
        // Pagination depends only on storyboard count, including panels without images.
        XCTAssertEqual(ComicPagination.pages(panelCount: 7, panelsPerPage: 4), [[0, 1, 2, 3], [4, 5, 6]])
        XCTAssertEqual(ComicPagination.pages(panelCount: 5, panelsPerPage: 2), [[0, 1], [2, 3], [4]])
        XCTAssertEqual(ComicPagination.pages(panelCount: 3, panelsPerPage: 1), [[0], [1], [2]])
        XCTAssertEqual(ComicPagination.pages(panelCount: -1, panelsPerPage: 4), [])
    }

    func testUnsupportedPageSizeUsesFourPanels() {
        XCTAssertEqual(ComicPagination.normalizedPanelsPerPage(0), 4)
        XCTAssertEqual(ComicPagination.normalizedPanelsPerPage(3), 4)
        XCTAssertEqual(ComicPagination.pages(panelCount: 5, panelsPerPage: Int.max), [[0, 1, 2, 3], [4]])
    }

    func testCellOrderAndGapInAnOffsetPage() {
        let bounds = CGRect(x: 64, y: 142, width: 1042, height: 1418)
        XCTAssertEqual(ComicPagination.cells(panelsPerPage: 1, in: bounds, gap: 24), [bounds])
        let two = ComicPagination.cells(panelsPerPage: 2, in: bounds, gap: 24)
        XCTAssertEqual(two, [CGRect(x: 64, y: 142, width: 1042, height: 697),
                             CGRect(x: 64, y: 863, width: 1042, height: 697)])
        let four = ComicPagination.cells(panelsPerPage: 4, in: bounds, gap: 24)
        XCTAssertEqual(four, [CGRect(x: 64, y: 142, width: 509, height: 697),
                              CGRect(x: 597, y: 142, width: 509, height: 697),
                              CGRect(x: 64, y: 863, width: 509, height: 697),
                              CGRect(x: 597, y: 863, width: 509, height: 697)])
    }

    func testCellsAndFittedImagesStayInsideThePageWithoutOverlap() {
        let bounds = CGRect(x: 17, y: 35, width: 1042, height: 1418)
        let imageSizes = [CGSize(width: 1024, height: 1536), CGSize(width: 1600, height: 900),
                          CGSize(width: 100, height: 100), CGSize(width: 1, height: 8000),
                          CGSize(width: 8000, height: 1)]
        for count in ComicPagination.supportedPanelsPerPage {
            let cells = ComicPagination.cells(panelsPerPage: count, in: bounds, gap: 24)
            XCTAssertEqual(cells.count, count)
            for (index, cell) in cells.enumerated() {
                assertContained(cell, in: bounds)
                for next in cells.dropFirst(index + 1) { XCTAssertFalse(cell.intersects(next)) }
                for size in imageSizes {
                    let image = ComicPagination.aspectFit(imageSize: size, in: cell)
                    assertContained(image, in: cell)
                    XCTAssertEqual(image.midX, cell.midX, accuracy: 0.000001)
                    XCTAssertEqual(image.midY, cell.midY, accuracy: 0.000001)
                    XCTAssertEqual(image.width / image.height, size.width / size.height, accuracy: 0.000001)
                    XCTAssertTrue(abs(image.width - cell.width) < 0.000001 || abs(image.height - cell.height) < 0.000001)
                }
            }
        }
    }

    func testInvalidGeometryCannotCreateNaNOrNegativeSizes() {
        let bounds = CGRect(x: 11, y: 19, width: 30, height: 40)
        for gap: CGFloat in [-10, .nan, .infinity, 1000] {
            for count in [1, 2, 4] {
                for cell in ComicPagination.cells(panelsPerPage: count, in: bounds, gap: gap) {
                    assertContained(cell, in: bounds)
                }
            }
        }
        for size in [CGSize.zero, CGSize(width: -1, height: 4), CGSize(width: CGFloat.nan, height: 1),
                     CGSize(width: 1, height: CGFloat.infinity)] {
            let rect = ComicPagination.aspectFit(imageSize: size, in: bounds)
            XCTAssertEqual(rect, CGRect(x: bounds.midX, y: bounds.midY, width: 0, height: 0))
        }
        for invalid in [CGRect.zero, CGRect(x: 0, y: 0, width: -1, height: 5),
                        CGRect(x: CGFloat.nan, y: 0, width: 4, height: 5)] {
            XCTAssertEqual(ComicPagination.cells(panelsPerPage: 4, in: invalid, gap: 2), Array(repeating: .zero, count: 4))
            XCTAssertEqual(ComicPagination.aspectFit(imageSize: CGSize(width: 2, height: 3), in: invalid), .zero)
        }
    }

    private func assertContained(_ rect: CGRect, in bounds: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(rect.minX.isFinite && rect.minY.isFinite && rect.width.isFinite && rect.height.isFinite,
                      file: file, line: line)
        XCTAssertGreaterThanOrEqual(rect.width, 0, file: file, line: line)
        XCTAssertGreaterThanOrEqual(rect.height, 0, file: file, line: line)
        XCTAssertGreaterThanOrEqual(rect.minX, bounds.minX - 0.000001, file: file, line: line)
        XCTAssertGreaterThanOrEqual(rect.minY, bounds.minY - 0.000001, file: file, line: line)
        XCTAssertLessThanOrEqual(rect.maxX, bounds.maxX + 0.000001, file: file, line: line)
        XCTAssertLessThanOrEqual(rect.maxY, bounds.maxY + 0.000001, file: file, line: line)
    }
}
