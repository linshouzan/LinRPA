//////////////////////////////////////////////////////////////////
// 文件名：BrowserView.swift
// 文件说明：这是适用于 macos 14+ 的浏览器功能
// 功能说明：已深度适配 RPA WebAgent 3.0，支持引擎底层无缝接管与异步 DOM 通信
// 修复说明：默认关闭置顶和控制台；引入共享 ProcessPool 修复 Session 缓存；增强 URL 持久化
// API 升级：支持标准的 OpenAI 兼容流式输出 (/v1/chat/completions)
// 进阶升级：[✨新增] 深度融合本地 AI 动态 RAG 语料录制体系 (Teacher-Student Pipeline)
// 代码要求：请保证代码的逻辑和完整性，保留代码中的所有注释内容
//////////////////////////////////////////////////////////////////

import SwiftUI
import WebKit
import Combine
import AppKit

// MARK: - [✨终极修复] 网页语料录制 JS 探针 (带卸载与视觉高亮徽标)
let corpusRecorderJS = """
(function() {
    if (window._rpaCorpusInjected) return;
    window._rpaCorpusInjected = true;
    window._rpaEventBuffer = [];
    
    // [✨新增] 元素闪烁及 Target ID 徽标视觉反馈
    function flashElement(el, textMark) {
        if (!el) return;
        let oldOutline = el.style.outline;
        let oldTransition = el.style.transition;
        el.style.transition = 'outline 0.3s ease-in-out';
        el.style.outline = '3px solid #ff2d55';
        
        let badge = document.createElement('div');
        if (textMark) {
            badge.innerText = 'ID: ' + textMark;
            badge.style.position = 'absolute';
            badge.style.background = '#ff2d55';
            badge.style.color = 'white';
            badge.style.fontSize = '12px';
            badge.style.fontWeight = 'bold';
            badge.style.padding = '2px 6px';
            badge.style.borderRadius = '4px';
            badge.style.zIndex = '2147483647';
            badge.style.pointerEvents = 'none';
            let rect = el.getBoundingClientRect();
            badge.style.left = (rect.left + window.scrollX) + 'px';
            badge.style.top = (rect.top + window.scrollY - 22) + 'px';
            document.body.appendChild(badge);
        }

        setTimeout(() => {
            el.style.outline = oldOutline;
            el.style.transition = oldTransition;
            if (badge && badge.parentNode) badge.parentNode.removeChild(badge);
        }, 1200);
    }

    // 暴露给外部调用：根据 targetId 在网页中滚到该元素并高亮
    window.playRPAAction = function(targetId) {
        let el = document.querySelector('[data-rpa-id="' + targetId + '"]');
        if (el) {
            el.scrollIntoView({ behavior: 'smooth', block: 'center' });
            setTimeout(() => flashElement(el, targetId), 300);
            return "SUCCESS";
        }
        return "NOT_FOUND";
    };

    function captureDOMSnapshot(interactiveEl) {
        try {
            let summary = []; let index = 0; let targetId = '';
            let interactiveTags = ['button', 'input', 'select', 'textarea', 'a'];
            let root = document.body || document.documentElement;
            if (!root) return { summary: '', targetId: '' };
            
            let elements = Array.from(root.querySelectorAll('*')).filter(el => {
                if (!el || !el.tagName) return false;
                if (el === interactiveEl) return true;
                let tag = el.tagName.toLowerCase(); 
                let role = el.getAttribute('role') || '';
                let style = window.getComputedStyle(el);
                let isPointer = style ? (style.cursor === 'pointer') : false;
                return interactiveTags.includes(tag) || ['button', 'link', 'tab', 'menuitem'].includes(role) || el.hasAttribute('onclick') || isPointer;
            });
            
            for(let i=0; i<elements.length; i++) {
                let el = elements[i]; let isTarget = (el === interactiveEl);
                let rect = el.getBoundingClientRect(); let style = window.getComputedStyle(el);
                if(isTarget || (rect.width > 5 && rect.height > 5 && style && style.display !== 'none' && style.visibility !== 'hidden')) {
                    let rawText = el.innerText || el.value || el.getAttribute('placeholder') || el.getAttribute('aria-label') || '';
                    let cleanText = String(rawText).trim().replace(/\\s+/g, ' ').substring(0, 15);
                    if (!isTarget && cleanText === '' && !['input', 'textarea', 'select'].includes(el.tagName.toLowerCase())) continue;
                    
                    el.setAttribute('data-rpa-id', index.toString());
                    if (isTarget) targetId = index.toString();
                    
                    if (summary.length < 80 || isTarget) {
                        summary.push(`[${index}] ${cleanText || (isTarget ? '交互元素' : '')}`);
                    }
                    index++;
                }
            }
            return { summary: summary.join('\\n'), targetId: targetId };
        } catch (err) { return { summary: 'JS_ERROR: ' + err.toString(), targetId: '' }; }
    }

    function sendEvent(type, target, extra = {}) {
        let text = target.innerText || target.value || target.getAttribute('placeholder') || target.getAttribute('aria-label') || '';
        let snapshot = captureDOMSnapshot(target);
        flashElement(target, snapshot.targetId); 
        let ev = { event: type, element_text: text.trim().substring(0, 30), dom_summary: snapshot.summary, target_id: snapshot.targetId };
        Object.assign(ev, extra);
        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.corpusHandler) {
            window.webkit.messageHandlers.corpusHandler.postMessage(ev);
        } else {
            window._rpaEventBuffer.push(ev);
        }
    }

    // [✨卸载机制] 将所有事件函数独立命名，以便之后可以被 removeEventListener 干净销毁
    function rpaClickHandler(e) {
        let interactive = e.target.closest('button, a, input, select, textarea, [role="button"], [role="link"], [onclick], [tabindex]') || e.target;
        if(interactive) sendEvent('click', interactive);
    }
    function rpaChangeHandler(e) {
        if (e.target && ['input', 'textarea'].includes(e.target.tagName.toLowerCase())) { sendEvent('input', e.target, { input_value: e.target.value }); }
    }
    
    let hoverTimer = null; let lastHoverEl = null;
    function rpaMouseoverHandler(e) {
        let interactive = e.target.closest('button, a, [role="menuitem"], .dropdown, [onclick]') || e.target;
        if (interactive === lastHoverEl) return;
        lastHoverEl = interactive; clearTimeout(hoverTimer);
        hoverTimer = setTimeout(() => { if (interactive && interactive.isConnected) sendEvent('hover', interactive); }, 800);
    }
    
    let dragStartPos = null; let dragStartEl = null;
    function rpaMousedownHandler(e) { dragStartPos = { x: e.clientX, y: e.clientY }; dragStartEl = e.target; }
    function rpaMouseupHandler(e) {
        if (!dragStartPos || !dragStartEl) return;
        let dx = e.clientX - dragStartPos.x; let dy = e.clientY - dragStartPos.y; let distance = Math.sqrt(dx*dx + dy*dy);
        if (distance > 40) { sendEvent('drag_drop', dragStartEl, { drag_offset: `${Math.round(dx)},${Math.round(dy)}` }); }
        dragStartPos = null; dragStartEl = null;
    }

    // 绑定事件
    document.addEventListener('click', rpaClickHandler, true);
    document.addEventListener('change', rpaChangeHandler, true);
    document.addEventListener('mouseover', rpaMouseoverHandler, true);
    document.addEventListener('mousedown', rpaMousedownHandler, true);
    document.addEventListener('mouseup', rpaMouseupHandler, true);

    // [✨核心] 注入给苹果系统调用的销毁函数，当停止录制时会执行这个以清除污染
    window._rpaCorpusStop = function() {
        document.removeEventListener('click', rpaClickHandler, true);
        document.removeEventListener('change', rpaChangeHandler, true);
        document.removeEventListener('mouseover', rpaMouseoverHandler, true);
        document.removeEventListener('mousedown', rpaMousedownHandler, true);
        document.removeEventListener('mouseup', rpaMouseupHandler, true);
        window._rpaCorpusInjected = false;
        console.log("RPA 网页探针已成功卸载。");
    };
})();
"""

