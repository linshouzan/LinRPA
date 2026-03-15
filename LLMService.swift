//////////////////////////////////////////////////////////////////
// 文件名：LLMService.swift
// 文件说明：这是适用于 macos 14+ 的AI模型调用服务
// 功能说明：通用大模型调用底座，统一支持文字、图片、文件的多模态流式/非流式分发。
// 代码要求：没有要求修改不用输出代码，请保证代码的逻辑和完整性，保留代码中的所有注释内容
//////////////////////////////////////////////////////////////////

import Foundation
import AppKit
import PDFKit

/// 通用的多模态消息结构体
struct LLMMessage {
    enum Role: String { case user, assistant, system }
    var role: Role
    var text: String
    var images: [NSImage] = []
    var fileURLs: [URL] = []
}

class LLMService: NSObject {
    static let shared = LLMService()
    
    // 全局默认配置 (可在此处统一修改)
    var defaultHost = "http://127.0.0.1:11434/v1/chat/completions"
    var defaultModel = "qwen3-vl:4b"
    var defaultApiKey = "sk-local-token"
    
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    
    private func getBase64(from image: NSImage) -> String? {
        guard let tiffRepresentation = image.tiffRepresentation,
              let bitmapImage = NSBitmapImageRep(data: tiffRepresentation),
              let data = bitmapImage.representation(using: .jpeg, properties: [.compressionFactor: 0.6]) else {
            return nil
        }
        return data.base64EncodedString()
    }
    
    private func extractTextContent(from url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf", let pdf = PDFDocument(url: url) {
            return (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.joined(separator: "\n")
        }
        if ["txt", "csv", "md", "json", "swift", "py", "js"].contains(ext) {
            let encodings: [String.Encoding] = [.utf8, .ascii, .isoLatin1, .macOSRoman]
            for encoding in encodings {
                if let text = try? String(contentsOf: url, encoding: encoding) { return text }
            }
        }
        do {
            var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [:]
            if ext == "docx" { options[.documentType] = NSAttributedString.DocumentType.officeOpenXML }
            else if ext == "doc" { options[.documentType] = NSAttributedString.DocumentType.docFormat }
            else if ext == "rtf" { options[.documentType] = NSAttributedString.DocumentType.rtf }
            
            let attrString = try NSAttributedString(url: url, options: options, documentAttributes: nil)
            let extractedText = attrString.string.trimmingCharacters(in: .whitespacesAndNewlines)
            return extractedText.isEmpty ? nil : extractedText
        } catch {
            return nil
        }
    }
    
    // MARK: - 核心：统一流式请求管道
    func stream(messages: [LLMMessage], model: String? = nil, host: String? = nil, apiKey: String? = nil) -> AsyncThrowingStream<String, Error> {
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let targetHost = host ?? defaultHost
                    let targetModel = model ?? defaultModel
                    let targetKey = apiKey ?? defaultApiKey
                    
                    guard let url = URL(string: targetHost) else {
                        continuation.yield("❌ [系统错误] 无效的 API 接口地址")
                        continuation.finish()
                        return
                    }
                    
                    var apiMessages: [[String: Any]] = []
                    
                    for msg in messages {
                        var contentArray: [[String: Any]] = []
                        var fullText = msg.text
                        
                        // 1. 注入文件上下文
                        for fileURL in msg.fileURLs {
                            if let text = extractTextContent(from: fileURL) {
                                fullText += "\n\n--- [附带文件: \(fileURL.lastPathComponent)] ---\n\(text)\n"
                            }
                        }
                        if !fullText.isEmpty {
                            contentArray.append(["type": "text", "text": fullText])
                        }
                        
                        // 2. 注入图片
                        for img in msg.images {
                            if let base64 = getBase64(from: img) {
                                contentArray.append(["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(base64)"]])
                            }
                        }
                        
                        // 🌟 动态自适应容错：如果只是纯文本，剥离 Array 降级为 String，兼容不支持 Vision array 的纯文本小模型
                        if contentArray.count == 1, let first = contentArray.first, first["type"] as? String == "text", let text = first["text"] as? String {
                            apiMessages.append(["role": msg.role.rawValue, "content": text])
                        } else {
                            apiMessages.append(["role": msg.role.rawValue, "content": contentArray])
                        }
                    }
                    
                    let requestBody: [String: Any] = ["model": targetModel, "messages": apiMessages, "stream": true]
                    let jsonData = try JSONSerialization.data(withJSONObject: requestBody)
                    
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.httpBody = jsonData
                    request.addValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.addValue("Bearer \(targetKey)", forHTTPHeaderField: "Authorization")
                    
                    let (result, response) = try await session.bytes(for: request)
                    if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
                        continuation.yield("\n❌ 网络/接口调用失败 (HTTP \(httpResponse.statusCode))")
                        continuation.finish()
                        return
                    }
                    
                    var isReasoningStarted = false
                    
                    // 3. SSE 流式解析
                    for try await line in result.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let jsonString = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                        if jsonString == "[DONE]" { break }
                        guard let data = jsonString.data(using: .utf8) else { continue }
                        
                        if let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let choices = decoded["choices"] as? [[String: Any]],
                           let firstChoice = choices.first,
                           let delta = firstChoice["delta"] as? [String: Any] {
                            
                            // 动态提取思考字段 (兼容 DeepSeek 和 Ollama 格式)
                            let dynamicReasoning = (delta["reasoning_content"] as? String) ?? (delta["reasoning"] as? String)
                            if let reasoningText = dynamicReasoning, !reasoningText.isEmpty {
                                if !isReasoningStarted { continuation.yield("<think>\n"); isReasoningStarted = true }
                                continuation.yield(reasoningText)
                            }
                            
                            if let content = delta["content"] as? String, !content.isEmpty {
                                if isReasoningStarted { continuation.yield("\n</think>\n"); isReasoningStarted = false }
                                continuation.yield(content)
                            }
                        }
                    }
                    
                    if isReasoningStarted { continuation.yield("\n</think>\n") }
                    continuation.finish()
                    
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    
    // MARK: - 包装：非流式单次请求 (直接拼装 Stream 数据，完美复用逻辑)
    func generate(messages: [LLMMessage], model: String? = nil, host: String? = nil, apiKey: String? = nil) async throws -> String {
        let dataStream = self.stream(messages: messages, model: model, host: host, apiKey: apiKey)
        var fullResponse = ""
        for try await chunk in dataStream {
            fullResponse += chunk
        }
        return fullResponse.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension LLMService: URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let serverTrust = challenge.protectionSpace.serverTrust { completionHandler(.useCredential, URLCredential(trust: serverTrust)) }
        else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }
}
