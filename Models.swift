//////////////////////////////////////////////////////////////////
// 文件名：Models.swift
// 文件说明：这是适用于 macos 14+ 的RPA数据模型与存储层
// 功能说明：包含 Web Agent 3.0 的数据结构与枚举定义
// 代码要求：保留了所有的极客级小组件和底层原生 UI 元素拾取防死锁逻辑。
//////////////////////////////////////////////////////////////////

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
    case webAgent = "🌟 Web智能体自主操作" // [✨新增] Web Agent 3.0
    case condition = "条件判断分支"
    case wait = "等待延时"
    case runShell = "执行Shell脚本"
    case runAppleScript = "执行AppleScript"
    case setVariable = "设置全局变量"
    case httpRequest = "发送HTTP请求"
    case uiInteraction = "原生UI元素交互"
    
    var category: ActionCategory {
        switch self {
        case .openApp, .openURL, .showNotification, .uiInteraction: return .system
        case .typeText, .mouseOperation, .readClipboard, .writeClipboard: return .mouseKeyboard
        case .ocrText, .aiVision, .webAgent: return .aiVision
        case .condition, .wait, .runShell, .runAppleScript, .setVariable, .httpRequest: return .logicData
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
        case .webAgent: // [✨新增] Web Agent 标题
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
    var id = UUID()
    var name: String
    var actions: [RPAAction]
    var connections: [WorkflowConnection]
    
    init(name: String, actions: [RPAAction] = [], connections: [WorkflowConnection] = []) {
        self.name = name; self.actions = actions; self.connections = connections
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