// MARK: - String Extension (基础代码格式化)

extension String {
    /// 提供基础的 JavaScript 自动缩进与格式化
    func basicJSFormat() -> String {
        var indentLevel = 0
        var result = ""
        let lines = self.components(separatedBy: .newlines)
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            
            let openBraces = trimmed.filter { $0 == "{" || $0 == "[" }.count
            let closeBraces = trimmed.filter { $0 == "}" || $0 == "]" }.count
            let delta = openBraces - closeBraces
            
            if trimmed.hasPrefix("}") || trimmed.hasPrefix("]") {
                indentLevel = max(0, indentLevel - 1)
            }
            
            let indent = String(repeating: "    ", count: indentLevel)
            result += indent + trimmed + "\n"
            
            if !(trimmed.hasPrefix("}") || trimmed.hasPrefix("]")) {
                indentLevel = max(0, indentLevel + delta)
            } else {
                indentLevel = max(0, indentLevel + delta + 1)
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Models

/// 控制台日志模型
struct ConsoleMessage: Identifiable, Equatable {
    var id: UUID
    var level: LogLevel
    var message: String
    var timestamp: Date
    
    init(id: UUID = UUID(), level: LogLevel, message: String, timestamp: Date = Date()) {
        self.id = id
        self.level = level
        self.message = message
        self.timestamp = timestamp
    }
    
    enum LogLevel: String {
        case log, info, warn, error, debug
        case input   // 用户输入的执行脚本
        case result  // 脚本执行的结果
        
        var color: Color {
            switch self {
            case .error: return .red
            case .warn: return .orange
            case .input: return .cyan
            case .result: return .gray
            case .debug: return .purple
            default: return .primary
            }
        }
        
        var iconName: String {
            switch self {
            case .log: return "terminal"
            case .info: return "info.circle.fill"
            case .warn: return "exclamationmark.triangle.fill"
            case .error: return "xmark.octagon.fill"
            case .debug: return "ladybug.fill"
            case .input: return "text.insert"
            case .result: return "text.append"
            }
        }
    }
}

// MARK: - 弱引用代理 (防止 WKScriptMessageHandler 内存泄漏)
class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: WKScriptMessageHandler?
    init(_ delegate: WKScriptMessageHandler) { self.delegate = delegate }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}

// MARK: - Browser Tab Model

/// 独立的浏览器标签页实例模型
class BrowserTab: NSObject, ObservableObject, Identifiable, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    let id = UUID()
    
    @Published var urlString: String = ""
    @Published var title: String = "新标签页"
    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false
    @Published var isLoading: Bool = false
    @Published var estimatedProgress: Double = 0.0
    @Published var consoleMessages: [ConsoleMessage] = []
    
    let webView: WKWebView
    private var cancellables = Set<AnyCancellable>()
    
    /// 当页面请求新窗口打开 (target="_blank") 时的回调
    var onOpenNewTab: ((URLRequest) -> Void)?
    
    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()
        // [✨修复] 绑定全局共享的进程池，确保多 Tab 和重启后的 Session/Cookie 缓存完美互通
        config.processPool = BrowserViewModel.sharedProcessPool
        
        let contentController = WKUserContentController()
        let consoleJS = """
        ['log', 'debug', 'info', 'warn', 'error'].forEach(function(level) {
            var original = console[level];
            console[level] = function() {
                var msg = Array.from(arguments).map(function(a) {
                    return (typeof a === 'object') ? JSON.stringify(a) : String(a);
                }).join(' ');
                window.webkit.messageHandlers.consoleHandler.postMessage({level: level, message: msg});
                original.apply(console, arguments);
            };
        });
        window.addEventListener('error', function(e) {
            window.webkit.messageHandlers.consoleHandler.postMessage({level: 'error', message: e.message});
        });
        """
        
        let script = WKUserScript(source: consoleJS, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        contentController.addUserScript(script)
        
        let corpusScript = WKUserScript(source: corpusRecorderJS, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
        contentController.addUserScript(corpusScript)
        
        config.userContentController = contentController
        
        self.webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        
        contentController.add(WeakScriptMessageHandler(self), name: "consoleHandler")
        contentController.add(WeakScriptMessageHandler(self), name: "corpusHandler") // 👈 注册录制回调
        
        self.webView.navigationDelegate = self
        self.webView.uiDelegate = self
        self.setupObservers()
    }
    
    deinit {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "consoleHandler")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "corpusHandler")
    }
    
