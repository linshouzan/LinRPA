//////////////////////////////////////////////////////////////////
// 文件名：AICorpusManager.swift
// 文件说明：本地动态 RAG 语料管理与 AI 带教系统核心模块 (完美回放版)
// 功能说明：包含数据模型、NLP极速语义检索、Teacher-Student录制合成与 UI 管理面板
// 进阶升级：支持 TargetID 徽标、动作流列表显示、按序回放与 UI 同步高亮、快捷键删除、探针卸载
// [✨增强]：支持列表编辑、TargetID序号展示、等待节点插入、自动滚动跟踪、输入显隐化、一键停止录制
// 代码要求：请保证代码的逻辑和完整性，保留代码中的所有注释内容
//////////////////////////////////////////////////////////////////

import SwiftUI
import AppKit
import NaturalLanguage
import Foundation
import Combine
import UniformTypeIdentifiers

// MARK: - 1. 数据模型与自愈机制 (Teacher-Student & 达尔文机制)
struct WebCorpusRecord: Codable, Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    
    var userIntent: String
    var beforeDOM: String
    var actionType: String
    var targetId: String
    var inputValue: String?
    
    var synthesizedThought: String?
    var synthesizedStepsJSON: String?
    
    var successCount: Int = 0
    var failCount: Int = 0
    var totalUsed: Int { successCount + failCount }
    
    var reliabilityStatus: String {
        if totalUsed == 0 { return "🆕 新录制" }
        let rate = Double(successCount) / Double(totalUsed)
        if totalUsed >= 3 && rate < 0.4 { return "⚠️ 建议废弃" }
        if totalUsed >= 2 && rate > 0.8 { return "⭐️ 高可靠" }
        return "✅ 可用 (\(Int(rate * 100))%)"
    }
    
    var reliabilityWeight: Double {
        if totalUsed == 0 { return 1.0 }
        let rate = Double(successCount) / Double(totalUsed)
        if totalUsed >= 3 && rate < 0.4 { return 0.1 }
        return 0.5 + (0.5 * rate)
    }
}

// MARK: - 2. NLP 极速语义检索数据库 (RAG Core)
class CorpusDatabase: ObservableObject {
    static let shared = CorpusDatabase()
    
    private let fileURL: URL
    @Published var records: [WebCorpusRecord] = []
    
    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.fileURL = docs.appendingPathComponent("rpa_corpus.json")
        self.load()
    }
    
    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([WebCorpusRecord].self, from: data) else {
            self.records = []
            return
        }
        self.records = decoded
    }
    
    func save() {
        if let data = try? JSONEncoder().encode(records) {
            try? data.write(to: fileURL)
        }
    }
    
    func addRecord(_ record: WebCorpusRecord) {
        records.append(record)
        save()
    }
    
    func reportExecutionResult(id: UUID, isSuccess: Bool) {
        DispatchQueue.main.async {
            guard let index = self.records.firstIndex(where: { $0.id == id }) else { return }
            if isSuccess {
                self.records[index].successCount += 1
            } else {
                self.records[index].failCount += 1
            }
            self.save()
        }
    }
    
    private func extractKeywords(from text: String) -> Set<String> {
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        var keywords = Set<String>()
        let options: NLTagger.Options = [.omitPunctuation, .omitWhitespace, .omitOther, .joinNames]
        
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass, options: options) { tag, tokenRange in
            if let tag = tag, tag == .noun || tag == .verb || tag == .organizationName || tag == .adjective || tag == .placeName {
                let word = String(text[tokenRange]).lowercased()
                if word.count > 0 { keywords.insert(word) }
            }
            return true
        }
        return keywords.isEmpty ? Set(text.lowercased().map { String($0) }) : keywords
    }
    
    func searchTopRelevantAdvanced(intent: String, topK: Int = 2) -> [WebCorpusRecord] {
        guard !records.isEmpty else { return [] }
        let targetKeywords = extractKeywords(from: intent)
        if targetKeywords.isEmpty { return [] }
        
        let scoredRecords = records.compactMap { record -> (record: WebCorpusRecord, score: Double)? in
            if record.reliabilityWeight <= 0.2 { return nil }
            let recordKeywords = extractKeywords(from: record.userIntent)
            let intersection = targetKeywords.intersection(recordKeywords)
            let baseScore = Double(intersection.count) / Double(targetKeywords.union(recordKeywords).count)
            let finalScore = baseScore * record.reliabilityWeight
            return (record, finalScore)
        }
        
        return scoredRecords.filter { $0.score > 0.15 }
                            .sorted { $0.score > $1.score }
                            .prefix(topK)
                            .map { $0.record }
    }
    
    func exportForFineTuning() -> String {
        var jsonl = ""
        for record in records {
            guard let thought = record.synthesizedThought, let steps = record.synthesizedStepsJSON else { continue }
            if record.reliabilityWeight <= 0.2 { continue }
            
            let sys = "你是一个网页自动化助手。请结合可见元素列表，决定下一步操作。"
            let usr = "【任务】: \(record.userIntent)\\n【DOM】:\\n\(record.beforeDOM)"
            let ast = "{\\n  \"thought\": \"\(thought)\",\\n  \"steps\": \(steps)\\n}"
            
            let safeAst = ast.replacingOccurrences(of: "\n", with: "\\n")
                             .replacingOccurrences(of: "\"", with: "\\\"")
            
            jsonl += "{\"messages\": [{\"role\": \"system\", \"content\": \"\(sys)\"}, {\"role\": \"user\", \"content\": \"\(usr)\"}, {\"role\": \"assistant\", \"content\": \"\(safeAst)\"}]}\n"
        }
        return jsonl
    }
}

// MARK: - 3. 语料录制与云端大模型数据清洗引擎
class WebCorpusManager: ObservableObject {
    static let shared = WebCorpusManager()
    
    private var pollTimer: Timer?
    private var globalEventMonitor: Any? // [✨新增] 全局热键监听器
    
    @Published var isRecordingMode: Bool = false {
        didSet {
            if isRecordingMode {
                startPollingExternalBrowsers()
                setupHotkeys()
            } else {
                stopPollingExternalBrowsers()
                removeHotkeys()
                Task { await stopAndTeardownProbe() }
                sessionEvents.removeAll()
                currentUserIntent = ""
                playingEventId = nil
            }
        }
    }
    @Published var currentUserIntent: String = ""
    @Published var isPaused: Bool = false {
        didSet {
            let status = isPaused ? "已暂停录制 (⌥⌘R 继续)" : "录制中 (⌥⌘R 暂停)"
            AgentMonitorManager.shared.actionExecutionLogs.append("⏸ \(status)")
        }
    }
    @Published var playingEventId: UUID? = nil
    
