import Foundation
import PDFKit
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

/// 设备端内容提取错误。
public enum ExtractionError: LocalizedError, Sendable {
    case unsupportedLocation
    case fileRead(Error)

    public var errorDescription: String? {
        switch self {
        case .unsupportedLocation:
            return "该文件位置不支持本地提取。"
        case .fileRead:
            return "读取文件失败。"
        }
    }
}

/// 设备端内容提取：文本（PDF/RTF/mdls 回退）、SHA-256 哈希、图片 EXIF、来源 URL。
/// 沿用旧 Renamer LocalAnalyzer 的经验，但只产 ExtractedFacts，不做分类/标题推断（那是 LLM 的活）。
public struct LocalExtractor: Sendable {
    public init() {}

    public func cheapFacts(for location: FileLocation) throws -> CheapFacts {
        guard case .local(let path) = location else {
            return CheapFacts(name: "", fileExtension: "", sizeBytes: 0)
        }
        let url = URL(fileURLWithPath: path)
        do {
            let values = try url.resourceValues(forKeys: [.nameKey, .fileSizeKey,
                                                          .creationDateKey, .contentModificationDateKey,
                                                          .typeIdentifierKey])
            let fullName = values.name ?? url.lastPathComponent
            let nameWithoutExt = (fullName as NSString).deletingPathExtension
            let ext = (fullName as NSString).pathExtension.lowercased()
            let utType = values.typeIdentifier
            return CheapFacts(
                name: nameWithoutExt,
                fileExtension: ext,
                sizeBytes: Int64(values.fileSize ?? 0),
                createdAt: values.creationDate,
                modifiedAt: values.contentModificationDate,
                utType: utType
            )
        } catch {
            throw ExtractionError.fileRead(error)
        }
    }

    public func extractedFacts(for location: FileLocation) async throws -> ExtractedFacts {
        guard case .local(let path) = location else {
            return ExtractedFacts()
        }
        let url = URL(fileURLWithPath: path)
        let hash: String
        do {
            hash = try sha256HexStreaming(url: url)
        } catch {
            throw ExtractionError.fileRead(error)
        }
        let text = extractText(url: url)
        let captureDate = extractCaptureDate(url: url)
        let sourceURL = spotlightSourceURL(url: url)
        return ExtractedFacts(
            text: text,
            contentHash: hash,
            isDuplicate: false,  // 重复判定由 ExtractionProvider 在外层维护哈希集合
            captureDate: captureDate,
            sourceURL: sourceURL
        )
    }

    // MARK: - 文本提取

    private func extractText(url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf":
            return extractPDFText(url: url)
        case "rtf", "rtfd":
            return extractRTFText(url: url)
        default:
            if let data = try? Data(contentsOf: url, options: .mappedIfSafe),
               let s = String(data: data, encoding: .utf8), !s.isEmpty { return s }
            return spotlightText(url: url)
        }
    }

    private func extractPDFText(url: URL) -> String? {
        guard let doc = PDFDocument(url: url) else { return nil }
        return (0..<doc.pageCount).compactMap { doc.page(at: $0)?.string }.joined(separator: "\n")
    }

    private func extractRTFText(url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let attr = try? NSAttributedString(
                  data: data,
                  options: [.documentType: NSAttributedString.DocumentType.rtf],
                  documentAttributes: nil
              ) else { return nil }
        return attr.string
    }

    private func spotlightText(url: URL) -> String? {
        // mdls 回退：docx/iWork 等格式用 Spotlight 索引提取
        let raw = runProcess("/usr/bin/mdls", args: ["-name", "kMDItemTextContent", "-raw", url.path])
        if raw.isEmpty || raw == "(null)" { return nil }
        return raw
    }

    // MARK: - 图片 EXIF

    private func extractCaptureDate(url: URL) -> Date? {
        let imageExts: Set<String> = ["jpg", "jpeg", "heic", "png", "tiff", "raw"]
        guard imageExts.contains(url.pathExtension.lowercased()) else { return nil }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else { return nil }
        if let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any],
           let dateString = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String {
            return parseEXIFDate(dateString)
        }
        if let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any],
           let dateString = tiff[kCGImagePropertyTIFFDateTime as String] as? String {
            return parseEXIFDate(dateString)
        }
        return nil
    }

    private func parseEXIFDate(_ s: String) -> Date? {
        // EXIF 格式 "yyyy:MM:dd HH:mm:ss"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: s)
    }

    // MARK: - 来源 URL（Spotlight kMDItemWhereFroms）

    private func spotlightSourceURL(url: URL) -> String? {
        let raw = runProcess("/usr/bin/mdls", args: ["-name", "kMDItemWhereFroms", "-raw", url.path])
        if raw.isEmpty || raw == "(null)" { return nil }
        // 形如 ( "https://...", "..." )，取第一个
        let cleaned = raw.trimmingCharacters(in: CharacterSet(charactersIn: "()\n "))
            .split(separator: ",")
            .first?
            .trimmingCharacters(in: CharacterSet(charactersIn: " \""))
        return (cleaned?.isEmpty == true) ? nil : cleaned
    }

    // MARK: - 进程执行（带 5 秒超时兜底）

    private func runProcess(_ executable: String, args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
        } catch {
            return ""
        }
        // 5 秒超时兜底：定时器到点 terminate，正常则 waitUntilExit 阻塞等待（不忙等）。
        let timeout = DispatchWorkItem { [process] in
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeout)
        process.waitUntilExit()
        timeout.cancel()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // MARK: - 哈希

    /// 流式分块读取算 SHA-256，避免整文件入内存。
    private func sha256HexStreaming(url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        let chunkSize = 1 << 20  // 1 MiB
        while true {
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}