    private func setupObservers() {
        webView.publisher(for: \.canGoBack).assign(to: &$canGoBack)
        webView.publisher(for: \.canGoForward).assign(to: &$canGoForward)
        webView.publisher(for: \.isLoading).assign(to: &$isLoading)
        webView.publisher(for: \.estimatedProgress).assign(to: &$estimatedProgress)
        webView.publisher(for: \.title)
            .compactMap { $0 == nil || $0!.isEmpty ? "新标签页" : $0 }
            .assign(to: &$title)
        
        webView.publisher(for: \.url)
            .compactMap { $0?.absoluteString }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newURL in
                self?.urlString = newURL
                if !newURL.isEmpty && newURL != "about:blank" {
                    UserDefaults.standard.set(newURL, forKey: "DevBrowserLastURL")
                }
            }
            .store(in: &cancellables)
    }
    
    func loadURL(_ address: String) {
        var finalURLString = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if finalURLString.isEmpty { return }
        if !finalURLString.lowercased().hasPrefix("http") {
            finalURLString = "https://" + finalURLString
        }
        if let url = URL(string: finalURLString) {
            webView.load(URLRequest(url: url))
        }
    }
    
    @MainActor
    func evaluateJSAsync(_ script: String) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { result, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (result as? String) ?? "")
                }
            }
        }
    }
    
    func evaluateJavaScript(_ script: String, completion: ((Any?, Error?) -> Void)? = nil) {
        guard !script.isEmpty else { return }
        addLog(.input, message: script)
        
        let safeScript = """
        (function() {
            try {
                let result = eval(\(String(reflecting: script)));
                if (result === undefined) return 'undefined';
                if (typeof result === 'function') return result.toString();
                try {
                    return JSON.stringify(result, null, 2) || String(result);
                } catch (e) {
                    return String(result);
                }
            } catch(e) {
                return 'ERROR: ' + e.toString();
            }
        })();
        """
        
        webView.evaluateJavaScript(safeScript) { [weak self] result, error in
            if let error = error {
                self?.addLog(.error, message: error.localizedDescription)
                completion?(nil, error)
                return
            }
            
            if let resultStr = result as? String {
                if resultStr.hasPrefix("ERROR: ") {
                    self?.addLog(.error, message: resultStr.replacingOccurrences(of: "ERROR: ", with: "↳ ❌ "))
                } else {
                    self?.addLog(.result, message: "↳ " + resultStr)
                }
            } else {
                self?.addLog(.result, message: "↳ undefined")
            }
            completion?(result, error)
        }
    }
    
    // MARK: - [✨核心] 处理网页发回的回调消息
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        
        // 1. 处理 AI 语料录制消息
        if message.name == "corpusHandler" {
            if let dict = message.body as? [String: Any],
               let eventType = dict["event"] as? String {
                
                let inputValue = dict["input_value"] as? String
                let elementText = dict["element_text"] as? String ?? ""
                
                let domSummary = dict["dom_summary"] as? String ?? ""
                let targetId = dict["target_id"] as? String ?? ""
                
                if domSummary.starts(with: "JS_ERROR:") {
                    print("❌ DOM获取脚本内部发生错误: \(domSummary)")
                    return
                }
                
                Task {
                    await WebCorpusManager.shared.handleWebEvent(
                        browser: "InternalBrowser",
                        eventType: eventType,
                        value: inputValue,
                        elementText: elementText,
                        domSummary: domSummary,
                        targetId: targetId
                    )
                }
            }
            return
        }
        
        // 2. 网页 Console 日志拦截逻辑
        if message.name == "consoleHandler" {
            guard let dict = message.body as? [String: String],
                  let levelStr = dict["level"],
                  let msg = dict["message"],
                  let level = ConsoleMessage.LogLevel(rawValue: levelStr) else { return }
            
            addLog(level, message: msg)
        }
    }
    
    @discardableResult
    func addLog(_ level: ConsoleMessage.LogLevel, message: String, id: UUID = UUID()) -> UUID {
        DispatchQueue.main.async {
            self.consoleMessages.append(ConsoleMessage(id: id, level: level, message: message))
        }
        return id
    }
    
    func updateLog(id: UUID, message: String) {
        DispatchQueue.main.async {
            if let index = self.consoleMessages.firstIndex(where: { $0.id == id }) {
                self.consoleMessages[index].message = message
            }
        }
    }
    
    func clearConsole() { consoleMessages.removeAll() }
    
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            if let request = navigationAction.request as URLRequest? {
                onOpenNewTab?(request)
            }
        }
        return nil
    }
}