    struct RawSessionEvent: Identifiable {
        let id = UUID()
        var actionType: String
        var targetId: String
        var inputValue: String?
        var elementText: String
        var domSummary: String
        var isSecureInput: Bool = false
    }
    @Published var sessionEvents: [RawSessionEvent] = []
    
    // [✨新增] 注册全局与本地热键 (Option + Command + R)
    private func setupHotkeys() {
        let handler: (NSEvent) -> Void = { [weak self] event in
            if event.modifierFlags.contains([.command, .option]) && event.keyCode == 15 { // 15 是 'R' 键
                DispatchQueue.main.async { self?.isPaused.toggle() }
            }
        }
        // 监听其他 App 激活时的按键
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler)
        // 本地 App 也可以使用 (非必需，但提升体验)
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.modifierFlags.contains([.command, .option]) && event.keyCode == 15 {
                DispatchQueue.main.async { self.isPaused.toggle() }
                return nil // 拦截掉
            }
            return event
        }
    }
    
    private func removeHotkeys() {
        if let monitor = globalEventMonitor {
            NSEvent.removeMonitor(monitor)
            globalEventMonitor = nil
        }
    }
    
    func stopRecording() {
        self.isRecordingMode = false
        AgentMonitorManager.shared.actionExecutionLogs.append("⏹ 已停止录制并卸载网页探针。")
    }
    
    @MainActor
    func addWaitAction(seconds: Double = 1.0) {
        let waitEvent = RawSessionEvent(actionType: "wait", targetId: "", inputValue: "\(seconds)", elementText: "强制延时 \(seconds) 秒", domSummary: "")
        sessionEvents.append(waitEvent)
        AgentMonitorManager.shared.actionExecutionLogs.append("⏳ 已在动作流中插入等待 \(seconds) 秒节点")
    }
    
    private func startPollingExternalBrowsers() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            Task { await self?.pollActiveBrowser() }
        }
    }
    
    private func stopPollingExternalBrowsers() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    @MainActor
    private func stopAndTeardownProbe() async {
        let targetBrowser = getTargetBrowser()
        _ = BrowserScriptBridge.runJS(in: targetBrowser, js: BrowserScriptBridge.probeTeardownJS)
    }

    private func getTargetBrowser() -> String {
        guard let appName = NSWorkspace.shared.frontmostApplication?.localizedName else { return "Google Chrome" }
        return appName == "Safari" ? "Safari" : "Google Chrome"
    }

    // [✨修复暂停缓存积压 Bug]
    @MainActor
    private func pollActiveBrowser() async {
        guard isRecordingMode else { return }
        let targetBrowser = getTargetBrowser()
        
        // 取出缓冲池并立刻清空 (JS IIFE 内部会自动置空)
        let pullScript = """
        (function() {
            if(window._rpaCorpusInjected) { 
                let res = JSON.stringify(window._rpaEventBuffer || []); 
                window._rpaEventBuffer = []; 
                return res; 
            } else { return 'NOT_INJECTED'; }
        })();
        """
        
        let jsonString = BrowserScriptBridge.runJS(in: targetBrowser, js: pullScript)
        
        if jsonString == "NOT_INJECTED" {
            _ = BrowserScriptBridge.runJS(in: targetBrowser, js: BrowserScriptBridge.probeInjectionJS)
        } else if let jsonString = jsonString, jsonString != "[]" && jsonString != "NOT_FOUND" {
            // [✨关键点]：无论是否暂停，都会把浏览器积压的动作“取出来”清空。如果是暂停状态，直接 return 丢弃，不再录入列表。
            if isPaused { return }
            
            if let data = jsonString.data(using: .utf8), let events = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                for dict in events {
                    let eventType = dict["event"] as? String ?? "unknown"
                    let targetId = dict["target_id"] as? String ?? ""
                    if targetId.isEmpty { continue }
                    
                    let newEvent = RawSessionEvent(
                        actionType: eventType,
                        targetId: targetId,
                        inputValue: dict["input_value"] as? String,
                        elementText: (dict["element_text"] as? String ?? "").isEmpty ? "未知元素" : (dict["element_text"] as! String),
                        domSummary: dict["dom_summary"] as? String ?? ""
                    )
                    sessionEvents.append(newEvent)
                    AgentMonitorManager.shared.actionExecutionLogs.append("📸 已记录: [\(eventType)] -> \(newEvent.elementText)")
                }
            }
        }
    }
    
    // [✨接入统一下发的 JS Bridge]
    @MainActor
    func playbackAction(event: RawSessionEvent) async {
        if event.targetId.isEmpty { return }
        let targetBrowser = getTargetBrowser()
        let js = BrowserScriptBridge.generatePlaybackJS(targetId: event.targetId, actionType: event.actionType, inputValue: event.inputValue ?? "")
        _ = BrowserScriptBridge.runJS(in: targetBrowser, js: js)
    }
    
    @MainActor
    func playAllActions() async {
        guard !sessionEvents.isEmpty else { return }
        let wasPaused = isPaused
        isPaused = true
        
        for event in sessionEvents {
            playingEventId = event.id
            AgentMonitorManager.shared.actionExecutionLogs.append("▶️ 正在回放动作: \(event.elementText)")
            if event.actionType == "wait" {
                let secs = Double(event.inputValue ?? "1") ?? 1.0
                try? await Task.sleep(nanoseconds: UInt64(secs * 1_000_000_000))
            } else {
                await playbackAction(event: event)
                try? await Task.sleep(nanoseconds: 1_200_000_000)
            }
        }
        
        playingEventId = nil
        isPaused = wasPaused
        AgentMonitorManager.shared.actionExecutionLogs.append("✅ 动作回放完成")
    }
    
    @MainActor
    func deleteAction(id: UUID) {
        if let index = sessionEvents.firstIndex(where: { $0.id == id }) {
            let removed = sessionEvents.remove(at: index)
            AgentMonitorManager.shared.actionExecutionLogs.append("🗑 已删除动作: \(removed.elementText)")
        }
    }
    
    @MainActor
    func restartRecordingSession() {
        sessionEvents.removeAll()
        isPaused = false
        AgentMonitorManager.shared.actionExecutionLogs.append("🔄 已清空动作队列")
    }
    
    @MainActor
    func saveSessionAndContinue() async {
        guard !sessionEvents.isEmpty else { return }
        
        let finalDOM = sessionEvents.last(where: { !$0.domSummary.isEmpty })?.domSummary ?? ""
        let intent = currentUserIntent.isEmpty ? "连续操作任务 (\(sessionEvents.count)步)" : currentUserIntent
        
        let rawStepsJSON = sessionEvents.map { ev -> String in
            var dict: [String: Any] = ["action_type": ev.actionType, "target_id": ev.targetId, "element_desc": ev.elementText]
            if let val = ev.inputValue { dict["input_value"] = val }
            if let data = try? JSONSerialization.data(withJSONObject: dict), let str = String(data: data, encoding: .utf8) { return str }
            return "{}"
        }.joined(separator: ",\n")
        
        var record = WebCorpusRecord(
            id: UUID(),
            timestamp: Date(),
            userIntent: intent,
            beforeDOM: finalDOM,
            actionType: "sequence",
            targetId: "multi",
            inputValue: "[\n\(rawStepsJSON)\n]"
        )
        
        CorpusDatabase.shared.addRecord(record)
        AgentMonitorManager.shared.actionExecutionLogs.append("✅ [\(intent)] 已保存入库")
        
        self.sessionEvents.removeAll()
        self.currentUserIntent = ""
        self.isPaused = false
        
        Task {
            await synthesizeTrainingData(record: &record)
            DispatchQueue.main.async {
                if let idx = CorpusDatabase.shared.records.firstIndex(where: { $0.id == record.id }) {
                    CorpusDatabase.shared.records[idx] = record
                    CorpusDatabase.shared.save()
                }
            }
        }
    }
    
    private func synthesizeTrainingData(record: inout WebCorpusRecord) async {
        let cleanerID = UserDefaults.standard.string(forKey: "corpusCleanerProviderID") ?? ""
        let allProviders = AIConfigManager.shared.providers
        let specificProvider = allProviders.first(where: { $0.id.uuidString == cleanerID })
        let activeProvider = AIConfigManager.shared.activeProvider
        
        let prompt: String
        if record.actionType == "sequence" {
            let rawStepsJsonStr = record.inputValue ?? "[]"
            prompt = """
            你是一个 RPA 训练数据生成专家。用户刚刚在网页上执行了一个【连贯的系列任务】。
            【用户最终意图】: \(record.userIntent)
            【捕获的原始动作序列】:
            \(rawStepsJsonStr)
            【最终页面的 DOM 结构】:
            \(record.beforeDOM)
            
            【要求】
            1. 请结合动作序列，为整个任务流写出一段总体推理(thought)（限30字内）。
            2. 规范化为 Agent 可执行的 steps 数组。如果遇到连续多次输入同一个框，请优化保留最后一次即可。
            3. 必须输出合法 JSON，使用 ```json 包裹！
            ```json
            {
               "thought": "你的连贯推理",
               "steps": [
                   {"action_type": "hover/click/input/drag_drop", "target_id": "ID", "input_value": "值"}
               ]
            }
            ```
            """
        } else {
            var actionDict: [String: Any] = ["action_type": record.actionType, "target_id": record.targetId]
            if record.actionType == "input" { actionDict["input_value"] = record.inputValue ?? "" }
            let actionJsonData = (try? JSONSerialization.data(withJSONObject: actionDict)) ?? Data()
            let actionJsonStr = String(data: actionJsonData, encoding: .utf8) ?? "{}"
            
            prompt = """
            你是一个 RPA 训练数据生成专家。现在有一个用户在网页上执行了操作，我需要你基于他当时面临的【DOM元素列表】，为这个操作写出一段简短的【推理过程(thought)】。
            用户目的：\(record.userIntent)
            用户最终执行的动作：\(actionJsonStr)
            当时的DOM列表：\(record.beforeDOM)
            
            【要求】
            1. thought 必须简短直接（20字以内），解释为什么选择该元素。
            2. steps 原封不动使用上面提供的“用户最终执行的动作”。
            3. 请严格输出如下 JSON 格式，必须使用 ```json 包裹！不要解释！
            ```json
            {
               "thought": "你的简短推理",
               "steps": [\(actionJsonStr)]
            }
            ```
            """
        }
        
        let msg = LLMMessage(role: .user, text: prompt)
        do {
            let resultStr = try await LLMService.shared.generate(messages: [msg])
            var cleanJSONStr = ""
            if let start = resultStr.firstIndex(of: "{"), let end = resultStr.lastIndex(of: "}") {
                cleanJSONStr = String(resultStr[start...end])
            }
            
            if let data = cleanJSONStr.data(using: .utf8),
               let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                record.synthesizedThought = dict["thought"] as? String ?? "⚠️ 模型未生成 thought"
                if let steps = dict["steps"], let stepsData = try? JSONSerialization.data(withJSONObject: steps) {
                    record.synthesizedStepsJSON = String(data: stepsData, encoding: .utf8)
                }
            }
        } catch {
            record.synthesizedThought = "❌ 接口报错"
            record.synthesizedStepsJSON = error.localizedDescription
        }
    }
    
    @MainActor
    func manualTranslate(recordId: UUID) async {
        let db = CorpusDatabase.shared
        guard let idx = db.records.firstIndex(where: { $0.id == recordId }) else { return }
        db.objectWillChange.send()
        db.records[idx].synthesizedThought = nil
        db.records[idx].synthesizedStepsJSON = nil
        var tempRecord = db.records[idx]
        await synthesizeTrainingData(record: &tempRecord)
        DispatchQueue.main.async {
            if let updateIdx = db.records.firstIndex(where: { $0.id == recordId }) {
                db.objectWillChange.send()
                db.records[updateIdx] = tempRecord
                db.save()
            }
        }
    }
    
    // [✨修复] 补充被误删的外部浏览器或内置 BrowserView 的事件接收接口
    @MainActor
    func handleWebEvent(browser: String, eventType: String, value: String? = nil, elementText: String = "", domSummary: String, targetId: String) async {
        // 录制模式未开启，或者当前处于暂停状态时，直接丢弃事件，不录入列表
        guard isRecordingMode, !isPaused else { return }
        guard !targetId.isEmpty else { return }
        
        let newEvent = RawSessionEvent(
            actionType: eventType,
            targetId: targetId,
            inputValue: value,
            elementText: elementText.isEmpty ? "未知元素" : elementText,
            domSummary: domSummary
        )
        
        sessionEvents.append(newEvent)
        AgentMonitorManager.shared.actionExecutionLogs.append("📸 已记录: [\(eventType)] -> \(newEvent.elementText)")
    }
}

