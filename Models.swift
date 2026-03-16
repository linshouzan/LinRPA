//////////////////////////////////////////////////////////////////
// 文件名：Models.swift
// 文件说明：这是适用于 macos 14+ 的RPA数据模型与存储层
// 功能说明：包含 Web Agent 3.0 的数据结构与枚举定义
// 代码要求：保留了所有的极客级小组件和底层原生 UI 元素拾取防死锁逻辑。
//////////////////////////////////////////////////////////////////

import SwiftUI
import Combine
import Foundation
import AppKit

// MARK: - 动作分类与定义
enum ActionCategory: String, CaseIterable, Codable {
    case system = "系统与应用"
    case mouseKeyboard = "鼠标与键盘"
    case aiVision = "AI 与视觉"
    case logicData = "逻辑与数据"
}

enum ActionType: String, CaseIterable, Codable {
    case openApp = "打开/激活应用程序"
    case openURL = "打开网址"
    case showNotification = "系统消息提醒"
    case typeText = "键盘操作"
    case mouseOperation = "鼠标操作"
    case readClipboard = "读取剪贴板"
    case writeClipboard = "写入剪贴板"
    case ocrText = "识别屏幕文字"
    case aiVision = "AI屏幕视觉分析"
    case webAgent = "Web智能体自主操作" // [✨新增] Web Agent 3.0
    case condition = "条件判断分支"
    case wait = "等待延时"
    case runShell = "执行Shell脚本"
    case runAppleScript = "执行AppleScript"
    case setVariable = "设置全局变量"
    case httpRequest = "发送HTTP请求"
    case uiInteraction = "原生UI元素交互"
    case callWorkflow = "调用子工作流"
    
    var category: ActionCategory {
        switch self {
        case .openApp, .openURL, .showNotification, .uiInteraction: return .system
        case .typeText, .mouseOperation, .readClipboard, .writeClipboard: return .mouseKeyboard
        case .ocrText, .aiVision, .webAgent: return .aiVision
        case .condition, .wait, .runShell, .runAppleScript, .setVariable, .httpRequest, .callWorkflow: return .logicData
        }
    }
    
    var icon: String {
        switch self {
        case .openApp: return "macwindow"
        case .openURL: return "safari"
        case .typeText: return "keyboard"
        case .mouseOperation: return "magicmouse"
        case .ocrText: return "text.viewfinder"
        case .readClipboard: return "doc.on.clipboard"
        case .writeClipboard: return "clipboard"
        case .runShell: return "terminal"
        case .runAppleScript: return "applescript.fill"
        case .condition: return "arrow.triangle.branch"
        case .showNotification: return "bell.badge.fill"
        case .wait: return "timer"
        case .aiVision: return "brain.head.profile"
        case .webAgent: return "globe.badge.chevron.backward" // 专属图标
        case .setVariable: return "tray.full.fill"
        case .httpRequest: return "network"
        case .uiInteraction: return "macwindow.on.rectangle"
        case .callWorkflow: return "arrow.triangle.merge"
        }
    }
}

enum macOSKeyCodes: UInt16 {
    case returnKey = 0x24, tab = 0x30, space = 0x31, delete = 0x33, escape = 0x35
}

enum PortPosition: String, Codable, CaseIterable {
    case top, bottom, left, right
    var controlOffset: CGSize {
        let offset: CGFloat = 80
        switch self {
        case .top: return CGSize(width: 0, height: -offset)
        case .bottom: return CGSize(width: 0, height: offset)
        case .left: return CGSize(width: -offset, height: 0)
        case .right: return CGSize(width: offset, height: 0)
        }
    }
}

enum ConnectionCondition: String, Codable {
    case always = "always", success = "success", failure = "failure"
}

struct WorkflowConnection: Identifiable, Codable, Hashable {
    var id = UUID()
    var startNodeID: UUID
    var endNodeID: UUID
    var startPort: PortPosition
    var endPort: PortPosition
    var condition: ConnectionCondition = .always
}