// MARK: - ViewModel

/// 浏览器全局业务逻辑管理器
class BrowserViewModel: NSObject, ObservableObject, WKHTTPCookieStoreObserver {
    
    static let shared = BrowserViewModel()
    
    static let sharedProcessPool = WKProcessPool()
    
    @Published var tabs: [BrowserTab] = []
    @Published var activeTabId: UUID?
    
    @Published var isAlwaysOnTop: Bool = false {
        didSet { updateWindowLevel() }
    }
    
    override init() { super.init() }
    deinit { WKWebsiteDataStore.default().httpCookieStore.remove(self) }
    
    var activeTab: BrowserTab? { tabs.first(where: { $0.id == activeTabId }) }
    
    @discardableResult
    func addNewTab(request: URLRequest? = nil, makeActive: Bool = true) -> BrowserTab {
        let newTab = BrowserTab()
        newTab.onOpenNewTab = { [weak self] req in self?.addNewTab(request: req, makeActive: true) }
        tabs.append(newTab)
        if makeActive { activeTabId = newTab.id }
        if let req = request { newTab.webView.load(req) }
        return newTab
    }
    
    func closeTab(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let isClosingActive = activeTabId == id
        tabs.remove(at: index)
        
        if tabs.isEmpty {
            addNewTab()
        } else if isClosingActive {
            let newIndex = max(0, index - 1)
            activeTabId = tabs[newIndex].id
        }
    }
    