// MARK: - 4. 语料可视化与人工介入管理面板
struct CorpusManagerView: View {
    @ObservedObject var database = CorpusDatabase.shared
    @ObservedObject var config = AIConfigManager.shared
    @State private var searchText = ""
    
    @AppStorage("corpusCleanerProviderID") var corpusCleanerID: String = ""
    
    var filteredRecords: [WebCorpusRecord] {
        let sorted = database.records.sorted(by: { $0.timestamp > $1.timestamp })
        if searchText.isEmpty { return sorted }
        return sorted.filter { $0.userIntent.localizedCaseInsensitiveContains(searchText) }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label("AI 动作经验库", systemImage: "book.fill")
                    .font(.headline)
                    .foregroundColor(.purple)
                
                Spacer()
                
                HStack {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                    TextField("搜索意图...", text: $searchText)
                        .textFieldStyle(.plain)
                        .frame(width: 150)
                }
                .padding(6)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.2), lineWidth: 1))

                Divider().frame(height: 20)

                HStack(spacing: 4) {
                    Image(systemName: "sparkles").foregroundColor(.orange)
                    Picker("清洗模型:", selection: $corpusCleanerID) {
                        Text("跟随全局设置").tag("")
                        ForEach(config.providers) { provider in
                            Text(provider.name).tag(provider.id.uuidString)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 130)
                }
                .help("为此处的手动转译和自动录制选择独立的高参数模型 (如 GPT-4/Claude)")

                Divider().frame(height: 20)

                Button(action: { CorpusHUDManager.shared.toggleHUD() }) {
                    Label("带教录制", systemImage: "record.circle")
                        .foregroundColor(.red)
                        .controlSize(.small)
                }
                .buttonStyle(.bordered)
                .help("打开AI带教悬浮窗，支持 Safari、Chrome 和内置浏览器")

                Button(action: { exportCorpus() }) {
                    Label("导出 JSONL", systemImage: "square.and.arrow.up")
                        .controlSize(.small)
                }
                .buttonStyle(.bordered)
            }
            .padding(12)
            .background(.ultraThinMaterial)
            
            Divider()
            
            if filteredRecords.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "tray.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.gray.opacity(0.3))
                    Text(searchText.isEmpty ? "暂无录制语料，请开启带教模式进行录制" : "未找到匹配 \"\(searchText)\" 的语料")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(filteredRecords) { record in
                        CorpusRecordRowView(recordId: record.id)
                            .listRowSeparator(.visible)
                            .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                    }
                }
                .listStyle(.inset)
            }
            
            HStack {
                Text("共 \(database.records.count) 条本地语料")
                Spacer()
                if let selected = config.providers.first(where: { $0.id.uuidString == corpusCleanerID }) {
                    Text("当前清洗引擎: \(selected.name) (\(selected.modelName))")
                } else {
                    Text("当前清洗引擎: 默认全局配置 (\(config.activeProvider.modelName))")
                }
            }
            .font(.system(size: 10))
            .foregroundColor(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(minWidth: 750, minHeight: 500)
    }
    
    private func exportCorpus() {
        let content = database.exportForFineTuning()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "rpa_corpus_finetune_\(Date().formatted(date: .numeric, time: .omitted)).jsonl"
        
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                let alert = NSAlert()
                alert.messageText = "导出失败"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }
}

