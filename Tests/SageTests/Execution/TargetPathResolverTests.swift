import XCTest
@testable import Sage

final class TargetPathResolverTests: XCTestCase {
    private func meta(title: String?) -> ExtractedMetadata { ExtractedMetadata(title: title) }

    func test基本目标路径_补源扩展名() {
        let resolver = TargetPathResolver(fileExists: { _ in false })
        let path = resolver.resolveDestination(baseDirectory: "/out", template: "{title}",
                                               sourceName: "扫描件.pdf", metadata: meta(title: "发票2026"))
        XCTAssertEqual(path, "/out/发票2026.pdf")
    }

    func test模板含子目录() {
        let resolver = TargetPathResolver(fileExists: { _ in false })
        let path = resolver.resolveDestination(baseDirectory: "/out", template: "{title}",
                                               sourceName: "a.pdf", metadata: meta(title: "财务/发票"))
        // TemplateResolver 会把令牌值内的 "/" 清洗为 "-"，故不产生子目录
        XCTAssertEqual(path, "/out/财务-发票.pdf")
    }

    func testTitle缺失回退源文件主干() {
        let resolver = TargetPathResolver(fileExists: { _ in false })
        let path = resolver.resolveDestination(baseDirectory: "/out", template: "{title}",
                                               sourceName: "原始名.jpg", metadata: meta(title: nil))
        XCTAssertEqual(path, "/out/原始名.jpg")
    }

    func test防重名_加序号跳过已存在() {
        let taken: Set<String> = ["/out/发票.pdf", "/out/发票 2.pdf"]
        let resolver = TargetPathResolver(fileExists: { taken.contains($0) })
        let path = resolver.resolveDestination(baseDirectory: "/out", template: "{title}",
                                               sourceName: "x.pdf", metadata: meta(title: "发票"))
        XCTAssertEqual(path, "/out/发票 3.pdf")
    }

    func testRename同目录() {
        let resolver = TargetPathResolver(fileExists: { _ in false })
        let path = resolver.resolveRename(inDirectoryOf: "/in/sub/old.pdf", template: "{title}",
                                          metadata: meta(title: "新名"))
        XCTAssertEqual(path, "/in/sub/新名.pdf")
    }

    func test无扩展名不补点() {
        let resolver = TargetPathResolver(fileExists: { _ in false })
        let path = resolver.resolveDestination(baseDirectory: "/out", template: "{title}",
                                               sourceName: "README", metadata: meta(title: "读我"))
        XCTAssertEqual(path, "/out/读我")
    }
}