    private func updateWindowLevel() {
        DispatchQueue.main.async {
            if let window = NSApp.keyWindow {
                window.level = self.isAlwaysOnTop ? .floating : .normal
            }
        }
    }
    
    func callAi(htmlString: String, isStreaming: Bool = true, onProgress: ((String, String) -> Void)? = nil) async -> String {
        let prompt = String(htmlString.prefix(30000))
        
        let provider = AIConfigManager.shared.activeProvider
        
        guard let url = URL(string: provider.host) else {
            return "❌ URL 无效，请检查设置中的模型地址"
        }
        
        let payload: [String: Any] = [
            "model": provider.modelName,
            "messages": [
                ["role": "user", "content": prompt]
            ],
            "stream": isStreaming
        ]
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(provider.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        
        if isStreaming {
            var fullContent = ""
            var thinkContent = ""
            var isThinking = false
            
            do {
                let (result, response) = try await URLSession.shared.bytes(for: request)
                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    return "❌ AI 接口请求失败 (HTTP \(code))，请检查模型配置及 API Key"
                }
                
                for try await line in result.lines {
                    guard line.hasPrefix("data: ") else { continue }
                    let dataString = line.dropFirst(6)
                    if dataString == "[DONE]" { break }
                    
                    if let data = dataString.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let choices = json["choices"] as? [[String: Any]],
                       let delta = choices.first?["delta"] as? [String: Any] {
                        
                        let dynamicReasoning = (delta["reasoning_content"] as? String) ?? (delta["reasoning"] as? String)
                        if let r = dynamicReasoning {
                            thinkContent += r
                            onProgress?(fullContent, thinkContent)
                            continue
                        }
                        
                        if let contentStr = delta["content"] as? String {
                            if contentStr.contains("<think>") { isThinking = true; continue }
                            if contentStr.contains("</think>") { isThinking = false; continue }
                            
                            if isThinking { thinkContent += contentStr }
                            else { fullContent += contentStr }
                            
                            onProgress?(fullContent, thinkContent)
                        }
                    }
                }
                return fullContent
            } catch {
                return "❌ 流式请求发生错误: \(error.localizedDescription)"
            }
        } else {
            do {
                let (data, _) = try await URLSession.shared.data(for: request)
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let choices = json["choices"] as? [[String: Any]],
                   let message = choices.first?["message"] as? [String: Any],
                   let content = message["content"] as? String {
                    return content
                }
                return "❌ AI 返回解析失败"
            } catch {
                return "❌ 请求发生错误: \(error.localizedDescription)"
            }
        }
    }
    
