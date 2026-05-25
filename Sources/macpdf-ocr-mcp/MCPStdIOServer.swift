import Foundation

struct MCPStdIOServer {
    private static let serverName = "macpdf-ocr-mcp"
    private static let serverVersion = "0.1.0"
    private static let defaultProtocolVersion = "2025-06-18"

    static func run() throws {
        while let line = readLine(strippingNewline: true) {
            try withAutoreleasePool {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    return
                }

                guard let data = trimmed.data(using: .utf8),
                      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return
                }

                if object["id"] != nil {
                    try handleRequest(object)
                } else {
                    handleNotification(object)
                }
            }
        }
    }

    private static func withAutoreleasePool(_ body: () throws -> Void) throws {
        var capturedError: Error?
        autoreleasepool {
            do {
                try body()
            } catch {
                capturedError = error
            }
        }
        if let capturedError {
            throw capturedError
        }
    }

    private static func handleRequest(_ request: [String: Any]) throws {
        let id = request["id"] as Any
        guard let method = request["method"] as? String else {
            try sendError(id: id, code: -32600, message: "Invalid request: missing method")
            return
        }

        switch method {
        case "initialize":
            let params = request["params"] as? [String: Any] ?? [:]
            let protocolVersion = (params["protocolVersion"] as? String) ?? defaultProtocolVersion
            let result: [String: Any] = [
                "protocolVersion": protocolVersion,
                "capabilities": [
                    "tools": [
                        "listChanged": false
                    ]
                ],
                "serverInfo": [
                    "name": serverName,
                    "version": serverVersion
                ],
                "instructions": "Use pdf_read for page-level reading, pdf_focus for detail crops, save_region for local excerpt saving, and ocr_detect_regions for OCR-based image region hints."
            ]
            try sendResponse(id: id, result: result)

        case "ping":
            try sendResponse(id: id, result: [:])

        case "tools/list":
            try sendResponse(id: id, result: ["tools": toolDefinitions()])

        case "tools/call":
            guard let params = request["params"] as? [String: Any],
                  let name = params["name"] as? String else {
                try sendError(id: id, code: -32602, message: "Invalid params for tools/call")
                return
            }

            let arguments = params["arguments"] as? [String: Any] ?? [:]
            do {
                let execution = try CLI.handleMCPTool(name: name, arguments: arguments)
                try sendResponse(id: id, result: makeToolResult(execution))
            } catch let error as CLIError {
                try sendResponse(
                    id: id,
                    result: [
                        "isError": true,
                        "content": [
                            [
                                "type": "text",
                                "text": error.description
                            ]
                        ]
                    ]
                )
            }

        default:
            try sendError(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private static func handleNotification(_ notification: [String: Any]) {
        _ = notification["method"] as? String
    }

    private static func makeToolResult(_ execution: MCPToolExecution) throws -> [String: Any] {
        var content: [[String: Any]] = [
            [
                "type": "text",
                "text": execution.text
            ]
        ]

        for path in execution.imagePaths {
            if let block = try imageContentBlock(for: path) {
                content.append(block)
            }
        }

        return [
            "structuredContent": execution.structuredContent,
            "content": content,
            "isError": false
        ]
    }

    private static func imageContentBlock(for path: String) throws -> [String: Any]? {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let data = try Data(contentsOf: url)
        let ext = url.pathExtension.lowercased()
        let mimeType: String
        switch ext {
        case "jpg", "jpeg":
            mimeType = "image/jpeg"
        case "webp":
            mimeType = "image/webp"
        default:
            mimeType = "image/png"
        }
        return [
            "type": "image",
            "data": data.base64EncodedString(),
            "mimeType": mimeType
        ]
    }

    private static func toolDefinitions() -> [[String: Any]] {
        [
            [
                "name": "pdf_read",
                "description": "Read one or more PDF pages. Returns page-grouped text, preview image paths, and candidate regions for follow-up focus calls.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "file": [
                            "type": "string",
                            "description": "Relative or absolute PDF path."
                        ],
                        "pages": [
                            "type": "string",
                            "description": "Use 'all', a single page like '12', or a range like '12-20'."
                        ],
                        "mode": [
                            "type": "string",
                            "enum": ["balanced", "text_only", "image_only", "text_focus", "image_focus"],
                            "description": "Controls text/image bias. Default: balanced."
                        ],
                        "engine": [
                            "type": "string",
                            "enum": ["auto", "pdfkit", "ocr", "hybrid"],
                            "description": "Controls whether to use native PDF text, OCR, or both. Default: auto."
                        ],
                        "batch_size": [
                            "type": "integer",
                            "minimum": 1,
                            "description": "Maximum number of pages to return in this call. Default: 4."
                        ],
                        "image_scale": [
                            "type": "integer",
                            "minimum": 1,
                            "maximum": 10,
                            "description": "Preview quality level from 1 to 10. Default: 5."
                        ]
                    ],
                    "required": ["file", "pages"]
                ]
            ],
            [
                "name": "pdf_focus",
                "description": "Read a focused PDF region. Returns local text, a detail image path, and candidate regions for the selected bbox.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "file": [
                            "type": "string",
                            "description": "Relative or absolute PDF path."
                        ],
                        "page": [
                            "type": "integer",
                            "minimum": 1,
                            "description": "1-based page number."
                        ],
                        "bbox_norm": [
                            "type": "array",
                            "description": "Normalized top-left-origin bbox [x, y, w, h].",
                            "minItems": 4,
                            "maxItems": 4,
                            "items": ["type": "number"]
                        ],
                        "mode": [
                            "type": "string",
                            "enum": ["balanced", "text_only", "image_only", "text_focus", "image_focus"],
                            "description": "Controls text/image bias. Default: balanced."
                        ],
                        "engine": [
                            "type": "string",
                            "enum": ["auto", "pdfkit", "ocr", "hybrid"],
                            "description": "Controls whether to use native PDF text, OCR, or both. Default: auto."
                        ],
                        "image_scale": [
                            "type": "integer",
                            "minimum": 1,
                            "maximum": 10,
                            "description": "Detail image quality level from 1 to 10. Default: 7."
                        ]
                    ],
                    "required": ["file", "page", "bbox_norm"]
                ]
            ],
            [
                "name": "save_region",
                "description": "Save a selected region from a PDF or an existing image directly to a local target path.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "source_type": [
                            "type": "string",
                            "enum": ["image", "pdf"]
                        ],
                        "source_path": [
                            "type": "string"
                        ],
                        "output_path": [
                            "type": "string",
                            "description": "Local file path where the cropped image should be saved."
                        ],
                        "bbox_norm": [
                            "type": "array",
                            "description": "Normalized top-left-origin bbox [x, y, w, h].",
                            "minItems": 4,
                            "maxItems": 4,
                            "items": ["type": "number"]
                        ],
                        "page": [
                            "type": "integer",
                            "minimum": 1,
                            "description": "Required when source_type is 'pdf'."
                        ],
                        "short_side_px": [
                            "type": "integer",
                            "minimum": 1,
                            "description": "Optional PDF render size hint used when source_type is 'pdf'. Default: 1600."
                        ]
                    ],
                    "required": ["source_type", "source_path", "output_path", "bbox_norm"]
                ]
            ],
            [
                "name": "ocr_detect_regions",
                "description": "Run OCR on an image and return OCR lines plus coarse grouped candidate regions.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "image": [
                            "type": "string",
                            "description": "Relative or absolute image path."
                        ],
                        "bbox_norm": [
                            "type": "array",
                            "description": "Optional normalized top-left-origin bbox [x, y, w, h] to OCR only part of the image.",
                            "minItems": 4,
                            "maxItems": 4,
                            "items": ["type": "number"]
                        ]
                    ],
                    "required": ["image"]
                ]
            ]
        ]
    }

    private static func sendResponse(id: Any, result: [String: Any]) throws {
        try writeJSON([
            "jsonrpc": "2.0",
            "id": id,
            "result": result
        ])
    }

    private static func sendError(id: Any, code: Int, message: String) throws {
        try writeJSON([
            "jsonrpc": "2.0",
            "id": id,
            "error": [
                "code": code,
                "message": message
            ]
        ])
    }

    private static func writeJSON(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        if let string = String(data: data, encoding: .utf8) {
            print(string)
            fflush(stdout)
        }
    }
}
