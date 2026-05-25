import AppKit
import Foundation
import PDFKit
import Vision

enum CLIError: Error, CustomStringConvertible {
    case usage(String)
    case message(String)

    var description: String {
        switch self {
        case .usage(let value), .message(let value):
            return value
        }
    }
}

struct PageSummary: Codable {
    let page: Int
    let charCount: Int
    let wordCount: Int
    let lineCount: Int
    let width: Double
    let height: Double
}

struct InspectTextOutput: Codable {
    let file: String
    let pageCount: Int
    let totalChars: Int
    let pages: [PageSummary]
}

struct RenderPageOutput: Codable {
    let file: String
    let page: Int
    let outputPath: String
    let cropBoxNorm: [Double]?
    let outputPx: [Int]
    let shortSidePx: Int
}

struct ExtractPageOutput: Codable {
    let file: String
    let page: Int
    let outputPath: String
}

struct CropImageOutput: Codable {
    let image: String
    let outputPath: String
    let cropBoxNorm: [Double]
    let outputPx: [Int]
}

struct SaveRegionOutput: Codable {
    let sourceType: String
    let sourcePath: String
    let outputPath: String
    let cropBoxNorm: [Double]
    let outputPx: [Int]
}

struct OCRLine: Codable {
    let text: String
    let confidence: Float
    let bboxNorm: [Double]
}

struct OCROutput: Codable {
    let image: String
    let cropBoxNorm: [Double]?
    let lineCount: Int
    let text: String
    let lines: [OCRLine]
}

struct OCRRegion: Codable {
    let id: String
    let bboxNorm: [Double]
    let lineCount: Int
    let textExcerpt: String
}

struct PDFReadPageOutput: Codable {
    let page: Int
    let textSource: String
    let text: String?
    let previewImagePath: String?
    let previewImagePx: [Int]?
    let regions: [OCRRegion]
}

struct PDFReadContinuation: Codable {
    let hasMore: Bool
    let nextPages: String?
}

struct PDFReadOutput: Codable {
    let file: String
    let requestedPages: String
    let mode: String
    let engine: String
    let batchSize: Int
    let imageScale: Int
    let pageCount: Int
    let returnedPages: [PDFReadPageOutput]
    let continuation: PDFReadContinuation
}

struct PDFFocusOutput: Codable {
    let file: String
    let page: Int
    let bboxNorm: [Double]
    let mode: String
    let engine: String
    let textSource: String
    let text: String?
    let detailImagePath: String?
    let detailImagePx: [Int]?
    let regions: [OCRRegion]
}

struct OCRDetectRegionsOutput: Codable {
    let image: String
    let cropBoxNorm: [Double]?
    let lineCount: Int
    let lines: [OCRLine]
    let regions: [OCRRegion]
}

struct MCPToolExecution {
    let structuredContent: [String: Any]
    let text: String
    let imagePaths: [String]
}

enum Command: String {
    case inspectText = "inspect-text"
    case mcpStdio = "mcp-stdio"
    case pdfRead = "pdf-read"
    case pdfFocus = "pdf-focus"
    case extractPage = "extract-page"
    case renderPage = "render-page"
    case cropImage = "crop-image"
    case saveRegion = "save-region"
    case ocrImage = "ocr-image"
    case ocrDetectRegions = "ocr-detect-regions"
}

struct CLI {
    static func run(arguments: [String]) throws {
        guard let rawCommand = arguments.first, let command = Command(rawValue: rawCommand) else {
            throw CLIError.usage(usageText)
        }

        switch command {
        case .inspectText:
            try runInspectText(arguments: Array(arguments.dropFirst()))
        case .mcpStdio:
            try MCPStdIOServer.run()
        case .pdfRead:
            try runPDFRead(arguments: Array(arguments.dropFirst()))
        case .pdfFocus:
            try runPDFFocus(arguments: Array(arguments.dropFirst()))
        case .extractPage:
            try runExtractPage(arguments: Array(arguments.dropFirst()))
        case .renderPage:
            try runRenderPage(arguments: Array(arguments.dropFirst()))
        case .cropImage:
            try runCropImage(arguments: Array(arguments.dropFirst()))
        case .saveRegion:
            try runSaveRegion(arguments: Array(arguments.dropFirst()))
        case .ocrImage:
            try runOCRImage(arguments: Array(arguments.dropFirst()))
        case .ocrDetectRegions:
            try runOCRDetectRegions(arguments: Array(arguments.dropFirst()))
        }
    }

    private static func runInspectText(arguments: [String]) throws {
        guard arguments.count == 1 else {
            throw CLIError.usage("Usage: macpdf-ocr-mcp inspect-text <pdf-path>")
        }

        let pdfPath = arguments[0]
        guard let document = PDFDocument(url: URL(fileURLWithPath: pdfPath)) else {
            throw CLIError.message("Unable to open PDF: \(pdfPath)")
        }

        let pages: [PageSummary] = (0..<document.pageCount).compactMap { index in
            guard let page = document.page(at: index) else { return nil }
            let text = page.string ?? ""
            let lines = text.split(whereSeparator: \.isNewline)
            let words = text.split(whereSeparator: \.isWhitespace)
            let bounds = page.bounds(for: .mediaBox)
            return PageSummary(
                page: index + 1,
                charCount: text.count,
                wordCount: words.count,
                lineCount: lines.count,
                width: bounds.width,
                height: bounds.height
            )
        }

        let output = InspectTextOutput(
            file: pdfPath,
            pageCount: document.pageCount,
            totalChars: pages.reduce(0) { $0 + $1.charCount },
            pages: pages
        )

        try printJSON(output)
    }