struct RPAAction: Identifiable, Codable, Equatable, Hashable {
    var id = UUID()
    let type: ActionType
    var parameter: String
    var positionX: Double = 0.0
    var positionY: Double = 0.0
    
    var customName: String = ""
    var offsetX: Double = 0.0
    var offsetY: Double = 0.0
    var sampleImageBase64: String = ""
    // [✨新增] 节点是否被禁用（运行时跳过）
    var isDisabled: Bool = false
    
    var displayTitle: String {
        if !customName.isEmpty { return customName }
        switch type {
        case .wait: return "延时 \(parameter.isEmpty ? "1" : parameter) 秒"
        case .openApp: return parameter.isEmpty ? type.rawValue : "打开 \(parameter)"
        case .openURL:
            let parts = parameter.components(separatedBy: "|")
            let url = parts.count > 0 ? parts[0] : parameter
            return url.isEmpty ? type.rawValue : "打开 \(url)"
        case .typeText: return parameter.isEmpty ? type.rawValue : "输入: \(parameter.count > 8 ? "\(parameter.prefix(8))..." : parameter)"
        case .ocrText: let text = parameter.components(separatedBy: "|").first ?? ""; return text.isEmpty ? type.rawValue : "识别: \(text)"
        case .condition: let parts = parameter.components(separatedBy: "|"); return parts.count >= 3 ? "判断: \(parts[0]) \(parts[1] == "==" ? "等于" : "包含")" : type.rawValue
        case .showNotification: let parts = parameter.components(separatedBy: "|"); return parts.count > 1 && !parts[1].isEmpty ? "提醒: \(parts[1])" : type.rawValue
        case .webAgent:
            let parts = parameter.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            let task = parts.count > 0 ? parts[0] : ""
            return task.isEmpty ? type.rawValue : "Agent: \(task.count > 10 ? "\(task.prefix(10))..." : task)"
        case .mouseOperation:
            if parameter.contains("drag") { return "鼠标拖拽" }
            if parameter.contains("Click") { return "鼠标点击" }
            if parameter.contains("move") { return "移动光标" }
            if parameter.contains("cmdScrollUp") { return "滚至顶端" }
            if parameter.contains("cmdScrollDown") { return "滚至底端" }
            if parameter.lowercased().contains("scroll") { return "鼠标滚动" }
            return type.rawValue
        case .setVariable: let parts = parameter.components(separatedBy: "|"); return parts.count > 0 ? "设置变量: \(parts[0])" : type.rawValue
        case .uiInteraction:
            let parts = parameter.components(separatedBy: "|")
            let appName = parts.count > 0 ? parts[0] : ""
            let actionStr = parts.count > 3 ? (parts[3] == "click" ? "点击" : "读取") : "操作"
            let matchMode = parts.count > 4 ? parts[4] : "exact"
            let titleStr = parts.count > 2 ? parts[2] : ""
            let prefix = matchMode == "contains" ? "包含" : (matchMode == "regex" ? "正则匹配" : "")
            return appName.isEmpty ? type.rawValue : "\(actionStr): \(appName) \(prefix) [\(titleStr.isEmpty ? "元素" : titleStr)]"
        default: return type.rawValue
        }
    }
}

struct Workflow: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var folderName: String
    var actions: [RPAAction]
    var connections: [WorkflowConnection]
    
    // 手动映射字段
    enum CodingKeys: String, CodingKey {
        case id, name, folderName, actions, connections
    }
    
    // 默认初始化
    init(id: UUID = UUID(), name: String, folderName: String = "默认文件夹", actions: [RPAAction] = [], connections: [WorkflowConnection] = []) {
        self.id = id
        self.name = name
        self.folderName = folderName
        self.actions = actions
        self.connections = connections
    }
    
    // 【✨核心修复】兼容旧版本 JSON 数据的解码器
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? "未命名流程"
        
        // 如果旧 JSON 里没有 folderName 字段，自动赋值为 "默认文件夹" 而不是崩溃
        self.folderName = try container.decodeIfPresent(String.self, forKey: .folderName) ?? "默认文件夹"
        
        self.actions = try container.decodeIfPresent([RPAAction].self, forKey: .actions) ?? []
        self.connections = try container.decodeIfPresent([WorkflowConnection].self, forKey: .connections) ?? []
    }
}