struct CorpusRecordRowView: View {
    let recordId: UUID
    @ObservedObject var database = CorpusDatabase.shared
    
    @State private var isHovered = false
    @State private var showDetailSheet = false
    @State private var localIsTranslating = false
    
    private var currentRecord: WebCorpusRecord? {
        database.records.first(where: { $0.id == recordId })
    }
    
    var body: some View {
        guard let record = currentRecord else {
            return AnyView(EmptyView())
        }
        
        return AnyView(
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(record.userIntent)
                        .font(.system(size: 14, weight: .bold))
                        .lineLimit(1)
                    Spacer()
                    HStack(spacing: 12) {
                        Text("被调用: \(record.totalUsed)次")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(record.reliabilityStatus)
                            .font(.caption).bold()
                            .foregroundColor(getStatusColor(record.reliabilityStatus))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.gray.opacity(0.1))
                            .cornerRadius(4)
                    }
                }
                
                Text("录制时间: \(record.timestamp.formatted()) | 动作: \(record.actionType.uppercased()) | TargetID: \(record.targetId)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                
                if let thought = record.synthesizedThought, let steps = record.synthesizedStepsJSON {
                    VStack(alignment: .leading, spacing: 4) {
                        if !thought.contains("❌") {
                            Text("💡 \(thought)")
                                .font(.system(size: 11))
                                .foregroundColor(.purple)
                            Text(steps)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.blue)
                        } else {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                Text(thought)
                            }
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.red)
                            
                            Text(steps)
                                .font(.system(size: 10))
                                .foregroundColor(.red.opacity(0.8))
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(thought.contains("❌") ? Color.red.opacity(0.05) : Color.blue.opacity(0.05))
                    .cornerRadius(6)
                } else {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.6)
                        Text("AI 正在理解录制现场并生成推理...")
                            .font(.caption2)
                            .foregroundColor(.orange)
                            .italic()
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.05))
                    .cornerRadius(6)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
            .overlay(alignment: .topTrailing) {
                if isHovered {
                    HStack(spacing: 12) {
                        Button(action: { showDetailSheet = true }) { Image(systemName: "doc.text.magnifyingglass").foregroundColor(.blue) }.buttonStyle(.plain)
                        Button(action: {
                            Task {
                                localIsTranslating = true
                                await WebCorpusManager.shared.manualTranslate(recordId: record.id)
                                localIsTranslating = false
                            }
                        }) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .foregroundColor(localIsTranslating ? .gray : .orange)
                                .rotationEffect(localIsTranslating ? .degrees(360) : .zero)
                                .animation(localIsTranslating ? Animation.linear(duration: 1).repeatForever(autoreverses: false) : .default, value: localIsTranslating)
                        }
                        .buttonStyle(.plain)
                        .disabled(localIsTranslating)
                        
                        Button(action: {
                            withAnimation {
                                database.records.removeAll { $0.id == record.id }
                                database.save()
                            }
                        }) { Image(systemName: "trash").foregroundColor(.red) }.buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Capsule().fill(Color(NSColor.controlBackgroundColor).opacity(0.95)).shadow(color: .black.opacity(0.1), radius: 3, x: 0, y: 1))
                    .padding(.top, 4).padding(.trailing, 8)
                }
            }
            .onHover { hovering in withAnimation(.easeInOut(duration: 0.15)) { self.isHovered = hovering } }
            .sheet(isPresented: $showDetailSheet) { CorpusDetailView(record: record) }
        )
    }
    private func getStatusColor(_ status: String) -> Color {
        if status.contains("⚠️") { return .red }
        if status.contains("⭐️") { return .orange }
        if status.contains("✅") { return .green }
        return .secondary
    }
}