    private static func runExtractPage(arguments: [String]) throws {
        guard arguments.count == 3 else {
            throw CLIError.usage("Usage: macpdf-ocr-mcp extract-page <pdf-path> <page> <output-path>")
        }

        let pdfPath = arguments[0]
        let pageNumber = try parsePositiveInt(arguments[1], name: "page")
        let outputPath = arguments[2]

        guard let document = PDFDocument(url: URL(fileURLWithPath: pdfPath)),
              let page = document.page(at: pageNumber - 1) else {
            throw CLIError.message("Unable to open PDF page \(pageNumber): \(pdfPath)")
        }

        let outputDocument = PDFDocument()
        guard let pageCopy = page.copy() as? PDFPage else {
            throw CLIError.message("Unable to copy PDF page \(pageNumber)")
        }
        outputDocument.insert(pageCopy, at: 0)

        let outputURL = URL(fileURLWithPath: outputPath)
        let outputDirectory = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        guard outputDocument.write(to: outputURL) else {
            throw CLIError.message("Unable to write extracted PDF page to \(outputPath)")
        }

        try printJSON(
            ExtractPageOutput(
                file: pdfPath,
                page: pageNumber,
                outputPath: outputPath
            )
        )
    }

    private static func runRenderPage(arguments: [String]) throws {
        guard arguments.count >= 4 else {
            throw CLIError.usage(
                "Usage: macpdf-ocr-mcp render-page <pdf-path> <page> <short-side-px> <output-path> [x y w h]"
            )
        }

        let pdfPath = arguments[0]
        let pageNumber = try parsePositiveInt(arguments[1], name: "page")
        let shortSidePx = try parsePositiveInt(arguments[2], name: "short-side-px")
        let outputPath = arguments[3]

        let cropBoxNorm: [Double]?
        if arguments.count == 8 {
            cropBoxNorm = try arguments[4...7].map(parseNormalizedComponent)
        } else if arguments.count == 4 {
            cropBoxNorm = nil
        } else {
            throw CLIError.usage(
                "Usage: macpdf-ocr-mcp render-page <pdf-path> <page> <short-side-px> <output-path> [x y w h]"
            )
        }

        let rendered = try renderPage(
            pdfPath: pdfPath,
            pageNumber: pageNumber,
            shortSidePx: shortSidePx,
            cropBoxNorm: cropBoxNorm
        )

        try writeData(rendered.data, to: outputPath)

        let output = RenderPageOutput(
            file: pdfPath,
            page: pageNumber,
            outputPath: outputPath,
            cropBoxNorm: cropBoxNorm,
            outputPx: [rendered.width, rendered.height],
            shortSidePx: shortSidePx
        )

        try printJSON(output)
    }

    private static func runCropImage(arguments: [String]) throws {
        guard arguments.count == 6 else {
            throw CLIError.usage(
                "Usage: macpdf-ocr-mcp crop-image <image-path> <output-path> <x> <y> <w> <h>"
            )
        }

        let imagePath = arguments[0]
        let outputPath = arguments[1]
        let cropBoxNorm = try arguments[2...5].map(parseNormalizedComponent)

        let rendered = try cropImage(imagePath: imagePath, cropBoxNorm: cropBoxNorm)
        try writeData(rendered.data, to: outputPath)

        let output = CropImageOutput(
            image: imagePath,
            outputPath: outputPath,
            cropBoxNorm: cropBoxNorm,
            outputPx: [rendered.width, rendered.height]
        )

        try printJSON(output)
    }

    private static func runPDFRead(arguments: [String]) throws {
        guard arguments.count >= 2, arguments.count <= 6 else {
            throw CLIError.usage(
                "Usage: macpdf-ocr-mcp pdf-read <pdf-path> <pages> [mode] [engine] [batch-size] [image-scale]"
            )
        }

        let pdfPath = arguments[0]
        let pageSpec = arguments[1]
        let mode = try parseMode(arguments.count >= 3 ? arguments[2] : "balanced")
        let engine = try parseEngine(arguments.count >= 4 ? arguments[3] : "auto")
        let batchSize = try parsePositiveInt(arguments.count >= 5 ? arguments[4] : "4", name: "batch-size")
        let imageScale = try parseScale(arguments.count >= 6 ? arguments[5] : "5")

        guard let document = PDFDocument(url: URL(fileURLWithPath: pdfPath)) else {
            throw CLIError.message("Unable to open PDF: \(pdfPath)")
        }

        let selectedPages = try parsePageSpec(pageSpec, pageCount: document.pageCount)
        let chunk = Array(selectedPages.prefix(batchSize))
        let remaining = Array(selectedPages.dropFirst(chunk.count))

        let returnedPages = try chunk.map { pageNumber in
            try buildPDFReadPage(
                document: document,
                pdfPath: pdfPath,
                pageNumber: pageNumber,
                mode: mode,
                engine: engine,
                imageScale: imageScale
            )
        }

        let continuation = PDFReadContinuation(
            hasMore: !remaining.isEmpty,
            nextPages: remaining.isEmpty ? nil : compactPageSpec(for: remaining)
        )

        let output = PDFReadOutput(
            file: pdfPath,
            requestedPages: pageSpec,
            mode: mode,
            engine: engine,
            batchSize: batchSize,
            imageScale: imageScale,
            pageCount: document.pageCount,
            returnedPages: returnedPages,
            continuation: continuation
        )

        try printJSON(output)
    }