class StorageManager {
    static let shared = StorageManager()
    private let fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("autoflow.json")
    
    func save(workflows: [Workflow]) {
        if let data = try? JSONEncoder().encode(workflows) { try? data.write(to: fileURL) }
    }
    
    func load() -> [Workflow] {
        guard let data = try? Data(contentsOf: fileURL), let workflows = try? JSONDecoder().decode([Workflow].self, from: data) else {
            return [Workflow(name: "自定义工作流程 1")]
        }
        return workflows
    }
}

// MARK: - [✨新增] 全局应用设置管理器
class AppSettings: ObservableObject {
    static let shared = AppSettings()
    
    // [✨新增] WebAgent 最大思考与动作执行轮数限制
    @AppStorage("webAgent_max_rounds") var webAgentMaxRounds: Int = 10
    
    // 运行偏好 (默认运行时不最小化窗口)
    @AppStorage("minimize_on_run") var minimizeOnRun: Bool = false
    
    // WebAgent的AI提示词
    @AppStorage("webAgentPrompt") var webAgentPrompt: String = """
    你是一个顶级 Web RPA 智能体。结合给定的【屏幕截图】和【DOM列表】，你需要规划接下来的一个或多个连续动作。
    注意：截图中可交互元素已被打上红色数字方框，请通过图片找到正确元素，并参考DOM列表提取目标ID。
    
    【任务目标】: {{TaskDesc}}
    【成功视觉断言】: {{SuccessAssertion}}
    【操作手册】: {{Manual}}
    【历史操作记录】:
    {{History}}
    
    ⚠️ 关键指令 ⚠️
    1. 如果任务需要多步连贯操作（例如：先 hover，再 click，再 input），请在 steps 数组中一次性输出多个动作。
    2. 如果历史记录中你刚执行过动作，但当前截图里没有任何变化，说明该ID可能无效。请重新寻找其他ID，或者换物理操作，如click换成native_click。
    3. 如果屏幕上找不到需要的元素，请尝试输出 scroll_down。
    
    🔐 敏感信息输入规范 🔐
    如果你判断当前是登录、密码输入等敏感输入框，**绝对不要尝试自己生成或捏造账号密码**。请在 `input_value` 中严格输出变量占位符！
    例如输入账号时输出 `{{account}}`，输入密码时输出 `{{password}}`。系统底层会自动拦截并替换为真实的安全凭证。
    
    【当前可见元素 (ID与截图对应)】:
    {{DOM}}
    
    【可选动作空间】 (请自由组合):
    - hover / click / input: 默认的底层 JS 注入操作 (速度极快)
    - native_hover / native_click / native_input: 原生物理外设操作 (仅当普通操作失效，或遇到防爬检测时使用)
    - scroll_down / scroll_up: 页面滚动
    - finish / fail: 任务成功完成(包含满足【成功视觉断言】)或失败请求接管
    
    严格输出如下 JSON 格式 (切勿输出其他废话):
    {
      "thought": "分析图文与历史记录，规划接下来的连续动作步骤的思考过程",
      "steps": [
        {
          "action_type": "hover/click/input/native_click/scroll_down/finish/fail",
          "target_id": "红框上的数字ID(无元素留空)",
          "input_value": "如果是input，填写内容(否则留空)"
        }
      ]
    }
    """
}

// MARK: - [✨新增] AI 模型配置与全局管理器

struct AIProvider: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String        // 例: "Ollama (本地默认)" 或 "DeepSeek"
    var host: String        // 例: "http://127.0.0.1:11434/v1/chat/completions"
    var modelName: String   // 例: "qwen3-vl:4b" 或 "deepseek-reasoner"
    var apiKey: String      // 例: "sk-local" 或 "sk-xxxxxx"
}

class AIConfigManager: ObservableObject {
    static let shared = AIConfigManager()
    
