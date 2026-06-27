import Foundation
import NaturalLanguage
#if canImport(PDFKit)
import PDFKit
#endif

actor LocalAnalyzer {
    func analyze(item: FileItem) async throws -> FileAnalysis {
        var analysis = FileAnalysis(
            id: item.id,
            title: nil,
            date: item.creationDate ?? item.modificationDate,
            category: nil,
            tags: [],
            source: nil,
            summary: nil,
            confidence: 0.5
        )

        let text = try await extractText(for: item)
        if !text.isEmpty {
            analysis.title = inferTitle(from: text)
            analysis.tags = extractKeywords(from: text)
            analysis.summary = String(text.prefix(200))
            analysis.confidence = 0.7
        }

        return analysis
    }

    private func extractText(for item: FileItem) async throws -> String {
        let ext = item.pathExtension.lowercased()
        if ext == "pdf" {
            #if canImport(PDFKit)
            return extractPDFText(url: item.url)
            #else
            return ""
            #endif
        } else if ["txt", "md", "swift", "py", "json", "csv"].contains(ext) {
            return (try? String(contentsOf: item.url, encoding: .utf8)) ?? ""
        }
        return ""
    }

    #if canImport(PDFKit)
    private func extractPDFText(url: URL) -> String {
        guard let doc = PDFDocument(url: url) else { return "" }
        var text = ""
        let pages = min(doc.pageCount, 10)
        for i in 0..<pages {
            text += doc.page(at: i)?.string ?? ""
            text += "\n"
        }
        return text
    }
    #endif

    private func inferTitle(from text: String) -> String? {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        return lines.first { $0.count > 5 && $0.count < 200 }
    }

    private func extractKeywords(from text: String) -> [String] {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var keywords: [String] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType, options: [.omitPunctuation, .omitWhitespace]) { tag, range in
            if tag == .personalName || tag == .organizationName || tag == .placeName {
                keywords.append(String(text[range]))
            }
            return true
        }
        return Array(keywords.prefix(10))
    }
}