    private static func runPDFFocus(arguments: [String]) throws {
        guard arguments.count >= 6, arguments.count <= 9 else {
            throw CLIError.usage(
                "Usage: macpdf-ocr-mcp pdf-focus <pdf-path> <page> <x> <y> <w> <h> [mode] [engine] [image-scale]"
            )
        }

        let pdfPath = arguments[0]
        let pageNumber = try parsePositiveInt(arguments[1], name: "page")
        let bboxNorm = try arguments[2...5].map(parseNormalizedComponent)
        let mode = try parseMode(arguments.count >= 7 ? arguments[6] : "balanced")
        let engine = try parseEngine(arguments.count >= 8 ? arguments[7] : "auto")
        let imageScale = try parseScale(arguments.count >= 9 ? arguments[8] : "7")

        guard let document = PDFDocument(url: URL(fileURLWithPath: pdfPath)),
              document.page(at: pageNumber - 1) != nil else {
            throw CLIError.message("Unable to open PDF page \(pageNumber): \(pdfPath)")
        }

        let output = try buildPDFFocusOutput(
            document: document,
            pdfPath: pdfPath,
            pageNumber: pageNumber,
            bboxNorm: bboxNorm,
            mode: mode,
            engine: engine,
            imageScale: imageScale
        )

        try printJSON(output)
    }

    private static func runSaveRegion(arguments: [String]) throws {
        guard arguments.count == 7 || arguments.count == 9 else {
            throw CLIError.usage(
                """
                Usage:
                  macpdf-ocr-mcp save-region image <image-path> <output-path> <x> <y> <w> <h>
                  macpdf-ocr-mcp save-region pdf <pdf-path> <page> <short-side-px> <output-path> <x> <y> <w> <h>
                """
            )
        }

        let sourceType = arguments[0]

        switch sourceType {
        case "image":
            guard arguments.count == 7 else {
                throw CLIError.usage(
                    "Usage: macpdf-ocr-mcp save-region image <image-path> <output-path> <x> <y> <w> <h>"
                )
            }
            let imagePath = arguments[1]
            let outputPath = arguments[2]
            let cropBoxNorm = try arguments[3...6].map(parseNormalizedComponent)
            let rendered = try cropImage(imagePath: imagePath, cropBoxNorm: cropBoxNorm)
            try writeData(rendered.data, to: outputPath)

            let output = SaveRegionOutput(
                sourceType: "image",
                sourcePath: imagePath,
                outputPath: outputPath,
                cropBoxNorm: cropBoxNorm,
                outputPx: [rendered.width, rendered.height]
            )
            try printJSON(output)

        case "pdf":
            guard arguments.count == 9 else {
                throw CLIError.usage(
                    "Usage: macpdf-ocr-mcp save-region pdf <pdf-path> <page> <short-side-px> <output-path> <x> <y> <w> <h>"
                )
            }
            let pdfPath = arguments[1]
            let pageNumber = try parsePositiveInt(arguments[2], name: "page")
            let shortSidePx = try parsePositiveInt(arguments[3], name: "short-side-px")
            let outputPath = arguments[4]
            let cropBoxNorm = try arguments[5...8].map(parseNormalizedComponent)
            let rendered = try renderPage(
                pdfPath: pdfPath,
                pageNumber: pageNumber,
                shortSidePx: shortSidePx,
                cropBoxNorm: cropBoxNorm
            )
            try writeData(rendered.data, to: outputPath)

            let output = SaveRegionOutput(
                sourceType: "pdf",
                sourcePath: pdfPath,
                outputPath: outputPath,
                cropBoxNorm: cropBoxNorm,
                outputPx: [rendered.width, rendered.height]
            )
            try printJSON(output)

        default:
            throw CLIError.message("source-type must be either 'image' or 'pdf'")
        }
    }

    private static func runOCRImage(arguments: [String]) throws {
        guard arguments.count == 1 || arguments.count == 5 else {
            throw CLIError.usage("Usage: macpdf-ocr-mcp ocr-image <image-path> [x y w h]")
        }

        let imagePath = arguments[0]
        let cropBoxNorm: [Double]?
        if arguments.count == 5 {
            cropBoxNorm = try arguments[1...4].map(parseNormalizedComponent)
        } else {
            cropBoxNorm = nil
        }

        let output = try runVisionOCR(imagePath: imagePath, cropBoxNorm: cropBoxNorm)
        try printJSON(output)
    }

    private static func runOCRDetectRegions(arguments: [String]) throws {
        guard arguments.count == 1 || arguments.count == 5 else {
            throw CLIError.usage("Usage: macpdf-ocr-mcp ocr-detect-regions <image-path> [x y w h]")
        }

        let imagePath = arguments[0]
        let cropBoxNorm: [Double]?
        if arguments.count == 5 {
            cropBoxNorm = try arguments[1...4].map(parseNormalizedComponent)
        } else {
            cropBoxNorm = nil
        }

        let output = try runVisionOCRDetectRegions(imagePath: imagePath, cropBoxNorm: cropBoxNorm)
        try printJSON(output)
    }