    func summarizePageWithAI(script: String) {
        guard let currentTab = activeTab else { return }
        currentTab.addLog(.info, message: "正在运行脚本获取字段数据...")
        
        currentTab.evaluateJavaScript(script) { [weak self, weak currentTab] result, error in
            guard let tab = currentTab, let self = self else { return }
            
            if let error = error {
                tab.addLog(.error, message: "脚本执行失败: \(error.localizedDescription)")
                return
            }
            guard let jsonString = result as? String, !jsonString.isEmpty else {
                tab.addLog(.warn, message: "获取到的脚本内容结果为空")
                return
            }
            
            tab.addLog(.info, message: "数据获取成功 (共提取 \(jsonString.count) 个字符)，正在发送给 AI...")
            let aiMessageId = tab.addLog(.result, message: "🤖 [建立 AI 连接中]")
            
            var dotCount = 0
            let animationTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                DispatchQueue.main.async { [weak tab] in
                    dotCount = (dotCount + 1) % 4
                    let dots = String(repeating: ".", count: dotCount)
                    tab?.updateLog(id: aiMessageId, message: "🤖 [建立 AI 连接中\(dots)]")
                }
            }
            RunLoop.current.add(animationTimer, forMode: .common)
            
            Task {
                var hasReceivedFirstChunk = false
                
                let aiResult = await self.callAi(htmlString: jsonString, isStreaming: true) { partialResult, thinkResult in
                    if !hasReceivedFirstChunk {
                        hasReceivedFirstChunk = true
                        animationTimer.invalidate()
                    }
                    
                    var msg = "🤖 "
                    var hasContent = false
                    
                    if !thinkResult.isEmpty {
                        msg += "[AI 深度思考中]:\n> \(thinkResult.replacingOccurrences(of: "\n", with: "\n> "))\n\n"
                        hasContent = true
                    }
                    
                    if !partialResult.isEmpty {
                        msg += "[AI 归纳总结中]:\n\(partialResult)"
                        hasContent = true
                    }
                    
                    if !hasContent {
                        msg += "[AI 正在持续处理流式数据...]"
                    }
                    
                    tab.updateLog(id: aiMessageId, message: msg)
                }
                
                animationTimer.invalidate()
                tab.updateLog(id: aiMessageId, message: "🤖 [AI 总结完毕]:\n\n\(aiResult)")
                
                DispatchQueue.main.async { [weak tab] in
                    guard let tab = tab else { return }
                    if let encodedData = try? JSONEncoder().encode(aiResult),
                       let safeJSString = String(data: encodedData, encoding: .utf8) {
                        
                        let callbackJS = """
                        if (typeof window.onAiResponse === 'function') {
                            window.onAiResponse(\(safeJSString));
                        } else {
                            console.warn('⚠️ 页面未挂载 window.onAiResponse 回调函数');
                        }
                        """
                        
                        tab.webView.evaluateJavaScript(callbackJS) { _, error in
                            if let error = error {
                                tab.addLog(.error, message: "执行 window.onAiResponse 回调失败: \(error.localizedDescription)")
                            } else {
                                tab.addLog(.info, message: "✅ 已成功将 AI 分析结果回调至前端 window.onAiResponse 函数")
                            }
                        }
                    }
                }
            }
        }
    }
    
    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        cookieStore.getAllCookies { cookies in
            let properties = cookies.compactMap { $0.properties }
            let dicts = properties.map { dict -> [String: Any] in
                var res = [String: Any]()
                for (k, v) in dict { res[k.rawValue] = v }
                return res
            }
            UserDefaults.standard.set(dicts, forKey: "DevBrowserPersistentCookies")
        }
    }
    
    func restoreCookiesAndLoad() {
        let lastURL = UserDefaults.standard.string(forKey: "DevBrowserLastURL") ?? "https://www.bing.com"
        
        let cookieStore = WKWebsiteDataStore.default().httpCookieStore
        cookieStore.add(self)
        let tab = addNewTab()
        guard let dicts = UserDefaults.standard.array(forKey: "DevBrowserPersistentCookies") as? [[String: Any]], !dicts.isEmpty else {
            tab.loadURL(lastURL)
            return
        }
        let group = DispatchGroup()
        for dict in dicts {
            var props = [HTTPCookiePropertyKey: Any]()
            for (k, v) in dict { props[HTTPCookiePropertyKey(rawValue: k)] = v }
            if let cookie = HTTPCookie(properties: props) {
                group.enter()
                cookieStore.setCookie(cookie) { group.leave() }
            }
        }
        group.notify(queue: .main) { tab.loadURL(lastURL) }
    }
}

// MARK: - SwiftUI & AppKit Views

struct MacWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { return webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct MacJSCodeEditor: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void
    
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    
    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.textColor = NSColor.textColor
        
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.allowsUndo = true
        
        return scrollView
    }
    
    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            let selectedRange = textView.selectedRange()
            textView.string = text
            context.coordinator.highlightSyntax(textView: textView)
            textView.setSelectedRange(selectedRange)
        }
    }
    
    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MacJSCodeEditor
        
        init(_ parent: MacJSCodeEditor) { self.parent = parent }
        
        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            highlightSyntax(textView: textView)
        }
        
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSTextView.insertNewline(_:)) {
                if NSApp.currentEvent?.modifierFlags.contains(.command) == true {
                    parent.onSubmit()
                    return true
                }
            }
            if commandSelector == #selector(NSTextView.insertTab(_:)) {
                textView.insertText("    ", replacementRange: textView.selectedRange())
                return true
            }
            return false
        }
        
        func highlightSyntax(textView: NSTextView) {
            let code = textView.string
            let attrString = NSMutableAttributedString(string: code)
            let fullRange = NSRange(location: 0, length: code.utf16.count)
            
            attrString.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), range: fullRange)
            attrString.addAttribute(.foregroundColor, value: NSColor.textColor, range: fullRange)
            
            let keywords = ["function", "var", "let", "const", "if", "else", "for", "while", "return", "try", "catch", "document", "window", "undefined", "true", "false", "null", "new", "this"]
            let keywordPattern = "\\b(\(keywords.joined(separator: "|")))\\b"
            if let regex = try? NSRegularExpression(pattern: keywordPattern) {
                for match in regex.matches(in: code, range: fullRange) {
                    attrString.addAttribute(.foregroundColor, value: NSColor.systemPink, range: match.range)
                }
            }
            
            let stringPattern = "(\"[^\"]*\")|('[^']*')|(`[^`]*`)"
            if let regex = try? NSRegularExpression(pattern: stringPattern) {
                for match in regex.matches(in: code, range: fullRange) {
                    attrString.addAttribute(.foregroundColor, value: NSColor.systemOrange, range: match.range)
                }
            }
            
            let commentPattern = "//.*"
            if let regex = try? NSRegularExpression(pattern: commentPattern) {
                for match in regex.matches(in: code, range: fullRange) {
                    attrString.addAttribute(.foregroundColor, value: NSColor.systemGreen, range: match.range)
                }
            }
            
            let selectedRange = textView.selectedRange()
            textView.textStorage?.setAttributedString(attrString)
            textView.setSelectedRange(selectedRange)
        }
    }
}