struct CorpusDetailView: View {
    @Environment(\.dismiss) var dismiss
    @State private var draftRecord: WebCorpusRecord
    @State private var isEditing: Bool = false
    
    init(record: WebCorpusRecord) { _draftRecord = State(initialValue: record) }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: isEditing ? "pencil.and.outline" : "eye.circle.fill")
                    .font(.title2)
                    .foregroundColor(isEditing ? .orange : .blue)
                Text(isEditing ? "编辑语料记录" : "语料录制现场快照")
                    .font(.headline)
                Spacer()
                if isEditing {
                    Button("取消") {
                        if let original = CorpusDatabase.shared.records.first(where: { $0.id == draftRecord.id }) { draftRecord = original }
                        withAnimation(.easeInOut(duration: 0.2)) { isEditing = false }
                    }
                    .buttonStyle(.plain).foregroundColor(.gray).padding(.trailing, 8)
                    Button(action: saveChanges) { HStack(spacing: 4) { Image(systemName: "checkmark"); Text("保存修改") } }.buttonStyle(.borderedProminent).tint(.blue).controlSize(.small)
                } else {
                    Button(action: { withAnimation(.easeInOut(duration: 0.2)) { isEditing = true } }) { Image(systemName: "square.and.pencil").foregroundColor(.blue) }.buttonStyle(.plain).help("编辑此条语料").padding(.trailing, 8)
                    Button(action: { dismiss() }) { Image(systemName: "xmark.circle.fill").foregroundColor(.gray.opacity(0.6)).font(.title3) }.buttonStyle(.plain)
                }
            }
            .padding().background(Color(NSColor.windowBackgroundColor))
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if isEditing { editForm() } else { readOnlyView() }
                }
                .padding()
            }
        }
        .frame(width: 600, height: 600)
    }
    
    private func saveChanges() {
        let db = CorpusDatabase.shared
        if let idx = db.records.firstIndex(where: { $0.id == draftRecord.id }) {
            db.objectWillChange.send()
            db.records[idx] = draftRecord
            db.save()
            withAnimation(.easeInOut(duration: 0.2)) { isEditing = false }
        }
    }
    
    @ViewBuilder
    private func editForm() -> some View {
        VStack(alignment: .leading, spacing: 16) {
            DarwinDataEditor(record: $draftRecord)
            VStack(alignment: .leading, spacing: 6) {
                Text("目标意图 (User Intent)").font(.caption).foregroundColor(.secondary)
                TextField("请输入用户操作意图", text: $draftRecord.userIntent).textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("交互动作 (Action Type)").font(.caption).foregroundColor(.secondary)
                    TextField("例如: click, input, sequence", text: $draftRecord.actionType).textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("目标 ID (Target ID)").font(.caption).foregroundColor(.secondary)
                    TextField("目标元素ID", text: $draftRecord.targetId).textFieldStyle(.roundedBorder)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("输入内容或序列 (Input Value / Sequence JSON)").font(.caption).foregroundColor(.secondary)
                PlainCodeEditor(text: Binding(get: { draftRecord.inputValue ?? "" }, set: { draftRecord.inputValue = $0.isEmpty ? nil : $0 }))
                .font(.system(size: 12, design: .monospaced)).frame(minHeight: 80).padding(4).background(Color(NSColor.textBackgroundColor)).overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.2)))
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("AI 推理过程 (Thought)").font(.caption).foregroundColor(.secondary)
                PlainCodeEditor(text: Binding(get: { draftRecord.synthesizedThought ?? "" }, set: { draftRecord.synthesizedThought = $0.isEmpty ? nil : $0 })).textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("可执行步骤 (Steps JSON) ⚠️ 必须是合法的 JSON").font(.caption).foregroundColor(.secondary)
                PlainCodeEditor(text: Binding(get: { draftRecord.synthesizedStepsJSON ?? "" }, set: { draftRecord.synthesizedStepsJSON = $0.isEmpty ? nil : $0 }))
                .font(.system(size: 12, design: .monospaced)).frame(minHeight: 120).padding(4).background(Color(NSColor.textBackgroundColor)).overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.2)))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("现场 DOM 结构 (Prompt Context)").font(.caption).foregroundColor(.secondary)
                PlainCodeEditor(text: $draftRecord.beforeDOM)
                    .font(.system(size: 11, design: .monospaced)).frame(minHeight: 100).padding(4).background(Color(NSColor.textBackgroundColor)).overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.2)))
            }
        }.padding(.top, 4)
    }
    
    @ViewBuilder
    private func readOnlyView() -> some View {
        Group {
            detailRow(title: "目标意图", content: draftRecord.userIntent)
            detailRow(title: "交互动作", content: draftRecord.actionType.uppercased())
            detailRow(title: "目标 ID", content: "[\(draftRecord.targetId)]")
            if let val = draftRecord.inputValue, !val.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("输入内容:").font(.system(size: 12, weight: .bold)).foregroundColor(.secondary)
                    Text(val).font(.system(size: 11, design: .monospaced)).foregroundColor(.primary).padding(8).frame(maxWidth: .infinity, alignment: .leading).background(Color.black.opacity(0.04)).cornerRadius(6)
                }
            }
            if let thought = draftRecord.synthesizedThought { detailRow(title: "AI 推理", content: "💡 \(thought)") }
            if let steps = draftRecord.synthesizedStepsJSON {
                VStack(alignment: .leading, spacing: 4) {
                    Text("执行步骤 JSON:").font(.system(size: 12, weight: .bold)).foregroundColor(.secondary).padding(.top, 4)
                    Text(steps).font(.system(size: 11, design: .monospaced)).foregroundColor(.blue).padding(8).frame(maxWidth: .infinity, alignment: .leading).background(Color.blue.opacity(0.05)).cornerRadius(6)
                }
            }
        }
        Divider().padding(.vertical, 4)
        Text("📋 录制瞬间的网页 DOM 精简树:").font(.system(size: 12, weight: .bold)).foregroundColor(.secondary)
        Text(draftRecord.beforeDOM).font(.system(size: 11, design: .monospaced)).foregroundColor(.primary).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Color.black.opacity(0.05)).cornerRadius(6).overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.2)))
    }
    
    private func detailRow(title: String, content: String) -> some View {
        HStack(alignment: .top) {
            Text(title + ":").font(.system(size: 12, weight: .bold)).foregroundColor(.secondary).frame(width: 85, alignment: .leading)
            Text(content).font(.system(size: 13)).foregroundColor(.primary)
        }
    }
}