    @Published var providers: [AIProvider] = [] {
        didSet { save() }
    }
    
    @Published var activeProviderId: UUID? {
        didSet {
            if let id = activeProviderId {
                UserDefaults.standard.set(id.uuidString, forKey: "ActiveAIProviderId")
            }
        }
    }
    
    init() {
        load()
    }
    
    // 获取当前正在生效的 AI 模型节点
    var activeProvider: AIProvider {
        if let id = activeProviderId, let provider = providers.first(where: { $0.id == id }) {
            return provider
        }
        // [兜底策略] 如果没有配置，永远返回默认的本地模型
        return providers.first ?? AIProvider(
            name: "Ollama 本地视觉模型",
            host: "http://127.0.0.1:11434/v1/chat/completions",
            modelName: "qwen3-vl:4b",
            apiKey: "sk-local-token"
        )
    }
    
    private func load() {
        if let data = UserDefaults.standard.data(forKey: "AIProvidersData"),
           let decoded = try? JSONDecoder().decode([AIProvider].self, from: data) {
            self.providers = decoded
        } else {
            // 首次初始化，注入两套默认配置模板
            self.providers = [
                AIProvider(name: "Ollama (本地视觉)", host: "http://127.0.0.1:11434/v1/chat/completions", modelName: "qwen3-vl:4b", apiKey: "sk-local-token"),
                AIProvider(name: "DeepSeek (云端推理)", host: "https://api.deepseek.com/v1/chat/completions", modelName: "deepseek-reasoner", apiKey: "")
            ]
        }
        
        if let savedIdStr = UserDefaults.standard.string(forKey: "ActiveAIProviderId"),
           let savedId = UUID(uuidString: savedIdStr),
           providers.contains(where: { $0.id == savedId }) {
            self.activeProviderId = savedId
        } else {
            self.activeProviderId = providers.first?.id
        }
    }
    
    private func save() {
        if let data = try? JSONEncoder().encode(providers) {
            UserDefaults.standard.set(data, forKey: "AIProvidersData")
        }
    }
}

// MARK: - WebAgent 4.0 参数与 Prompt 配置模型
public struct WebAgentParams: Codable, Equatable {
    var taskDesc: String
    var browser: String
    var requireConfirm: Bool
    var manualText: String
    var captureMode: String
    var successAssertion: String
    var assertionType: String // [✨新增] 断言类型：支持 "ai" (智能裁判) 或 "ocr" (精准识字)
    
    // 智能解析：兼容新的 JSON 格式、缺省字段以及旧的 "|" 拼接格式
    static func parse(from string: String) -> WebAgentParams {
        if let data = string.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return WebAgentParams(
                taskDesc: dict["taskDesc"] as? String ?? "",
                browser: dict["browser"] as? String ?? "InternalBrowser",
                requireConfirm: dict["requireConfirm"] as? Bool ?? true,
                manualText: dict["manualText"] as? String ?? "",
                captureMode: dict["captureMode"] as? String ?? "app",
                successAssertion: dict["successAssertion"] as? String ?? "",
                assertionType: dict["assertionType"] as? String ?? "ocr" // 默认为 OCR
            )
        }
        
        // 兼容极早期版本的旧版参数解析
        let parts = string.split(separator: "|", maxSplits: 6, omittingEmptySubsequences: false).map(String.init)
        return WebAgentParams(
            taskDesc: parts.count > 0 ? parts[0] : "",
            browser: parts.count > 1 ? parts[1] : "InternalBrowser",
            requireConfirm: parts.count > 2 ? (parts[2] == "true") : true,
            manualText: parts.count > 3 ? parts[3] : "",
            captureMode: parts.count > 4 ? parts[4] : "app",
            successAssertion: parts.count > 5 ? parts[5] : "",
            assertionType: "ocr"
        )
    }
    
    // 序列化为 JSON 字符串保存
    func encode() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys // 保证每次生成的 JSON 字段顺序绝对一致
        if let data = try? encoder.encode(self),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return ""
    }
}
