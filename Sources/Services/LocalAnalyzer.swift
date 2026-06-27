import Foundation
import NaturalLanguage
#if canImport(PDFKit)
import PDFKit
#endif
#if canImport(ImageIO)
import ImageIO
#endif
#if canImport(AVFoundation)
import AVFoundation
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

        let ext = item.pathExtension.lowercased()

        if isImage(ext: ext) {
            analysis = mergeImageMetadata(analysis: analysis, item: item)
        } else if isVideo(ext: ext) {
            analysis = await mergeVideoMetadata(analysis: analysis, item: item)
        } else {
            let text = try await extractText(for: item)
            if !text.isEmpty {
                analysis.title = inferTitle(from: text)
                analysis.tags = extractNamedEntities(from: text)
                analysis.summary = String(text.prefix(200))
                analysis.confidence = 0.7
            }
        }

        return analysis
    }

    /// 为减少文件读取次数，可先提取文本，再传入分析流程。
    /// 媒体文件（图片/视频）仍独立提取元数据；文本/PDF 直接使用传入的 text。
    func analyze(item: FileItem, text: String) async throws -> FileAnalysis {
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

        let ext = item.pathExtension.lowercased()

        if isImage(ext: ext) {
            analysis = mergeImageMetadata(analysis: analysis, item: item)
        } else if isVideo(ext: ext) {
            analysis = await mergeVideoMetadata(analysis: analysis, item: item)
        } else if !text.isEmpty {
            analysis.title = inferTitle(from: text)
            analysis.tags = extractNamedEntities(from: text)
            analysis.summary = String(text.prefix(200))
            analysis.confidence = 0.7
        }

        return analysis
    }

    nonisolated func extractText(for item: FileItem) async throws -> String {
        let ext = item.pathExtension.lowercased()
        if ext == "pdf" {
            #if canImport(PDFKit)
            return extractPDFText(url: item.url)
            #else
            return ""
            #endif
        } else if ext == "rtf" {
            return extractRTFText(url: item.url)
        } else if ["txt", "md", "swift", "py", "json", "csv"].contains(ext) {
            return (try? String(contentsOf: item.url, encoding: .utf8)) ?? ""
        } else if ["docx", "pages", "numbers", "keynote"].contains(ext) {
            return extractSpotlightText(url: item.url)
        }
        return ""
    }

    #if canImport(PDFKit)
    private nonisolated func extractPDFText(url: URL) -> String {
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

    private nonisolated func extractRTFText(url: URL) -> String {
        guard let data = try? Data(contentsOf: url),
              let attributed = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) else {
            return ""
        }
        return attributed.string
    }

    /// 通过 Spotlight (`mdls`) 提取文档文本内容，作为 docx/pages/numbers/keynote 的简易回退。
    private nonisolated func extractSpotlightText(url: URL) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdls")
        process.arguments = ["-name", "kMDItemTextContent", "-raw", url.path()]
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let string = String(data: data, encoding: .utf8) else { return "" }
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed == "(null)" ? "" : trimmed
        } catch {
            return ""
        }
    }

    private func inferTitle(from text: String) -> String? {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        return lines.first { $0.count > 5 && $0.count < 200 }
    }

    private func extractNamedEntities(from text: String) -> [String] {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var names: [String] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType, options: [.omitPunctuation, .omitWhitespace]) { tag, range in
            if tag == .personalName || tag == .organizationName || tag == .placeName {
                names.append(String(text[range]))
            }
            return true
        }
        return Array(names.prefix(10))
    }

    private func isImage(ext: String) -> Bool {
        ["jpg", "jpeg", "png", "heic", "tiff", "tif", "bmp", "gif", "webp"].contains(ext)
    }

    private func isVideo(ext: String) -> Bool {
        ["mp4", "mov", "m4v", "avi", "mkv", "wmv", "flv", "webm"].contains(ext)
    }

    /// 使用 ImageIO 提取图片 EXIF/TIFF 等元数据。
    private func mergeImageMetadata(analysis: FileAnalysis, item: FileItem) -> FileAnalysis {
        var copy = analysis
        #if canImport(ImageIO)
        guard let source = CGImageSourceCreateWithURL(item.url as CFURL, nil) else { return copy }
        let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        let exif = metadata?[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let tiff = metadata?[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        let gps = metadata?[kCGImagePropertyGPSDictionary as String] as? [String: Any]

        if let dateString = exif?[kCGImagePropertyExifDateTimeOriginal as String] as? String {
            copy.date = parseEXIFDate(dateString)
        } else if let dateString = tiff?[kCGImagePropertyTIFFDateTime as String] as? String {
            copy.date = parseEXIFDate(dateString)
        }

        var details: [String] = []
        if let make = tiff?[kCGImagePropertyTIFFMake as String] as? String {
            details.append(make)
        }
        if let model = tiff?[kCGImagePropertyTIFFModel as String] as? String {
            details.append(model)
            copy.source = model
        }
        if let width = metadata?[kCGImagePropertyPixelWidth as String] as? Int,
           let height = metadata?[kCGImagePropertyPixelHeight as String] as? Int {
            details.append("\(width)x\(height)")
        }
        if let latitude = gps?[kCGImagePropertyGPSLatitude as String] as? Double,
           let longitude = gps?[kCGImagePropertyGPSLongitude as String] as? Double {
            details.append("GPS \(latitude),\(longitude)")
        }
        if !details.isEmpty {
            copy.summary = details.joined(separator: " · ")
        }
        copy.confidence = 0.6
        #endif
        return copy
    }

    /// 使用 AVFoundation 提取视频时长、创建日期等元数据。
    private func mergeVideoMetadata(analysis: FileAnalysis, item: FileItem) async -> FileAnalysis {
        var copy = analysis
        #if canImport(AVFoundation)
        let asset = AVAsset(url: item.url)
        do {
            let duration = try await asset.load(.duration)
            if duration.isNumeric, duration.value > 0 {
                let seconds = CMTimeGetSeconds(duration)
                copy.summary = "时长 \(Int(seconds / 60)):\(String(format: "%02d", Int(seconds) % 60))"
            }
        } catch {
            // 无法读取时长则忽略。
        }

        do {
            let metadata = try await asset.load(.metadata)
            for metadataItem in metadata {
                guard let key = metadataItem.commonKey?.rawValue else { continue }
                switch key {
                case "creationDate":
                    if let dateValue = try? await metadataItem.load(.value) as? Date {
                        copy.date = dateValue
                    } else if let dateString = try? await metadataItem.load(.stringValue) {
                        copy.date = parseEXIFDate(dateString)
                    }
                case "model":
                    if let model = try? await metadataItem.load(.stringValue) {
                        copy.source = model
                    }
                default:
                    break
                }
            }
        } catch {
            // 无法读取元数据则忽略。
        }
        copy.confidence = 0.6
        #endif
        return copy
    }

    private func parseEXIFDate(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = TimeZone.current
        return formatter.date(from: string)
    }
}