struct DarwinDataEditor: View {
    @Binding var record: WebCorpusRecord
    var body: some View {
        GroupBox("📊 达尔文机制数据干预 (人工调权)") {
            HStack(spacing: 24) {
                HStack { Text("✅ 正确次数:").font(.caption).foregroundColor(.secondary); Stepper(value: $record.successCount, in: 0...99999) { Text("\(record.successCount)").font(.system(.body, design: .monospaced)).foregroundColor(.green).frame(minWidth: 35, alignment: .leading) } }
                HStack { Text("❌ 错误次数:").font(.caption).foregroundColor(.secondary); Stepper(value: $record.failCount, in: 0...99999) { Text("\(record.failCount)").font(.system(.body, design: .monospaced)).foregroundColor(.red).frame(minWidth: 35, alignment: .leading) } }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("总被调次数: \(record.totalUsed)").font(.caption).bold().foregroundColor(.primary)
                    Text("当前可靠性: \(record.reliabilityStatus)").font(.caption2).foregroundColor(record.reliabilityStatus.contains("高") ? .green : (record.reliabilityStatus.contains("低") ? .red : .orange))
                }.padding(.horizontal, 10).padding(.vertical, 6).background(Color.black.opacity(0.05)).cornerRadius(6)
            }.padding(8)
        }
    }
}

class CorpusManagerWindowController: NSWindowController {
    static var sharedController: CorpusManagerWindowController?
    @MainActor
    static func showWindow() {
        if sharedController == nil {
            let hostingController = NSHostingController(rootView: CorpusManagerView())
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 750, height: 550), styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "AI 动作经验库 (本地 RAG)"
            window.minSize = NSSize(width: 600, height: 400)
            window.center()
            window.isReleasedWhenClosed = false
            window.contentViewController = hostingController
            sharedController = CorpusManagerWindowController(window: window)
        }
        if let window = sharedController?.window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - 悬浮窗 HUD 组件
class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { return true }
    override var canBecomeMain: Bool { return false }
}

class CorpusHUDManager {
    static let shared = CorpusHUDManager()
    private var panel: HUDPanel?
    
    // [✨升级] 进一步扩大悬浮窗的高度，以容纳丰富的自动滚动列表与动作流面板
    private let expandedSize = NSSize(width: 380, height: 520)
    private let collapsedSize = NSSize(width: 170, height: 42)
    
    func toggleHUD() {
        if panel?.isVisible == true { hideHUD() } else { showHUD() }
    }
    
    func showHUD() {
        if panel == nil {
            let newPanel = HUDPanel(contentRect: NSRect(origin: .zero, size: collapsedSize), styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
            newPanel.isFloatingPanel = true; newPanel.level = .floating; newPanel.backgroundColor = .clear; newPanel.isOpaque = false; newPanel.hasShadow = true; newPanel.isMovableByWindowBackground = true; newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let host = NSHostingView(rootView: CorpusRecordingHUD())
            host.wantsLayer = true; host.layer?.cornerRadius = 20; host.layer?.masksToBounds = true; host.layer?.backgroundColor = NSColor.clear.cgColor
            newPanel.contentView = host; self.panel = newPanel
        }
        updatePanelFrame(animate: false); panel?.orderFrontRegardless()
    }
    
    func updatePanelFrame(animate: Bool = true) {
        guard let panel = panel, let screen = NSScreen.main else { return }
        let isRecording = WebCorpusManager.shared.isRecordingMode
        let targetSize = isRecording ? expandedSize : collapsedSize
        let screenFrame = screen.visibleFrame
        let targetX = screenFrame.maxX - targetSize.width - 20
        let targetY = screenFrame.maxY - targetSize.height - 10
        let newFrame = NSRect(origin: CGPoint(x: targetX, y: targetY), size: targetSize)
        
        if animate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.5; context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(newFrame, display: true)
            }
        } else {
            panel.setFrame(newFrame, display: true)
        }
    }
    
    func hideHUD() {
        if WebCorpusManager.shared.isRecordingMode { WebCorpusManager.shared.isRecordingMode = false }
        if let panel = panel {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2; panel.animator().alphaValue = 0
            } completionHandler: {
                self.panel?.orderOut(nil); self.panel?.alphaValue = 1.0
            }
        }
    }
}

// MARK: - [✨带教面板终极升级] (已修复编译器超时问题)
struct CorpusRecordingHUD: View {
    @ObservedObject var corpusManager = WebCorpusManager.shared
    @State private var pulseStage: CGFloat = 0.0
    @State private var glowRotation: Double = 0
    @State private var lastActionLog: String = "快捷键 ⌥⌘R 启停"
    @State private var logHighlight: Bool = false
    @State private var selectedEventId: UUID? = nil
    @State private var isCollapsedOverride: Bool = false // 允许在开启录制时手动收起

