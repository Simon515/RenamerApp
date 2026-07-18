import XCTest
@testable import Sage

final class TemplateResolverTests: XCTestCase {
    private let resolver = TemplateResolver()

    private var metadata: ExtractedMetadata {
        ExtractedMetadata(title: "三月增值税发票", date: Date(timeIntervalSince1970: 1_772_236_800),
                          category: "财务/发票", tags: ["发票"], summary: nil, source: "税务局")
    }

    func test基本令牌() {
        let result = resolver.resolve("{date}-{title}", metadata: metadata, fallbackName: "原名")
        XCTAssertEqual(result, "2026-02-28-三月增值税发票")
    }

    func test自定义日期格式() {
        let result = resolver.resolve("{date:yyyy}/{date:MM}/{title}", metadata: metadata, fallbackName: "原名")
        XCTAssertEqual(result, "2026/02/三月增值税发票")
    }

    func test日期格式内含斜杠_按数据清洗不产生子目录() {
        // 想用日期分目录应写 {date:yyyy}/{date:MM}；格式串内部的 "/" 是数据，清洗为 "-"
        let result = resolver.resolve("{date:yyyy/MM}", metadata: metadata, fallbackName: "原名")
        XCTAssertEqual(result, "2026-02")
    }

    func testTitle缺失回退原文件名() {
        var meta = metadata
        meta.title = nil
        let result = resolver.resolve("{title}", metadata: meta, fallbackName: "原名")
        XCTAssertEqual(result, "原名")
    }

    func test其余令牌缺失为空串() {
        var meta = metadata
        meta.source = nil
        let result = resolver.resolve("{title}-{source}", metadata: meta, fallbackName: "原名")
        XCTAssertEqual(result, "三月增值税发票-")
    }

    func test令牌值中的斜杠被清洗_模板中的斜杠保留() {
        // category 值内的 "/" 是数据，须清洗为 "-"；模板里显式写的 "/" 是子目录
        let result = resolver.resolve("{category}/{title}", metadata: metadata, fallbackName: "原名")
        XCTAssertEqual(result, "财务-发票/三月增值税发票")
    }

    func test未知令牌原样保留() {
        let result = resolver.resolve("{unknown}-{title}", metadata: metadata, fallbackName: "原名")
        XCTAssertEqual(result, "{unknown}-三月增值税发票")
    }
}