    private static func buildPDFReadPage(
        document: PDFDocument,
        pdfPath: String,
        pageNumber: Int,
        mode: String,
        engine: String,
        imageScale: Int
    ) throws -> PDFReadPageOutput {
        guard let page = document.page(at: pageNumber - 1) else {
            throw CLIError.message("Unable to open PDF page \(pageNumber): \(pdfPath)")
        }

        let previewInfo: (path: String, px: [Int])?
        if mode != "text_only" {
            let previewShortSide = previewShortSidePx(mode: mode, imageScale: imageScale)
            let rendered = try renderPage(
                pdfPath: pdfPath,
                pageNumber: pageNumber,
                shortSidePx: previewShortSide,
                cropBoxNorm: nil
            )
            let previewPath = try makeRuntimeOutputPath(prefix: "pdf-read-p\(pageNumber)", ext: "png")
            try writeData(rendered.data, to: previewPath)
            previewInfo = (previewPath, [rendered.width, rendered.height])
        } else {
            previewInfo = nil
        }

        let textExtraction: (source: String, text: String, lines: [OCRLine])
        if mode == "image_only" {
            textExtraction = ("none", "", [])
        } else {
            textExtraction = try extractPageText(
                page: page,
                pdfPath: pdfPath,
                pageNumber: pageNumber,
                engine: engine,
                imageScale: imageScale
            )
        }

        let regions = detectRegions(from: textExtraction.lines)
        let text: String?
        if mode == "image_only" {
            text = nil
        } else {
            text = textExtraction.text.isEmpty ? nil : textExtraction.text
        }

        return PDFReadPageOutput(
            page: pageNumber,
            textSource: textExtraction.source,
            text: text,
            previewImagePath: previewInfo?.path,
            previewImagePx: previewInfo?.px,
            regions: regions
        )
    }

    private static func buildPDFFocusOutput(
        document: PDFDocument,
        pdfPath: String,
        pageNumber: Int,
        bboxNorm: [Double],
        mode: String,
        engine: String,
        imageScale: Int
    ) throws -> PDFFocusOutput {
        guard let page = document.page(at: pageNumber - 1) else {
            throw CLIError.message("Unable to open PDF page \(pageNumber): \(pdfPath)")
        }

        let detailInfo: (path: String, px: [Int])?
        if mode != "text_only" {
            let detailShortSide = focusShortSidePx(mode: mode, imageScale: imageScale)
            let rendered = try renderPage(
                pdfPath: pdfPath,
                pageNumber: pageNumber,
                shortSidePx: detailShortSide,
                cropBoxNorm: bboxNorm
            )
            let detailPath = try makeRuntimeOutputPath(prefix: "pdf-focus-p\(pageNumber)", ext: "png")
            try writeData(rendered.data, to: detailPath)
            detailInfo = (detailPath, [rendered.width, rendered.height])
        } else {
            detailInfo = nil
        }

        let textExtraction: (source: String, text: String, lines: [OCRLine])
        if mode == "image_only" {
            textExtraction = ("none", "", [])
        } else {
            textExtraction = try extractFocusedText(
                page: page,
                pdfPath: pdfPath,
                pageNumber: pageNumber,
                bboxNorm: bboxNorm,
                engine: engine,
                imageScale: imageScale
            )
        }

        let regions = detectRegions(from: textExtraction.lines)
        let text: String?
        if mode == "image_only" {
            text = nil
        } else {
            text = textExtraction.text.isEmpty ? nil : textExtraction.text
        }

        return PDFFocusOutput(
            file: pdfPath,
            page: pageNumber,
            bboxNorm: bboxNorm,
            mode: mode,
            engine: engine,
            textSource: textExtraction.source,
            text: text,
            detailImagePath: detailInfo?.path,
            detailImagePx: detailInfo?.px,
            regions: regions
        )
    }

    private static func extractPageText(
        page: PDFPage,
        pdfPath: String,
        pageNumber: Int,
        engine: String,
        imageScale: Int
    ) throws -> (source: String, text: String, lines: [OCRLine]) {
        let pdfLines = extractPDFLines(page: page)
        let pdfText = pdfLines.map(\.text).joined(separator: "\n")
        let hasPDFText = !pdfText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        switch engine {
        case "pdfkit":
            return ("pdfkit", pdfText, pdfLines)
        case "ocr":
            return try extractPageTextViaOCR(pdfPath: pdfPath, pageNumber: pageNumber, bboxNorm: nil, imageScale: max(7, imageScale))
        case "hybrid":
            if hasPDFText {
                return ("hybrid", pdfText, pdfLines)
            }
            return try extractPageTextViaOCR(pdfPath: pdfPath, pageNumber: pageNumber, bboxNorm: nil, imageScale: max(7, imageScale))
        case "auto":
            if hasPDFText {
                return ("pdfkit", pdfText, pdfLines)
            }
            return try extractPageTextViaOCR(pdfPath: pdfPath, pageNumber: pageNumber, bboxNorm: nil, imageScale: max(7, imageScale))
        default:
            throw CLIError.message("Unsupported engine: \(engine)")
        }
    }

    private static func extractFocusedText(
        page: PDFPage,
        pdfPath: String,
        pageNumber: Int,
        bboxNorm: [Double],
        engine: String,
        imageScale: Int
    ) throws -> (source: String, text: String, lines: [OCRLine]) {
        let allPDFLines = extractPDFLines(page: page)
        let filteredPDFLines = allPDFLines.filter { intersects($0.bboxNorm, bboxNorm) }
        let filteredText = filteredPDFLines.map(\.text).joined(separator: "\n")
        let hasPDFText = !filteredText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        switch engine {
        case "pdfkit":
            return ("pdfkit", filteredText, filteredPDFLines)
        case "ocr":
            return try extractPageTextViaOCR(pdfPath: pdfPath, pageNumber: pageNumber, bboxNorm: bboxNorm, imageScale: max(7, imageScale))
        case "hybrid":
            if hasPDFText {
                return ("hybrid", filteredText, filteredPDFLines)
            }
            return try extractPageTextViaOCR(pdfPath: pdfPath, pageNumber: pageNumber, bboxNorm: bboxNorm, imageScale: max(7, imageScale))
        case "auto":
            if hasPDFText {
                return ("pdfkit", filteredText, filteredPDFLines)
            }
            return try extractPageTextViaOCR(pdfPath: pdfPath, pageNumber: pageNumber, bboxNorm: bboxNorm, imageScale: max(7, imageScale))
        default:
            throw CLIError.message("Unsupported engine: \(engine)")
        }
    }