    var body: some View {
        mainContent
            .background(backgroundEffectView)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5))
            .shadow(color: Color.black.opacity(0.25), radius: 12)
            .onAppear(perform: setupAnimations)
            .onReceive(AgentMonitorManager.shared.$actionExecutionLogs, perform: handleNewLog)
            .onChange(of: corpusManager.isRecordingMode) { _ in CorpusHUDManager.shared.updatePanelFrame() }
            .onChange(of: isCollapsedOverride) { _ in CorpusHUDManager.shared.updatePanelFrame(animate: true) }
    }
    
    @ViewBuilder private var mainContent: some View {
        ZStack {
            if corpusManager.isRecordingMode && !isCollapsedOverride {
                expandedRecordingView
            } else {
                collapsedView
            }
        }
    }
    
    @ViewBuilder private var backgroundEffectView: some View {
        ZStack {
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
            if corpusManager.isRecordingMode && !corpusManager.isPaused {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(AngularGradient(colors: [.red, .orange, .clear, .orange, .red], center: .center, angle: .degrees(glowRotation)), lineWidth: 3)
            }
        }
    }
    
    private var expandedRecordingView: some View {
        VStack(alignment: .leading, spacing: 10) {
            topBarView
            
            TextField("在此备注当前操作意图...", text: $corpusManager.currentUserIntent)
                .textFieldStyle(.plain)
                .padding(9)
                .background(Color.primary.opacity(0.08))
                .cornerRadius(8)
                .font(.system(size: 12))
            
            HStack(spacing: 4) {
                Image(systemName: corpusManager.isPaused ? "pause.circle.fill" : "bolt.horizontal.circle.fill")
                    .foregroundColor(logHighlight ? .orange : .secondary)
                Text(lastActionLog).font(.system(size: 10, design: .monospaced))
                    .foregroundColor(logHighlight ? .orange : .secondary).lineLimit(1)
            }.padding(.horizontal, 4).id(lastActionLog)
            
            eventsScrollView
            
            bottomControlBar
        }
        .padding(14)
        .frame(width: 400, height: 500)
    }
    
    private var topBarView: some View {
        HStack {
            HStack(spacing: 6) {
                Circle().fill(corpusManager.isPaused ? Color.orange : (pulseStage > 0.5 ? Color.red : Color.darkRed))
                    .frame(width: 8, height: 8).shadow(color: corpusManager.isPaused ? .orange : .red, radius: pulseStage * 6)
                Text(corpusManager.isPaused ? "PAUSED" : "REC STEP")
                    .font(.system(size: 10, weight: .black)).foregroundColor(.white).opacity(corpusManager.isPaused ? 1.0 : (0.7 + pulseStage * 0.3))
            }.padding(.horizontal, 10).padding(.vertical, 4).background(corpusManager.isPaused ? Color.orange.opacity(0.8) : Color.red.opacity(0.8)).clipShape(Capsule())
            
            Spacer()
            // [✨新增] 展开窗体上的收起按钮
            Button(action: { withAnimation { isCollapsedOverride = true } }) {
                Image(systemName: "arrow.down.right.and.arrow.up.left").foregroundColor(.secondary).font(.system(size: 12))
            }.buttonStyle(.plain).padding(.trailing, 6).help("缩小面板")
            
            Button(action: { corpusManager.stopRecording() }) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 14))
            }.buttonStyle(.plain).foregroundColor(.secondary)
        }
    }
    
    // 3. 抽离复杂的滚动列表与 ScrollViewReader (调用新的回放 API)
    private var eventsScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(corpusManager.sessionEvents) { event in
                        CorpusEventRowView(
                            event: safeBinding(for: event),
                            isPlaying: corpusManager.playingEventId == event.id,
                            isSelected: selectedEventId == event.id,
                            onPlay: {
                                // [✨修改点] 传入 event 自身
                                Task { await corpusManager.playbackAction(event: event) }
                            },
                            onDelete: {
                                if selectedEventId == event.id {
                                    selectedEventId = nil
                                }
                                NSApp.keyWindow?.makeFirstResponder(nil)
                                withAnimation { corpusManager.deleteAction(id: event.id) }
                            }
                        )
                        .onTapGesture { selectedEventId = event.id }
                        .id(event.id)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 250)
            .background(Color(NSColor.windowBackgroundColor).opacity(0.5))
            .cornerRadius(8)
            .onChange(of: corpusManager.sessionEvents.count) { _, _ in
                if let lastId = corpusManager.sessionEvents.last?.id {
                    withAnimation { proxy.scrollTo(lastId, anchor: .bottom) }
                }
            }
            .onChange(of: corpusManager.playingEventId) { _, newId in
                if let playId = newId {
                    withAnimation { proxy.scrollTo(playId, anchor: .center) }
                }
            }
        }
    }
    
    // 4. 抽离底部工具栏 (加回清空按钮)
    private var bottomControlBar: some View {
        let hasSteps = !corpusManager.sessionEvents.isEmpty
        return HStack(spacing: 8) {
            // 暂停/继续录制
            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { corpusManager.isPaused.toggle() } }) {
                HStack(spacing: 4) { Image(systemName: corpusManager.isPaused ? "play.fill" : "pause.fill") }
                .font(.system(size: 10, weight: .bold)).frame(width: 24, height: 24)
                .background(corpusManager.isPaused ? Color.green.opacity(0.8) : Color.orange.opacity(0.8))
                .foregroundColor(.white).clipShape(Circle())
            }.buttonStyle(.plain).help(corpusManager.isPaused ? "继续录制" : "暂停捕获")
            
            // 插入等待节点
            Button(action: { withAnimation { corpusManager.addWaitAction() } }) {
                Image(systemName: "timer")
                .font(.system(size: 11, weight: .bold)).frame(width: 24, height: 24)
                .background(Color.cyan.opacity(0.8)).foregroundColor(.white).clipShape(Circle())
            }.buttonStyle(.plain).help("插入1秒等待节点")
            
            // 回放全部
            Button(action: { Task { await corpusManager.playAllActions() } }) {
                HStack(spacing: 4) { Image(systemName: "play.rectangle.fill"); Text("回放") }
                .font(.system(size: 10, weight: .bold)).padding(.horizontal, 8).padding(.vertical, 5)
                .background(hasSteps ? Color.purple.opacity(0.8) : Color.gray.opacity(0.3))
                .foregroundColor(hasSteps ? .white : .gray).clipShape(Capsule())
            }.buttonStyle(.plain).disabled(!hasSteps || corpusManager.playingEventId != nil).help("可视化按序回放所有动作")
            
            // 停止录制 (退出带教模式)
            Button(action: { corpusManager.stopRecording() }) {
                HStack(spacing: 4) { Image(systemName: "stop.fill") }
                .font(.system(size: 10, weight: .bold)).padding(.horizontal, 6).padding(.vertical, 5)
                .background(Color.gray.opacity(0.8)).foregroundColor(.white).clipShape(Circle())
            }.buttonStyle(.plain).help("停止录制并关闭")
            
            // [✨新增/保留] 清空按钮
            Button(action: { withAnimation { corpusManager.restartRecordingSession() } }) {
                HStack(spacing: 4) { Image(systemName: "trash.fill") }
                .font(.system(size: 10, weight: .bold)).padding(.horizontal, 6).padding(.vertical, 5)
                .background(hasSteps ? Color.red.opacity(0.8) : Color.gray.opacity(0.3))
                .foregroundColor(hasSteps ? .white : .gray).clipShape(Circle())
            }.buttonStyle(.plain).disabled(!hasSteps).help("清空当前已录制的动作流")
            
            Spacer()
            
            // 保存
            Button(action: { Task { await corpusManager.saveSessionAndContinue() } }) {
                Text(hasSteps ? "保存 (\(corpusManager.sessionEvents.count)步)" : "等待中")
                    .font(.system(size: 11, weight: .bold)).padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Capsule().fill(hasSteps ? Color.blue : Color.gray.opacity(0.5)))
                    .foregroundColor(hasSteps ? .white : .gray)
                    .shadow(color: (hasSteps ? Color.blue : Color.clear).opacity(0.4), radius: 4)
            }.buttonStyle(.plain).disabled(!hasSteps)
        }
    }
    
    // [✨核心防崩补丁] 手动安全构建 Binding，完美拦截数组删除时的越界崩溃
    private func safeBinding(for event: WebCorpusManager.RawSessionEvent) -> Binding<WebCorpusManager.RawSessionEvent> {
        Binding(
            get: {
                if let index = corpusManager.sessionEvents.firstIndex(where: { $0.id == event.id }) {
                    return corpusManager.sessionEvents[index]
                }
                return event // 如果元素已被删除，返回传入的快照进行兜底渲染，阻止 Crash
            },
            set: { newValue in
                if let index = corpusManager.sessionEvents.firstIndex(where: { $0.id == event.id }) {
                    corpusManager.sessionEvents[index] = newValue
                }
            }
        )
    }
    
    // [✨修改] 小窗体去掉文字，纯粹的操作栏
    private var collapsedView: some View {
        HStack(spacing: 12) {
            // 开始/暂停按钮
            Button(action: { withAnimation { corpusManager.isPaused.toggle() } }) {
                Circle().fill(corpusManager.isPaused ? Color.green : Color.orange)
                    .frame(width: 16, height: 16).overlay(Image(systemName: corpusManager.isPaused ? "play.fill" : "pause.fill").font(.system(size: 8, weight: .bold)).foregroundColor(.white))
            }.buttonStyle(.plain)
            
            Spacer()
            
            // 展开按钮
            Button(action: {
                if !corpusManager.isRecordingMode { corpusManager.isRecordingMode = true }
                withAnimation { isCollapsedOverride = false }
            }) {
                Image(systemName: "arrow.up.left.and.arrow.down.right").foregroundColor(.blue).font(.system(size: 12, weight: .bold))
            }.buttonStyle(.plain)
            
            // 关闭/停止录制按钮
            Button(action: { corpusManager.stopRecording() }) {
                Image(systemName: "xmark.circle.fill").foregroundColor(.red).font(.system(size: 14))
            }.buttonStyle(.plain)
        }.padding(.horizontal, 12).frame(width: 140, height: 38)
    }
    
    private func setupAnimations() {
        withAnimation(.linear(duration: 3).repeatForever(autoreverses: false)) { glowRotation = 360 }
        withAnimation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true)) { pulseStage = 1.0 }
    }
    
    private func handleNewLog(_ logs: [String]) {
        if let last = logs.last {
            self.lastActionLog = last
            withAnimation(.none) { self.logHighlight = true }
            withAnimation(.easeOut(duration: 1.5).delay(1.0)) { self.logHighlight = false }
        }
    }
}