struct DevConsoleView: View {
    @ObservedObject var tab: BrowserTab
    @State private var scriptInput: String = ""
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Console", systemImage: "terminal")
                    .font(.system(size: 11, weight: .bold))
                Spacer()
                Button(action: tab.clearConsole) { Image(systemName: "trash") }.buttonStyle(.plain)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            ScrollViewReader { proxy in
                List(tab.consoleMessages) { msg in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: msg.level.iconName)
                            .font(.system(size: 10))
                            .foregroundColor(msg.level.color)
                            .frame(width: 14)
                            .padding(.top, 2)
                        
                        Text(msg.message)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(msg.level.color)
                            .textSelection(.enabled)
                    }
                    .id(msg.id)
                }
                .listStyle(.plain)
                .onChange(of: tab.consoleMessages.count) { _, _ in
                    if let last = tab.consoleMessages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
                .onReceive(tab.$consoleMessages) { messages in
                    if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            
            Divider()
            
            HStack(alignment: .top) {
                Text(">")
                    .foregroundColor(.blue)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .padding(.top, 3)
                
                MacJSCodeEditor(text: $scriptInput, onSubmit: executeScript)
                    .frame(minHeight: 22, maxHeight: 120)
                
                VStack(spacing: 8) {
                    Button(action: { scriptInput = scriptInput.basicJSFormat() }) {
                        Image(systemName: "curlybraces")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("一键格式化缩进")
                    
                    Button(action: executeScript) {
                        Image(systemName: "paperplane.fill")
                            .foregroundColor(scriptInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .secondary : .accentColor)
                    }
                    .buttonStyle(.plain)
                    .disabled(scriptInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("执行 (Cmd + Enter)")
                }
                .padding(.top, 2)
                .padding(.leading, 4)
            }
            .padding(8)
            .background(Color(NSColor.controlBackgroundColor))
        }
    }
    
    private func executeScript() {
        if !scriptInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            tab.evaluateJavaScript(scriptInput)
            scriptInput = ""
        }
    }
}

struct ScriptEditorView: View {
    @Binding var script: String
    @Binding var isPresented: Bool
    var onExecute: () -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("编辑提取脚本", systemImage: "curlybraces")
                    .font(.headline)
                Spacer()
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            MacJSCodeEditor(text: $script, onSubmit: {
                isPresented = false
                onExecute()
            })
            .padding()
            
            Divider()
            
            HStack {
                Button("取消") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                
                Button("格式化缩进") { script = script.basicJSFormat() }
                    .buttonStyle(.borderless)
                
                Spacer()
                
                Button("保存并执行 (Cmd+Enter)") {
                    isPresented = false
                    onExecute()
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(minWidth: 650, minHeight: 450)
    }
}

struct BrowserToolbar: View {
    @ObservedObject var tab: BrowserTab
    @ObservedObject var viewModel: BrowserViewModel
    @Binding var showConsole: Bool
    @Binding var showScriptEditor: Bool
    
    @State private var addressInput: String = ""
    @ObservedObject var corpusManager = WebCorpusManager.shared
    
    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 10) {
                Button(action: { tab.webView.goBack() }) { Image(systemName: "arrow.left") }.disabled(!tab.canGoBack)
                Button(action: { tab.webView.goForward() }) { Image(systemName: "arrow.right") }.disabled(!tab.canGoForward)
                Button(action: { tab.webView.reload() }) { Image(systemName: "arrow.clockwise") }
            }
            .buttonStyle(.plain).font(.system(size: 14, weight: .medium))
            