    private static func extractPageTextViaOCR(
        pdfPath: String,
        pageNumber: Int,
        bboxNorm: [Double]?,
        imageScale: Int
    ) throws -> (source: String, text: String, lines: [OCRLine]) {
        let shortSide = focusShortSidePx(mode: "image_focus", imageScale: imageScale)
        let rendered = try renderPage(
            pdfPath: pdfPath,
            pageNumber: pageNumber,
            shortSidePx: shortSide,
            cropBoxNorm: bboxNorm
        )
        let tempPath = try makeRuntimeOutputPath(prefix: "ocr-page-p\(pageNumber)", ext: "png")
        try writeData(rendered.data, to: tempPath)
        let lines = try runVisionOCRLines(imagePath: tempPath, cropBoxNorm: nil)
        return ("vision", lines.map(\.text).joined(separator: "\n"), lines)
    }

    private static func extractPDFLines(page: PDFPage) -> [OCRLine] {
        guard let pageText = page.string, !pageText.isEmpty else {
            return []
        }

        let nsText = pageText as NSString
        guard let selection = page.selection(for: NSRange(location: 0, length: nsText.length)) else {
            return []
        }

        let pageBounds = page.bounds(for: .mediaBox)

        return selection.selectionsByLine().compactMap { lineSelection in
            let text = (lineSelection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let rect = lineSelection.bounds(for: page)
            guard rect.width > 0, rect.height > 0 else { return nil }
            return OCRLine(
                text: text,
                confidence: 1,
                bboxNorm: normalizePDFRect(rect, pageBounds: pageBounds)
            )
        }
    }

    private static func runVisionOCR(imagePath: String, cropBoxNorm: [Double]?) throws -> OCROutput {
        let lines = try runVisionOCRLines(imagePath: imagePath, cropBoxNorm: cropBoxNorm)

        return OCROutput(
            image: imagePath,
            cropBoxNorm: cropBoxNorm,
            lineCount: lines.count,
            text: lines.map(\.text).joined(separator: "\n"),
            lines: lines
        )
    }

    private static func runVisionOCRDetectRegions(imagePath: String, cropBoxNorm: [Double]?) throws -> OCRDetectRegionsOutput {
        let lines = try runVisionOCRLines(imagePath: imagePath, cropBoxNorm: cropBoxNorm)
        let regions = detectRegions(from: lines)

        return OCRDetectRegionsOutput(
            image: imagePath,
            cropBoxNorm: cropBoxNorm,
            lineCount: lines.count,
            lines: lines,
            regions: regions
        )
    }

    private static func runVisionOCRLines(imagePath: String, cropBoxNorm: [Double]?) throws -> [OCRLine] {
        guard let image = NSImage(contentsOfFile: imagePath),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw CLIError.message("Unable to load image for OCR: \(imagePath)")
        }

        let ocrImage: CGImage
        if let cropBoxNorm {
            ocrImage = try cropCGImage(cgImage, cropBoxNorm: cropBoxNorm)
        } else {
            ocrImage = cgImage
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]

        let handler = VNImageRequestHandler(cgImage: ocrImage)
        try handler.perform([request])

        let lines: [OCRLine] = (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            return OCRLine(
                text: candidate.string,
                confidence: candidate.confidence,
                bboxNorm: [
                    Double(box.origin.x),
                    Double(1 - box.origin.y - box.height),
                    Double(box.width),
                    Double(box.height)
                ]
            )
        }

        return lines
    }

    private static func cropImage(imagePath: String, cropBoxNorm: [Double]) throws -> (data: Data, width: Int, height: Int) {
        guard let image = NSImage(contentsOfFile: imagePath),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw CLIError.message("Unable to load image for crop: \(imagePath)")
        }