// 5. [✨关键提取] 单行组件 (支持 TargetID 与描述的完全编辑)
struct CorpusEventRowView: View {
    @Binding var event: WebCorpusManager.RawSessionEvent
    var isPlaying: Bool
    var isSelected: Bool
    var onPlay: () -> Void
    var onDelete: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                // 1. 动作列 (定宽，对齐)
                Text("[\(event.actionType)]")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.blue)
                    .frame(width: 60, alignment: .leading)
                
                // 2. ID 列 (自适应缩小，但有一个固定最小宽度确保整体对齐)
                HStack(spacing: 2) {
                    Text("ID:")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                    TextField("空", text: $event.targetId)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 4).padding(.vertical, 1)
                .frame(width: 80, alignment: .leading) // 锁定 ID 区块宽度
                .background(Color.red.opacity(0.8))
                .cornerRadius(4)
                
                // 3. 内容列 (占据剩余空间)
                TextField("元素描述", text: $event.elementText)
                    .font(.system(size: 11))
                    .foregroundColor(.primary)
                    .textFieldStyle(.plain)
                
                Spacer()
                
                if isPlaying {
                    Image(systemName: "play.circle.fill").foregroundColor(.green)
                } else {
                    Button(action: onPlay) { Image(systemName: "play.fill").font(.system(size: 10)).foregroundColor(.secondary) }.buttonStyle(.plain)
                }
                Button(action: onDelete) { Image(systemName: "trash").font(.system(size: 10)).foregroundColor(.red.opacity(0.7)) }.buttonStyle(.plain).padding(.leading, 4)
            }
            
            if event.actionType == "input" || event.actionType == "wait" {
                HStack {
                    Image(systemName: "arrow.turn.down.right").foregroundColor(.secondary).font(.system(size: 10)).frame(width: 60, alignment: .trailing)
                    // ... 你的输入框逻辑体保持不变 ...
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(isPlaying ? Color.green.opacity(0.2) : (isSelected ? Color.blue.opacity(0.2) : Color.black.opacity(0.05))))
    }
}

extension Color {
    static let darkRed = Color(red: 0.5, green: 0, blue: 0)
}

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material; var blendingMode: NSVisualEffectView.BlendingMode
    func makeNSView(context: Context) -> NSVisualEffectView { let view = NSVisualEffectView(); view.material = material; view.blendingMode = blendingMode; view.state = .active; return view }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