            ZStack(alignment: .trailing) {
                TextField("输入网址并回车...", text: $addressInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { tab.loadURL(addressInput) }
                    .onAppear { addressInput = tab.urlString }
                    .onChange(of: tab.urlString) { _, newValue in
                        addressInput = newValue
                    }
                
                if tab.isLoading { ProgressView().scaleEffect(0.5).padding(.trailing, 6) }
            }
            
            HStack(spacing: 15) {
                Button(action: { viewModel.isAlwaysOnTop.toggle() }) {
                    Image(systemName: viewModel.isAlwaysOnTop ? "pin.fill" : "pin")
                        .foregroundColor(viewModel.isAlwaysOnTop ? .accentColor : .secondary)
                        .rotationEffect(.degrees(viewModel.isAlwaysOnTop ? 0 : -45))
                }
                .buttonStyle(.plain)
                .help(viewModel.isAlwaysOnTop ? "取消置顶" : "置顶窗口")

                Button(action: { CorpusHUDManager.shared.toggleHUD() }) {
                    Image(systemName: corpusManager.isRecordingMode ? "record.circle" : "graduationcap.fill")
                        .foregroundColor(corpusManager.isRecordingMode ? .red : .purple)
                }
                .buttonStyle(.plain)
                .help("开启/关闭 AI 带教悬浮录制窗")
                
                Button(action: { showScriptEditor = true }) {
                    Image(systemName: "play.fill").foregroundColor(.green)
                }
                .buttonStyle(.plain)
                .help("修改提取脚本并发送给灵动岛 AI 进行分析")

                Button(action: { withAnimation { showConsole.toggle() } }) {
                    Image(systemName: "terminal.fill")
                        .foregroundColor(showConsole ? .accentColor : .primary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

public struct BrowserView: View {
    @StateObject private var viewModel = BrowserViewModel.shared
    @State private var showConsole: Bool = false
    @State private var showScriptEditor: Bool = false
    
    @StateObject private var corpusManager = WebCorpusManager.shared
    
    public init() {}
    
    public var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(viewModel.tabs) { tab in
                        BrowserTabItemView(
                            title: tab.title,
                            isActive: viewModel.activeTabId == tab.id,
                            onTap: { viewModel.activeTabId = tab.id },
                            onClose: { viewModel.closeTab(id: tab.id) }
                        )
                    }
                    Button(action: { viewModel.addNewTab() }) {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.secondary)
                            .frame(width: 28, height: 28)
                            .background(Color.secondary.opacity(0.1))
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .background(Material.regular)
            
            Divider()
            
            if let activeTab = viewModel.activeTab {
                BrowserToolbar(tab: activeTab, viewModel: viewModel, showConsole: $showConsole, showScriptEditor: $showScriptEditor)
            }
            
            Divider()
            
            VSplitView {
                ZStack {
                    if viewModel.tabs.isEmpty {
                        Text("无打开的标签页").foregroundColor(.secondary)
                    } else {
                        ForEach(viewModel.tabs) { tab in
                            MacWebView(webView: tab.webView)
                                .opacity(viewModel.activeTabId == tab.id ? 1 : 0)
                                .allowsHitTesting(viewModel.activeTabId == tab.id)
                        }
                    }
                }
                .frame(minHeight: 300)
                
                if showConsole, let activeTab = viewModel.activeTab {
                    DevConsoleView(tab: activeTab).frame(minHeight: 100)
                }
            }
        }
        .onAppear {
            if viewModel.tabs.isEmpty { viewModel.restoreCookiesAndLoad() }
        }
    }
}

struct BrowserTabItemView: View {
    let title: String
    let isActive: Bool
    let onTap: () -> Void
    let onClose: () -> Void
    @State private var isHovering = false
    
    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: isActive ? .medium : .regular))
                .foregroundColor(isActive ? .primary : .secondary)
                .lineLimit(1).truncationMode(.tail).frame(maxWidth: 160, alignment: .leading)
            Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundColor(isHovering ? .primary : .secondary) }
                .buttonStyle(.plain).opacity(isActive || isHovering ? 1.0 : 0.0)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(isActive ? Color(NSColor.controlBackgroundColor) : Color.clear)
        .cornerRadius(6)
        .shadow(color: isActive ? Color.black.opacity(0.1) : .clear, radius: 1, y: 1)
        .contentShape(Rectangle())
        .onHover { hovering in isHovering = hovering }.onTapGesture(perform: onTap)
    }
}

class BrowserWindowController: NSWindowController, NSWindowDelegate {
    static var sharedController: BrowserWindowController?
    
    @MainActor
    static func showSharedWindow() {
        if sharedController == nil {
            sharedController = BrowserWindowController()
        }
        
        if let window = sharedController?.window {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            if !window.isVisible {
                sharedController?.showWindow(nil)
            }
            window.makeKeyAndOrderFront(nil)
        }
        
        NSApp.activate(ignoringOtherApps: true)
    }
    
    convenience init() {
        let hostingController = NSHostingController(rootView: BrowserView())
        let newWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1600, height: 1000), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        newWindow.title = "开发者浏览器"
        newWindow.minSize = NSSize(width: 1024, height: 768)
        newWindow.level = .normal
        newWindow.setFrameAutosaveName("DevBrowserMainFrame")
        newWindow.center()
        newWindow.contentViewController = hostingController
        newWindow.isReleasedWhenClosed = false
        self.init(window: newWindow)
        newWindow.delegate = self
    }
}