        let cropped = try cropCGImage(cgImage, cropBoxNorm: cropBoxNorm)
        let rep = NSBitmapImageRep(cgImage: cropped)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw CLIError.message("Unable to encode cropped image")
        }

        return (png, cropped.width, cropped.height)
    }

    private static func renderPage(
        pdfPath: String,
        pageNumber: Int,
        shortSidePx: Int,
        cropBoxNorm: [Double]?
    ) throws -> (data: Data, width: Int, height: Int) {
        guard let document = PDFDocument(url: URL(fileURLWithPath: pdfPath)),
              let page = document.page(at: pageNumber - 1) else {
            throw CLIError.message("Unable to open PDF page \(pageNumber): \(pdfPath)")
        }

        let pageBounds = page.bounds(for: .mediaBox)
        let cropRect = cropBoxNorm.map { normalizedRect(from: $0, pageBounds: pageBounds) } ?? pageBounds
        let scale = CGFloat(shortSidePx) / min(cropRect.width, cropRect.height)
        let targetWidth = max(1, Int((cropRect.width * scale).rounded()))
        let targetHeight = max(1, Int((cropRect.height * scale).rounded()))

        let image = NSImage(size: NSSize(width: targetWidth, height: targetHeight), flipped: false) { dstRect in
            NSColor.white.setFill()
            dstRect.fill()

            guard let context = NSGraphicsContext.current?.cgContext else {
                return false
            }

            context.interpolationQuality = .high
            context.saveGState()
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -cropRect.origin.x, y: -cropRect.origin.y)
            page.draw(with: .mediaBox, to: context)
            context.restoreGState()
            return true
        }

        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw CLIError.message("Unable to encode rendered page image")
        }

        return (png, targetWidth, targetHeight)
    }

    private static func normalizedRect(from components: [Double], pageBounds: CGRect) -> CGRect {
        let x = pageBounds.minX + pageBounds.width * components[0]
        let width = pageBounds.width * components[2]
        let height = pageBounds.height * components[3]
        let topY = pageBounds.minY + pageBounds.height * (1 - components[1] - components[3])
        return CGRect(x: x, y: topY, width: width, height: height)
    }

    private static func normalizePDFRect(_ rect: CGRect, pageBounds: CGRect) -> [Double] {
        let x = (rect.minX - pageBounds.minX) / pageBounds.width
        let y = 1 - ((rect.maxY - pageBounds.minY) / pageBounds.height)
        let width = rect.width / pageBounds.width
        let height = rect.height / pageBounds.height
        return [Double(x), Double(y), Double(width), Double(height)]
    }

    private static func cropCGImage(_ image: CGImage, cropBoxNorm: [Double]) throws -> CGImage {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)

        let cropRect = CGRect(
            x: width * cropBoxNorm[0],
            y: height * cropBoxNorm[1],
            width: width * cropBoxNorm[2],
            height: height * cropBoxNorm[3]
        ).integral

        guard cropRect.width > 0, cropRect.height > 0 else {
            throw CLIError.message("Crop region must produce a non-zero rectangle")
        }

        guard let cropped = image.cropping(to: cropRect) else {
            throw CLIError.message("Unable to crop image using the requested region")
        }

        return cropped
    }

    private static func intersects(_ lhs: [Double], _ rhs: [Double]) -> Bool {
        let lhsMaxX = lhs[0] + lhs[2]
        let lhsMaxY = lhs[1] + lhs[3]
        let rhsMaxX = rhs[0] + rhs[2]
        let rhsMaxY = rhs[1] + rhs[3]

        return lhs[0] < rhsMaxX && lhsMaxX > rhs[0] && lhs[1] < rhsMaxY && lhsMaxY > rhs[1]
    }

    private static func parsePageSpec(_ spec: String, pageCount: Int) throws -> [Int] {
        if spec == "all" {
            return Array(1...pageCount)
        }
        if let page = Int(spec), page >= 1, page <= pageCount {
            return [page]
        }
        let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
        if parts.count == 2,
           let start = Int(parts[0]),
           let end = Int(parts[1]),
           start >= 1,
           end >= start,
           end <= pageCount {
            return Array(start...end)
        }
        throw CLIError.message("Invalid page spec '\(spec)'. Use 'all', '12', or '12-20'.")
    }

    private static func compactPageSpec(for pages: [Int]) -> String {
        guard let first = pages.first, let last = pages.last else {
            return ""
        }
        return first == last ? "\(first)" : "\(first)-\(last)"
    }

    private static func previewShortSidePx(mode: String, imageScale: Int) -> Int {
        let base = shortSidePx(for: imageScale)
        if mode == "image_focus" {
            return Int(Double(base) * 1.15)
        }
        if mode == "text_focus" {
            return max(768, Int(Double(base) * 0.9))
        }
        return base
    }

    private static func focusShortSidePx(mode: String, imageScale: Int) -> Int {
        let base = max(1200, shortSidePx(for: imageScale))
        if mode == "image_focus" {
            return Int(Double(base) * 1.25)
        }
        return base
    }

    private static func shortSidePx(for imageScale: Int) -> Int {
        switch imageScale {
        case 1...2:
            return 512
        case 3...4:
            return 768
        case 5...6:
            return 1200
        case 7...8:
            return 1600
        case 9...10:
            return 2200
        default:
            return 1200
        }
    }

    private static func parsePositiveInt(_ value: String, name: String) throws -> Int {
        guard let parsed = Int(value), parsed > 0 else {
            throw CLIError.message("\(name) must be a positive integer")
        }
        return parsed
    }

    private static func parseScale(_ value: String) throws -> Int {
        let parsed = try parsePositiveInt(value, name: "image-scale")
        guard (1...10).contains(parsed) else {
            throw CLIError.message("image-scale must be between 1 and 10")
        }
        return parsed
    }

    private static func parseMode(_ value: String) throws -> String {
        let allowed = ["balanced", "text_only", "image_only", "text_focus", "image_focus"]
        guard allowed.contains(value) else {
            throw CLIError.message("mode must be one of: \(allowed.joined(separator: ", "))")
        }
        return value
    }

    private static func parseEngine(_ value: String) throws -> String {
        let allowed = ["auto", "pdfkit", "ocr", "hybrid"]
        guard allowed.contains(value) else {
            throw CLIError.message("engine must be one of: \(allowed.joined(separator: ", "))")
        }
        return value
    }

    private static func makeRuntimeOutputPath(prefix: String, ext: String) throws -> String {
        let runtimeDir = URL(fileURLWithPath: ".tmp/runtime", isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeDir, withIntermediateDirectories: true, attributes: nil)
        return runtimeDir
            .appendingPathComponent("\(prefix)-\(UUID().uuidString).\(ext)")
            .path
    }

    private static func writeData(_ data: Data, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
    }

    static func handleMCPTool(name: String, arguments: [String: Any]) throws -> MCPToolExecution {
        switch name {
        case "pdf_read":
            let pdfPath = try requireString(arguments, key: "file")
            let pageSpec = try requireString(arguments, key: "pages")
            let mode = try parseMode(optionalString(arguments["mode"]) ?? "balanced")
            let engine = try parseEngine(optionalString(arguments["engine"]) ?? "auto")
            let batchSize = try parsePositiveInt(optionalString(arguments["batch_size"]) ?? "4", name: "batch_size")
            let imageScale = try parseScale(optionalString(arguments["image_scale"]) ?? "5")

            guard let document = PDFDocument(url: URL(fileURLWithPath: pdfPath)) else {
                throw CLIError.message("Unable to open PDF: \(pdfPath)")
            }

            let selectedPages = try parsePageSpec(pageSpec, pageCount: document.pageCount)
            let chunk = Array(selectedPages.prefix(batchSize))
            let remaining = Array(selectedPages.dropFirst(chunk.count))

            let returnedPages = try chunk.map { pageNumber in
                try buildPDFReadPage(
                    document: document,
                    pdfPath: pdfPath,
                    pageNumber: pageNumber,
                    mode: mode,
                    engine: engine,
                    imageScale: imageScale
                )
            }

            let output = PDFReadOutput(
                file: pdfPath,
                requestedPages: pageSpec,
                mode: mode,
                engine: engine,
                batchSize: batchSize,
                imageScale: imageScale,
                pageCount: document.pageCount,
                returnedPages: returnedPages,
                continuation: PDFReadContinuation(
                    hasMore: !remaining.isEmpty,
                    nextPages: remaining.isEmpty ? nil : compactPageSpec(for: remaining)
                )
            )

            return try makeMCPExecution(
                output,
                text: summarizePDFRead(output),
                imagePaths: output.returnedPages.compactMap(\.previewImagePath)
            )

        case "pdf_focus":
            let pdfPath = try requireString(arguments, key: "file")
            let pageNumber = try requireInt(arguments, key: "page")
            let bboxNorm = try requireBBox(arguments, key: "bbox_norm")
            let mode = try parseMode(optionalString(arguments["mode"]) ?? "balanced")
            let engine = try parseEngine(optionalString(arguments["engine"]) ?? "auto")
            let imageScale = try parseScale(optionalString(arguments["image_scale"]) ?? "7")

            guard let document = PDFDocument(url: URL(fileURLWithPath: pdfPath)),
                  document.page(at: pageNumber - 1) != nil else {
                throw CLIError.message("Unable to open PDF page \(pageNumber): \(pdfPath)")
            }

            let output = try buildPDFFocusOutput(
                document: document,
                pdfPath: pdfPath,
                pageNumber: pageNumber,
                bboxNorm: bboxNorm,
                mode: mode,
                engine: engine,
                imageScale: imageScale
            )

            return try makeMCPExecution(
                output,
                text: summarizePDFFocus(output),
                imagePaths: output.detailImagePath.map { [$0] } ?? []
            )

        case "save_region":
            let sourceType = try requireString(arguments, key: "source_type")
            let sourcePath = try requireString(arguments, key: "source_path")
            let outputPath = try requireString(arguments, key: "output_path")
            let bboxNorm = try requireBBox(arguments, key: "bbox_norm")

            switch sourceType {
            case "image":
                let rendered = try cropImage(imagePath: sourcePath, cropBoxNorm: bboxNorm)
                try writeData(rendered.data, to: outputPath)
                let output = SaveRegionOutput(
                    sourceType: "image",
                    sourcePath: sourcePath,
                    outputPath: outputPath,
                    cropBoxNorm: bboxNorm,
                    outputPx: [rendered.width, rendered.height]
                )
                return try makeMCPExecution(
                    output,
                    text: "Saved image region to \(outputPath).",
                    imagePaths: [outputPath]
                )

            case "pdf":
                let pageNumber = try requireInt(arguments, key: "page")
                let shortSidePx = try parsePositiveInt(optionalString(arguments["short_side_px"]) ?? "1600", name: "short_side_px")
                let rendered = try renderPage(
                    pdfPath: sourcePath,
                    pageNumber: pageNumber,
                    shortSidePx: shortSidePx,
                    cropBoxNorm: bboxNorm
                )
                try writeData(rendered.data, to: outputPath)
                let output = SaveRegionOutput(
                    sourceType: "pdf",
                    sourcePath: sourcePath,
                    outputPath: outputPath,
                    cropBoxNorm: bboxNorm,
                    outputPx: [rendered.width, rendered.height]
                )
                return try makeMCPExecution(
                    output,
                    text: "Saved PDF region to \(outputPath).",
                    imagePaths: [outputPath]
                )

            default:
                throw CLIError.message("source_type must be either 'image' or 'pdf'")
            }

        case "ocr_detect_regions":
            let imagePath = try requireString(arguments, key: "image")
            let bboxNorm = try optionalBBox(arguments, key: "bbox_norm")
            let output = try runVisionOCRDetectRegions(imagePath: imagePath, cropBoxNorm: bboxNorm)
            return try makeMCPExecution(
                output,
                text: summarizeOCRDetectRegions(output),
                imagePaths: []
            )

        default:
            throw CLIError.message("Unknown tool: \(name)")
        }
    }

    private static func makeMCPExecution<T: Encodable>(
        _ value: T,
        text: String,
        imagePaths: [String]
    ) throws -> MCPToolExecution {
        guard let structured = try toJSONObject(value) as? [String: Any] else {
            throw CLIError.message("Unable to encode structured tool output")
        }
        return MCPToolExecution(
            structuredContent: structured,
            text: text,
            imagePaths: imagePaths
        )
    }

    private static func toJSONObject<T: Encodable>(_ value: T) throws -> Any {
        let encoder = JSONEncoder()
        let data = try encoder.encode(value)
        return try JSONSerialization.jsonObject(with: data)
    }

    private static func requireString(_ arguments: [String: Any], key: String) throws -> String {
        if let string = arguments[key] as? String, !string.isEmpty {
            return string
        }
        if let number = arguments[key] as? NSNumber {
            return number.stringValue
        }
        throw CLIError.message("Missing or invalid argument '\(key)'")
    }

    private static func requireInt(_ arguments: [String: Any], key: String) throws -> Int {
        if let value = arguments[key] as? Int {
            return value
        }
        if let number = arguments[key] as? NSNumber {
            return number.intValue
        }
        if let string = arguments[key] as? String, let value = Int(string) {
            return value
        }
        throw CLIError.message("Missing or invalid integer argument '\(key)'")
    }

    private static func optionalString(_ value: Any?) -> String? {
        if let string = value as? String {
            return string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }

    private static func requireBBox(_ arguments: [String: Any], key: String) throws -> [Double] {
        guard let bbox = try optionalBBox(arguments, key: key) else {
            throw CLIError.message("Missing or invalid bbox argument '\(key)'")
        }
        return bbox
    }

    private static func optionalBBox(_ arguments: [String: Any], key: String) throws -> [Double]? {
        guard let raw = arguments[key] else {
            return nil
        }
        guard let array = raw as? [Any], array.count == 4 else {
            throw CLIError.message("Argument '\(key)' must be an array of four normalized numbers")
        }
        return try array.map { item in
            if let value = item as? Double {
                return try parseNormalizedComponent(String(value))
            }
            if let value = item as? NSNumber {
                return try parseNormalizedComponent(value.stringValue)
            }
            if let value = item as? String {
                return try parseNormalizedComponent(value)
            }
            throw CLIError.message("Argument '\(key)' must be an array of four normalized numbers")
        }
    }

    private static func summarizePDFRead(_ output: PDFReadOutput) -> String {
        let pageList = output.returnedPages.map { "\($0.page)" }.joined(separator: ", ")
        return "Read pages \(pageList) from \(output.file). Returned \(output.returnedPages.count) page objects with text, preview paths, and candidate regions."
    }

    private static func summarizePDFFocus(_ output: PDFFocusOutput) -> String {
        "Focused page \(output.page) of \(output.file) for bbox \(output.bboxNorm). Returned local text, a detail image path, and candidate regions."
    }

    private static func summarizeOCRDetectRegions(_ output: OCRDetectRegionsOutput) -> String {
        "Detected \(output.lineCount) OCR lines and \(output.regions.count) grouped regions in \(output.image)."
    }

    private static func detectRegions(from lines: [OCRLine]) -> [OCRRegion] {
        let sorted = lines.enumerated().sorted { lhs, rhs in
            let left = lhs.element.bboxNorm
            let right = rhs.element.bboxNorm
            if abs(left[1] - right[1]) > 0.02 {
                return left[1] < right[1]
            }
            return left[0] < right[0]
        }

        var groups: [[OCRLine]] = []

        for item in sorted {
            let line = item.element
            if var last = groups.last {
                let lastLine = last[last.count - 1]
                let verticalGap = line.bboxNorm[1] - (lastLine.bboxNorm[1] + lastLine.bboxNorm[3])
                let horizontalOverlap = min(
                    lastLine.bboxNorm[0] + lastLine.bboxNorm[2],
                    line.bboxNorm[0] + line.bboxNorm[2]
                ) - max(lastLine.bboxNorm[0], line.bboxNorm[0])

                if verticalGap <= 0.06 && horizontalOverlap >= -0.08 {
                    last.append(line)
                    groups[groups.count - 1] = last
                    continue
                }
            }
            groups.append([line])
        }

        return groups.enumerated().map { index, group in
            let minX = group.map { $0.bboxNorm[0] }.min() ?? 0
            let minY = group.map { $0.bboxNorm[1] }.min() ?? 0
            let maxX = group.map { $0.bboxNorm[0] + $0.bboxNorm[2] }.max() ?? 0
            let maxY = group.map { $0.bboxNorm[1] + $0.bboxNorm[3] }.max() ?? 0
            let excerpt = group.map(\.text).joined(separator: " ")

            return OCRRegion(
                id: "r\(index + 1)",
                bboxNorm: [minX, minY, maxX - minX, maxY - minY],
                lineCount: group.count,
                textExcerpt: String(excerpt.prefix(160))
            )
        }
    }

    private static func parseNormalizedComponent(_ value: String) throws -> Double {
        guard let component = Double(value), (0...1).contains(component) else {
            throw CLIError.message("Normalized crop values must be numbers between 0 and 1")
        }
        return component
    }

    private static func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw CLIError.message("Unable to encode JSON output")
        }
        print(string)
    }

    private static let usageText = """
    Usage:
      macpdf-ocr-mcp inspect-text <pdf-path>
      macpdf-ocr-mcp mcp-stdio
      macpdf-ocr-mcp pdf-read <pdf-path> <pages> [mode] [engine] [batch-size] [image-scale]
      macpdf-ocr-mcp pdf-focus <pdf-path> <page> <x> <y> <w> <h> [mode] [engine] [image-scale]
      macpdf-ocr-mcp extract-page <pdf-path> <page> <output-path>
      macpdf-ocr-mcp render-page <pdf-path> <page> <short-side-px> <output-path> [x y w h]
      macpdf-ocr-mcp crop-image <image-path> <output-path> <x> <y> <w> <h>
      macpdf-ocr-mcp save-region image <image-path> <output-path> <x> <y> <w> <h>
      macpdf-ocr-mcp save-region pdf <pdf-path> <page> <short-side-px> <output-path> <x> <y> <w> <h>
      macpdf-ocr-mcp ocr-image <image-path> [x y w h]
      macpdf-ocr-mcp ocr-detect-regions <image-path> [x y w h]
    """
}

@main
struct MacPDFOCRMCP {
    static func main() {
        do {
            try CLI.run(arguments: Array(CommandLine.arguments.dropFirst()))
        } catch let error as CLIError {
            fputs("\(error.description)\n", stderr)
            exit(1)
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
