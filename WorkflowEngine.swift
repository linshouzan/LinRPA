//////////////////////////////////////////////////////////////////
// 文件名：WorkflowEngine.swift
// 文件说明：这是适用于 macos 14+ 的RPA流程引擎管理器 (重构解耦版)
// 功能说明：完美倒计时 HUD 裁切与对比度；新增列表重排；智能 OCR 视觉特征距离匹配；激活应用能力提升；支持鼠标拖拽轨迹及相对坐标解析；支持OCR区域裁切加速。
// 架构优化：已将具体的 Action 执行逻辑彻底剥离至 ActionExecutors，本文件专注流程调度与系统底层交互。
// 代码要求：没有要求修改不用输出代码，请保证代码的逻辑和完整性，保留代码中的所有注释内容
//////////////////////////////////////////////////////////////////

import SwiftUI
import Foundation
import AppKit
import Observation
import Vision
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit

struct ScreenCaptureUtility {
    /// 截取屏幕（支持精准窗口标题过滤，解决多窗口自身干扰问题）
    static func captureScreen(forAppName targetAppName: String? = nil, targetWindowTitle: String? = nil) async throws -> CGImage {
        
        let content = try await SCShareableContent.current
        guard let primaryDisplay = content.displays.first else {
            throw NSError(domain: "ScreenCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "未找到主显示器"])
        }
        
        var captureDisplay = primaryDisplay
        var filter: SCContentFilter?
        
        if let appName = targetAppName, !appName.isEmpty {
            if let targetApp = content.applications.first(where: {
                $0.applicationName.localizedCaseInsensitiveContains(appName) ||
                $0.bundleIdentifier.localizedCaseInsensitiveContains(appName)
            }) {
                var realWindows = content.windows.filter { win in
                    win.owningApplication?.processID == targetApp.processID &&
                    win.frame.width > 50 &&
                    win.frame.height > 50
                }
                
                // [✨核心修复] 精确匹配窗口标题，将其他窗口（如主控制台、监控面板）剔除出白名单
                if let exactTitle = targetWindowTitle, !exactTitle.isEmpty {
                    let matchedWindows = realWindows.filter { $0.title?.contains(exactTitle) == true }
                    if !matchedWindows.isEmpty {
                        realWindows = matchedWindows
                    }
                }
                
                if !realWindows.isEmpty {
                    if let firstWin = realWindows.first,
                       let targetDisp = content.displays.first(where: { $0.frame.intersects(firstWin.frame) }) {
                        captureDisplay = targetDisp
                    }
                    // SCContentFilter 的 including 模式会完美地只渲染白名单窗口，其余透明/纯黑
                    filter = SCContentFilter(display: captureDisplay, including: realWindows)
                } else {
                    print("⚠️ 未检测到 [\(appName)] 的合法可视窗口，降级为全屏截图")
                }
            }
        }
        
        if filter == nil {
            filter = SCContentFilter(display: captureDisplay, excludingWindows: [])
        }
        
        let scaleFactor: CGFloat = await MainActor.run {
            var factor: CGFloat = 1.0
            for screen in NSScreen.screens {
                if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                    if CGDirectDisplayID(screenNumber.uint32Value) == captureDisplay.displayID {
                        factor = screen.backingScaleFactor
                        break
                    }
                }
            }
            return factor
        }
        
        let pixelWidth = Int(CGFloat(captureDisplay.width) * scaleFactor)
        let pixelHeight = Int(CGFloat(captureDisplay.height) * scaleFactor)
        
        guard pixelWidth > 100, pixelHeight > 100 else {
            throw NSError(domain: "ScreenCapture", code: 3, userInfo: [NSLocalizedDescriptionKey: "获取到的显示器尺寸异常"])
        }
        
        let config = SCStreamConfiguration()
        config.width = pixelWidth
        config.height = pixelHeight
        config.showsCursor = false
        config.backgroundColor = CGColor.black
        config.colorSpaceName = CGColorSpace.sRGB
        
        return try await SCScreenshotManager.captureImage(contentFilter: filter!, configuration: config)
    }
}

@Observable
class WorkflowEngine {
    var workflows: [Workflow] = [] { didSet { if !isLoading { hasUnsavedChanges = true } } }
    var selectedWorkflowId: UUID? = nil
    var isRunning = false{ didSet { if !isRunning { currentActionId = nil } } }
    var currentActionId: UUID? = nil
    var logs: [String] = []
    
    // [✨全局变量池]
    var variables: [String: String] = [:]
    var folders: [String] = ["默认文件夹"] { didSet { UserDefaults.standard.set(folders, forKey: "RPA_Folders") } }
    
    var hasAccessibilityPermission: Bool = false
    var hasScreenRecordingPermission: Bool = false
    var currentWorkflowIndex: Int? { workflows.firstIndex(where: { $0.id == selectedWorkflowId }) }
    
    var nodePositions: [UUID: CGPoint] = [:]
    var hasUnsavedChanges: Bool = false
    @ObservationIgnored private var isLoading = false
    
    @ObservationIgnored private var globalKeyMonitor: Any?
    @ObservationIgnored private var localKeyMonitor: Any?
    
    @ObservationIgnored private var windowObservers: [Any] = []
    
    init() {
        isLoading = true; workflows = StorageManager.shared.load(); selectedWorkflowId = workflows.first?.id; isLoading = false
        hasUnsavedChanges = false; checkPermissions(); setupHotkeys()
        // 初始化时加载文件夹
        if let savedFolders = UserDefaults.standard.stringArray(forKey: "RPA_Folders") {
            self.folders = savedFolders
        }
        if !self.folders.contains("默认文件夹") { self.folders.insert("默认文件夹", at: 0) }
        
        setupWindowObservers()
    }
    
    deinit {
        if let monitor = globalKeyMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = localKeyMonitor { NSEvent.removeMonitor(monitor) }
        
        // 释放通知监听
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }
    
    // [✨修改] 监听主界面的显示、最小化与关闭事件
    private func setupWindowObservers() {
        // 1. 监听主窗口变成活动窗口 (完美解决：主窗体被激活显示时，自动隐藏悬浮窗)
        let becomeKeyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { notification in
            guard let window = notification.object as? NSWindow else { return }
            
            // 🛑 核心修复：过滤 SwiftUI 内部生成的临时窗口（如右键菜单、Popover、Alert 等）
            // 只有真正的主窗口才予以放行响应
            guard window.className.contains("AppKitWindow") || window.title == "我的流程" else { return }
            
            ExecutionToolbarManager.shared.hide()
        }
        
        // 2. 监听主窗口最小化 (触发显示悬浮窗)
        let minObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMiniaturizeNotification, object: nil, queue: .main) { [weak self] notification in
            guard let self = self, let window = notification.object as? NSWindow else { return }
            
            // 🛑 核心修复：精准阻断非主窗体
            guard window.className.contains("AppKitWindow") || window.title == "我的流程" else { return }
            
            ExecutionToolbarManager.shared.show(engine: self)
        }
        
        // 3. 监听主窗口关闭 (触发显示悬浮窗)
        let closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] notification in
            guard let self = self, let window = notification.object as? NSWindow else { return }
            
            // 🛑 核心修复：防止右键菜单或气泡关闭时，错误触发悬浮窗弹出的 Bug
            guard window.className.contains("AppKitWindow") || window.title == "我的流程" else { return }
            
            // [✨终极黑魔法] 赶在系统把主窗口释放掉之前，强行阻断销毁流程，让其处于“隐藏”而非“死亡”状态
            window.isReleasedWhenClosed = false
            
            ExecutionToolbarManager.shared.show(engine: self)
        }
        
        windowObservers = [becomeKeyObserver, minObserver, closeObserver]
    }
    
    // 【✨新增】文件夹 CRUD 方法
    func addFolder(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !folders.contains(trimmed) else { return }
        folders.append(trimmed)
    }
    
    func renameFolder(oldName: String, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !folders.contains(trimmed), oldName != "默认文件夹" else { return }
        
        // 1. 改文件夹列表
        if let idx = folders.firstIndex(of: oldName) { folders[idx] = trimmed }
        // 2. 批量把该文件夹下的工作流归属修改掉
        for i in 0..<workflows.count {
            if workflows[i].folderName == oldName { workflows[i].folderName = trimmed }
        }
        saveChanges()
    }
    
    func deleteFolder(name: String) {
        guard name != "默认文件夹" else { return } // 默认文件夹不允许删除
        folders.removeAll { $0 == name }
        // 自动把里面的文件踢回默认文件夹
        for i in 0..<workflows.count {
            if workflows[i].folderName == name { workflows[i].folderName = "默认文件夹" }
        }
        saveChanges()
    }
    
    private func setupHotkeys() {
        let handler: (NSEvent) -> Void = { [weak self] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags.contains([.command, .option]) && event.keyCode == 1 {
                if self?.isRunning == true { self?.isRunning = false; self?.log("🛑 检测到停止快捷键 (Cmd+Opt+S)，紧急中止执行！") }
            }
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler)
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in handler(event); return event }
    }
    
    func saveChanges() { StorageManager.shared.save(workflows: workflows); hasUnsavedChanges = false; log("💾 流程及配置已保存") }
    func discardChanges() { isLoading = true; workflows = StorageManager.shared.load(); nodePositions.removeAll(); isLoading = false; hasUnsavedChanges = false; log("🔄 已撤销所有未保存的修改") }
    
    // MARK: - [✨新增] 跳转系统隐私设置面板
    func openSystemSettings(for type: String) {
        let urlString: String
        if type == "accessibility" {
            // 跳转到 隐私与安全性 -> 辅助功能
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        } else {
            // 跳转到 隐私与安全性 -> 屏幕录制
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        }
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - 权限检查与阶梯式引导
    func checkPermissions(isUserInitiated: Bool = false) {
        // 1. 静默检查当前权限状态（设置 Prompt 为 false，绝对不弹窗）
        let checkOptions = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        let isAxTrusted = AXIsProcessTrustedWithOptions(checkOptions)
        let isScreenTrusted = CGPreflightScreenCaptureAccess()
        
        self.hasAccessibilityPermission = isAxTrusted
        self.hasScreenRecordingPermission = isScreenTrusted
        
        // 2. 如果是用户主动点击“刷新”按钮触发的检查
        if isUserInitiated {
            if !isAxTrusted {
                // 引导 1：没有辅助权限，跳转到系统设置 -> 隐私 -> 辅助功能
                let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
                
                // 顺便触发一次系统弹窗（如果用户之前从未被弹过的话）
                let promptOptions = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                AXIsProcessTrustedWithOptions(promptOptions)
                
            } else if !isScreenTrusted {
                // 引导 2：有辅助权限但没有录屏权限，跳转到系统设置 -> 隐私 -> 屏幕录制
                let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
                if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
                
                // 触发录屏请求系统弹窗
                CGRequestScreenCaptureAccess()
            } else {
                self.log("✅ 所有必要权限均已授权！")
            }
        }
    }
    
    func createNewWorkflow() { let newWF = Workflow(name: "新建流程 \(workflows.count + 1)"); workflows.append(newWF); selectedWorkflowId = newWF.id }
    func deleteWorkflow(at offsets: IndexSet) { workflows.remove(atOffsets: offsets); if let selectedId = selectedWorkflowId, !workflows.contains(where: { $0.id == selectedId }) { selectedWorkflowId = workflows.first?.id } }
    func deleteWorkflow(id: UUID) { if let idx = workflows.firstIndex(where: { $0.id == id }) { workflows.remove(at: idx) }; if selectedWorkflowId == id { selectedWorkflowId = workflows.first?.id } }
    func moveWorkflow(from source: IndexSet, to destination: Int) { workflows.move(fromOffsets: source, toOffset: destination) }
    // 1. 处理：同文件夹内的原生排序
    func moveWorkflowWithinFolder(folder: String, source: IndexSet, destination: Int) {
        var localList = workflows.filter { $0.folderName == folder }
        localList.move(fromOffsets: source, toOffset: destination)
        rebuildWorkflows(activeFolder: folder, newActiveFolderList: localList)
    }
    
    // 2. 处理：跨文件夹的精准插入 (带蓝色指示线)
    func insertWorkflow(id: UUID, into folder: String, at localIndex: Int) {
        guard let wIndex = workflows.firstIndex(where: { $0.id == id }) else { return }
        var movedItem = workflows[wIndex]
        movedItem.folderName = folder // 更新归属文件夹
        
        var localList = workflows.filter { $0.folderName == folder && $0.id != id }
        let safeIndex = min(max(0, localIndex), localList.count)
        localList.insert(movedItem, at: safeIndex)
        
        rebuildWorkflows(activeFolder: folder, newActiveFolderList: localList)
    }
    
    // 3. 处理：通过菜单移动，或拖拽到空文件夹 Header 上
    func moveWorkflow(id: UUID, toFolder targetFolder: String) {
        guard let wIndex = workflows.firstIndex(where: { $0.id == id }) else { return }
        guard workflows[wIndex].folderName != targetFolder else { return }
        
        var movedItem = workflows[wIndex]
        movedItem.folderName = targetFolder
        
        var localList = workflows.filter { $0.folderName == targetFolder }
        localList.append(movedItem) // 默认放到末尾
        
        rebuildWorkflows(activeFolder: targetFolder, newActiveFolderList: localList)
    }
    
    // 🛡️ 核心防闪烁机制：静默重组数组，不触发大面积的 View 销毁
    private func rebuildWorkflows(activeFolder: String, newActiveFolderList: [Workflow]) {
        var finalList = [Workflow]()
        let movedIds = Set(newActiveFolderList.map { $0.id })
        
        for f in folders {
            if f == activeFolder {
                finalList.append(contentsOf: newActiveFolderList)
            } else {
                // 将不属于当前操作文件夹，且没有被移动过的老数据按原样拼回
                let items = workflows.filter { $0.folderName == f && !movedIds.contains($0.id) }
                finalList.append(contentsOf: items)
            }
        }
        
        // 注意：这里绝对不能包裹 withAnimation，否则会与 List 原生的拖拽动画冲突导致严重闪烁
        self.workflows = finalList
        saveChanges()
    }

    func addAction(_ type: ActionType) {
        guard let idx = currentWorkflowIndex else { return }
        var param = ""
        if type == .aiVision { param = "提取屏幕上的主要内容：" }
        if type == .condition { param = "{{clipboard}}|contains|成功" }
        if type == .showNotification { param = "banner|RPA 提醒|我是消息内容" }
        if type == .setVariable { param = "myVar|测试数据" }
        if type == .httpRequest { param = "https://api.github.com|GET" }
        if type == .uiInteraction { param = "Safari|||click" }
        if type == .webAgent { param = "在这里描述你需要它完成的任务...|InternalBrowser|true|" }
        if type == .openURL { param = "https://www.bing.com|InternalBrowser" }
        workflows[idx].actions.append(RPAAction(type: type, parameter: param, customName: ""))
    }
    
    // [✨修改] 解决坐标完美重叠导致“看起来只录制了一个组件”的致命问题
    private func addRecordedAction(_ action: RPAAction) {
        guard let idx = currentWorkflowIndex else { return }
        var newAction = action
        
        // 拿到当前画布最后一个节点
        let lastNode = workflows[idx].actions.last
        
        // 修复坐标获取逻辑：先读 nodePositions 字典，若无则读取实体 positionX/Y
        var lastPos = CGPoint(x: 300, y: 150)
        if let last = lastNode {
            let dictPos = nodePositions[last.id]
            lastPos = dictPos ?? (last.positionX != 0 ? CGPoint(x: last.positionX, y: last.positionY) : CGPoint(x: 300, y: 150))
        }
        
        // 计算新坐标：垂直排在最后一个节点的正下方 90px 处
        let newPos = lastNode != nil ? CGPoint(x: lastPos.x, y: lastPos.y + 90) : lastPos
        newAction.positionX = newPos.x
        newAction.positionY = newPos.y
        
        // 【关键】将节点加入工作流，并同步刷新 SwiftUI 的 nodePositions 坐标系缓存
        workflows[idx].actions.append(newAction)
        nodePositions[newAction.id] = newPos
        
        // 自动将上一个节点的尾巴连线到这个新节点的头部
        if let prevNode = lastNode {
            addConnection(source: prevNode.id, sourcePort: .bottom, target: newAction.id, targetPort: .top)
        }
        
        log("⏺️ 录制动作已自动编排: \(action.displayTitle)")
    }
    
    func removeAction(id: UUID) { guard let idx = currentWorkflowIndex else { return }; workflows[idx].actions.removeAll { $0.id == id }; workflows[idx].connections.removeAll { $0.startNodeID == id || $0.endNodeID == id } }
    func updateActionPosition(id: UUID, position: CGPoint) { guard let idx = currentWorkflowIndex else { return }; if let actionIdx = workflows[idx].actions.firstIndex(where: { $0.id == id }) { workflows[idx].actions[actionIdx].positionX = Double(position.x); workflows[idx].actions[actionIdx].positionY = Double(position.y) } }
    func addConnection(source: UUID, sourcePort: PortPosition, target: UUID, targetPort: PortPosition, condition: ConnectionCondition = .always) { guard let idx = currentWorkflowIndex else { return }; let newConn = WorkflowConnection(startNodeID: source, endNodeID: target, startPort: sourcePort, endPort: targetPort, condition: condition); if !workflows[idx].connections.contains(where: { $0.startNodeID == source && $0.endNodeID == target }) { workflows[idx].connections.append(newConn) } }
    
    // [✨修改] 移除 private，允许外部 Executor 调用
    func parseVariables(_ input: String) -> String {
        var result = input
        if result.contains("{{clipboard}}") {
            let clipText = NSPasteboard.general.string(forType: .string) ?? ""
            result = result.replacingOccurrences(of: "{{clipboard}}", with: clipText)
        }
        do {
            let regex = try NSRegularExpression(pattern: "\\{\\{(.*?)\\}\\}")
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                if let range = Range(match.range(at: 1), in: result) {
                    let varName = String(result[range])
                    if varName != "clipboard" {
                        let val = variables[varName] ?? ""
                        result.replaceSubrange(Range(match.range, in: result)!, with: val)
                    }
                }
            }
        } catch { log("❌ 变量解析失败: \(error)") }
        return result
    }
    
    // [✨修改] 支持传入自定义文案的倒计时
    @MainActor
    func showCountdownHUD(message: String = "按 Cmd+Opt+S 紧急取消") async {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 260), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating; panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = false; panel.center()
        let containerView = NSView(); containerView.wantsLayer = true; containerView.layer?.cornerRadius = 32; containerView.layer?.masksToBounds = true; containerView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.85).cgColor
        let numberLabel = NSTextField(labelWithString: "3"); numberLabel.font = .monospacedDigitSystemFont(ofSize: 110, weight: .bold); numberLabel.textColor = .white; numberLabel.alignment = .center; numberLabel.isEditable = false; numberLabel.isBordered = false; numberLabel.drawsBackground = false
        let shortcutLabel = NSTextField(labelWithString: message); shortcutLabel.font = .systemFont(ofSize: 14, weight: .bold); shortcutLabel.textColor = .systemYellow; shortcutLabel.alignment = .center; shortcutLabel.isEditable = false; shortcutLabel.isBordered = false; shortcutLabel.drawsBackground = false
        let stackView = NSStackView(views: [numberLabel, shortcutLabel]); stackView.orientation = .vertical; stackView.alignment = .centerX; stackView.spacing = 16; stackView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(stackView); NSLayoutConstraint.activate([stackView.centerXAnchor.constraint(equalTo: containerView.centerXAnchor), stackView.centerYAnchor.constraint(equalTo: containerView.centerYAnchor)])
        panel.contentView = containerView; panel.orderFront(nil)
        
        for i in (1...3).reversed() {
            if !isRunning && message == "按 Cmd+Opt+S 紧急取消" { break }
            numberLabel.stringValue = "\(i)"
            try? await Task.sleep(for: .seconds(1))
        }
        panel.close()
    }
    
    // MARK: - 工作流执行引擎 (支持子流程递归调用)
    
    /// 主流程执行入口 (由用户点击 UI 触发)
    func runCurrentWorkflow() async {
        guard let idx = currentWorkflowIndex, !isRunning else { return }
        let workflow = workflows[idx]
        guard !workflow.actions.isEmpty else { return }
        
        isRunning = true; logs.removeAll(); variables.removeAll()
        if !AXIsProcessTrusted() { log("❌ 致命错误：未获得辅助功能权限！"); isRunning = false; return }
        
        // [✨修复点4] 修正 HUD 的弹出逻辑
        await MainActor.run {
            // 如果允许最小化，则隐藏主窗口
            if AppSettings.shared.minimizeOnRun {
                if let mainWindow = NSApp.windows.first(where: { $0.className.contains("AppKitWindow") }) {
                    mainWindow.miniaturize(nil)
                }
            }
            // 无论是否最小化，监控悬浮面板都必须展示！
            ExecutionToolbarManager.shared.show(engine: self)
        }
        
        log("⏱️ 准备执行，倒计时 3 秒...")
        await showCountdownHUD()

        guard isRunning else {
            // 倒计时期间如果被紧急中止，也要收回工具栏
            //await MainActor.run { ExecutionToolbarManager.shared.hide() }
            return
        }
        
        log("🚀 开始执行工作流: \(workflow.name)")
        let allTargetIDs = Set(workflow.connections.map { $0.endNodeID })
        var startNodes = workflow.actions.filter { !allTargetIDs.contains($0.id) }
        if startNodes.isEmpty { if let firstAction = workflow.actions.first { startNodes = [firstAction]; log("⚠️ 未检测到明确起点，强制从第一节点发起。") } else { isRunning = false; await MainActor.run { ExecutionToolbarManager.shared.hide() }; return; } }
        
        var executionQueue: [UUID] = startNodes.map { $0.id }
        while !executionQueue.isEmpty && isRunning {
            let actionID = executionQueue.removeFirst()
            guard let action = workflow.actions.first(where: { $0.id == actionID }) else { continue }
            
            // 跳过执行，直接传导连线
            if action.isDisabled {
                log("⏭️ 节点被禁用，直接跳过: [\(action.displayTitle)]")
                let nextConnections = workflow.connections.filter { $0.startNodeID == actionID }
                for conn in nextConnections { executionQueue.append(conn.endNodeID) }
                continue
            }
            
            currentActionId = action.id
            log("▶️ 执行: [\(action.displayTitle)]")
            
            let executor = ActionExecutorFactory.getExecutor(for: action.type)
            let executeResult = await executor.execute(action: action, context: self)
            
            try? await Task.sleep(for: .milliseconds(50))
            
            let nextConnections = workflow.connections.filter { $0.startNodeID == actionID && ($0.condition == .always || $0.condition == executeResult) }
            for conn in nextConnections { executionQueue.append(conn.endNodeID) }
        }
        if isRunning { log("✅ 所有流程执行完成！") }
        currentActionId = nil; isRunning = false
        
        // [✨修改] 执行结束或中途被中止时，回收悬浮面板
        await MainActor.run {
            //ExecutionToolbarManager.shared.hide()
        }
    }
    
    /// 独立工作流执行方法 (供主流程和子流程调度器调用)
    func runWorkflow(by id: UUID) async -> Bool {
        guard let workflow = workflows.first(where: { $0.id == id }) else {
            log("❌ 找不到 ID 为 \(id) 的工作流")
            return false
        }
        
        guard !workflow.actions.isEmpty else {
            log("⚠️ 工作流 [\(workflow.name)] 是空的，跳过。")
            return true
        }
        
        log("🚀 开始执行工作流: [\(workflow.name)]")
        let allTargetIDs = Set(workflow.connections.map { $0.endNodeID })
        var startNodes = workflow.actions.filter { !allTargetIDs.contains($0.id) }
        
        if startNodes.isEmpty {
            if let firstAction = workflow.actions.first {
                startNodes = [firstAction]
                log("⚠️ 未检测到明确起点，强制从第一节点发起。")
            } else { return false }
        }
        
        var executionQueue: [UUID] = startNodes.map { $0.id }
        
        while !executionQueue.isEmpty && isRunning {
            let actionID = executionQueue.removeFirst()
            guard let action = workflow.actions.first(where: { $0.id == actionID }) else { continue }
            
            // [✨修改] 子流程同样需要支持节点禁用跳过
            if action.isDisabled {
                log("⏭️ 节点被禁用，直接跳过: [\(action.displayTitle)]")
                let nextConnections = workflow.connections.filter { $0.startNodeID == actionID }
                for conn in nextConnections { executionQueue.append(conn.endNodeID) }
                continue
            }
            
            currentActionId = action.id
            log("▶️ 执行: [\(action.displayTitle)]")
            
            let executor = ActionExecutorFactory.getExecutor(for: action.type)
            let executeResult = await executor.execute(action: action, context: self)
            
            try? await Task.sleep(for: .milliseconds(50))
            
            let nextConnections = workflow.connections.filter {
                $0.startNodeID == actionID && ($0.condition == .always || $0.condition == executeResult)
            }
            for conn in nextConnections { executionQueue.append(conn.endNodeID) }
        }
        return isRunning
    }
    
    // MARK: - 基础底层能力（已向外部开放）
    
    // [✨终极提升] 图像预处理增强，解决低对比度和深色模式识别难问题
    private func enhanceImageForOCR(cgImage: CGImage) -> CGImage {
        let ciImage = CIImage(cgImage: cgImage)
        let context = CIContext(options: nil)
        
        // 1. 去色 (黑白化)
        guard let noirFilter = CIFilter(name: "CIPhotoEffectNoir") else { return cgImage }
        noirFilter.setValue(ciImage, forKey: kCIInputImageKey)
        
        // 2. 极致对比度拉升
        guard let colorControls = CIFilter(name: "CIColorControls") else { return cgImage }
        colorControls.setValue(noirFilter.outputImage, forKey: kCIInputImageKey)
        colorControls.setValue(2.0, forKey: kCIInputContrastKey) // 拉高对比度
        
        if let output = colorControls.outputImage,
           let resultCG = context.createCGImage(output, from: output.extent) {
            return resultCG
        }
        return cgImage
    }
    
    // [✨终极升级] 增加 fuzzy 模式与容错距离
    func findTextOnScreen(text: String, sampleBase64: String, region: CGRect?, appName: String? = nil, windowTitle: String? = nil, matchMode: String = "contains", targetIndex: Int = -1, fuzzyTolerance: Int = 0, enhanceContrast: Bool = false) async -> (point: CGPoint, text: String)? {
            
        guard let fullCGImage = try? await ScreenCaptureUtility.captureScreen(forAppName: appName, targetWindowTitle: windowTitle) else { return nil }
            
            let bounds = CGDisplayBounds(CGMainDisplayID())
            var targetCGImage = fullCGImage; var cropOffset = CGPoint.zero; var cropSize = bounds.size
            
            if let r = region {
                let safeRect = r.intersection(bounds)
                if !safeRect.isNull, let cropped = fullCGImage.cropping(to: safeRect) {
                    targetCGImage = cropped; cropOffset = safeRect.origin; cropSize = safeRect.size
                }
            }
            
            // [✨终极提升] 根据配置应用预处理
            let finalImageToScan = enhanceContrast ? enhanceImageForOCR(cgImage: targetCGImage) : targetCGImage
            
            return await withCheckedContinuation { continuation in
                let request = VNRecognizeTextRequest { [weak self] (req, err) in
                guard let self = self, let obs = req.results as? [VNRecognizedTextObservation] else { continuation.resume(returning: nil); return }
                
                // 1. 根据匹配模式过滤
                let matches = obs.filter { observation in
                    let candidateText = observation.topCandidates(1).first?.string ?? ""
                    
                    if matchMode == "exact" {
                        return candidateText == text
                    } else if matchMode == "regex" {
                        return candidateText.range(of: text, options: [.regularExpression, .caseInsensitive]) != nil
                    } else if matchMode == "fuzzy" {
                        // [✨新增] 模糊容错匹配：只要候选词中有一段连续的子串与目标词的编辑距离小于等于容错值
                        // 简单处理：判断整个候选词与目标词的距离，或目标词在候选词中近似存在
                        if candidateText.contains(text) { return true }
                        if candidateText.count >= text.count / 2 {
                            let distance = candidateText.editDistance(to: text)
                            return distance <= fuzzyTolerance
                        }
                        return false
                    } else {
                        return candidateText.localizedCaseInsensitiveContains(text)
                    }
                }
                
                if matches.isEmpty { continuation.resume(returning: nil); return }
                
                let getScreenPoint = { (match: VNRecognizedTextObservation) -> CGPoint in
                    let localX = match.boundingBox.midX * cropSize.width
                    let localY = (1.0 - match.boundingBox.midY) * cropSize.height
                    return CGPoint(x: cropOffset.x + localX, y: cropOffset.y + localY)
                }
                
                if targetIndex >= 0 && targetIndex < matches.count {
                    let match = matches[targetIndex]
                    continuation.resume(returning: (getScreenPoint(match), match.topCandidates(1).first?.string ?? ""))
                    return
                }
                
                if matches.count == 1 || sampleBase64.isEmpty {
                    continuation.resume(returning: (getScreenPoint(matches.first!), matches.first!.topCandidates(1).first?.string ?? ""))
                    return
                }
                
                if let sampleData = Data(base64Encoded: sampleBase64),
                   let sampleNSImage = NSImage(data: sampleData),
                   let sampleCG = sampleNSImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    var minDistance: Float = .infinity; var bestMatch = matches.first!
                    for match in matches {
                        let rect = VNImageRectForNormalizedRect(match.boundingBox, Int(targetCGImage.width), Int(targetCGImage.height))
                        if let cropped = targetCGImage.cropping(to: rect),
                           let dist = try? self.computeImageDistance(img1: sampleCG, img2: cropped), dist < minDistance {
                            minDistance = dist; bestMatch = match
                        }
                    }
                    continuation.resume(returning: (getScreenPoint(bestMatch), bestMatch.topCandidates(1).first?.string ?? ""))
                } else {
                    continuation.resume(returning: (getScreenPoint(matches.first!), matches.first!.topCandidates(1).first?.string ?? ""))
                }
            }
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            request.usesLanguageCorrection = true
            try? VNImageRequestHandler(cgImage: targetCGImage, options: [:]).perform([request])
        }
    }
    
    func computeImageDistance(img1: CGImage, img2: CGImage) throws -> Float {
        let req1 = VNGenerateImageFeaturePrintRequest(); let req2 = VNGenerateImageFeaturePrintRequest()
        try VNImageRequestHandler(cgImage: img1, options: [:]).perform([req1]); try VNImageRequestHandler(cgImage: img2, options: [:]).perform([req2])
        guard let f1 = req1.results?.first as? VNFeaturePrintObservation, let f2 = req2.results?.first as? VNFeaturePrintObservation else { return .infinity }
        var dist: Float = 0; try f1.computeDistance(&dist, to: f2); return dist
    }
    
    func simulateDrag(from start: CGPoint, to end: CGPoint) async {
        let eventSource = CGEventSource(stateID: .hidSystemState); CGWarpMouseCursorPosition(start); try? await Task.sleep(for: .milliseconds(100))
        CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left)?.post(tap: .cghidEventTap)
        try? await Task.sleep(for: .milliseconds(100))
        let steps = 30
        for i in 1...steps {
            let progress = CGFloat(i) / CGFloat(steps); let easeProgress = 1.0 - pow(1.0 - progress, 3)
            let currentPoint = CGPoint(x: start.x + (end.x - start.x) * easeProgress, y: start.y + (end.y - start.y) * easeProgress)
            CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDragged, mouseCursorPosition: currentPoint, mouseButton: .left)?.post(tap: .cghidEventTap)
            try? await Task.sleep(for: .milliseconds(15))
        }
        try? await Task.sleep(for: .milliseconds(150))
        CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left)?.post(tap: .cghidEventTap)
    }
    
    // MARK: - [✨重构] 拟人化平滑鼠标引擎
    func simulateMouseOperation(type: String, at point: CGPoint) async {
        let eventSource = CGEventSource(stateID: .hidSystemState)
        let startPoint = CGEvent(source: nil)?.location ?? point
        
        // 1. 拟人化轨迹平滑移动 (利用 easeOutCubic 曲线)
        let distance = hypot(point.x - startPoint.x, point.y - startPoint.y)
        // 动态计算步数：距离越远，分的步数越多，上限 35 步
        let steps = max(5, min(35, Int(distance / 20.0)))
        
        for i in 1...steps {
            let progress = CGFloat(i) / CGFloat(steps)
            let easeProgress = 1.0 - pow(1.0 - progress, 3) // easeOut
            let currentPoint = CGPoint(
                x: startPoint.x + (point.x - startPoint.x) * easeProgress,
                y: startPoint.y + (point.y - startPoint.y) * easeProgress
            )
            CGEvent(mouseEventSource: eventSource, mouseType: .mouseMoved, mouseCursorPosition: currentPoint, mouseButton: .left)?.post(tap: .cghidEventTap)
            // 每次微小移动停顿 5~8 毫秒，呈现极其丝滑顺畅的物理动画
            try? await Task.sleep(nanoseconds: UInt64(Int.random(in: 5...8) * 1_000_000))
        }
        
        // 确保最终坐标精准锁定
        CGWarpMouseCursorPosition(point)
        if type == "move" { return }
        
        // 给目标元素一个响应悬停态的时间
        try? await Task.sleep(for: .milliseconds(50))
        
        var mdType: CGEventType = .leftMouseDown
        var muType: CGEventType = .leftMouseUp
        var button: CGMouseButton = .left
        var clickState: Int64 = 1
        
        if type == "rightClick" { mdType = .rightMouseDown; muType = .rightMouseUp; button = .right }
        else if type == "doubleClick" { clickState = 2 }
        
        if let md = CGEvent(mouseEventSource: eventSource, mouseType: mdType, mouseCursorPosition: point, mouseButton: button),
           let mu = CGEvent(mouseEventSource: eventSource, mouseType: muType, mouseCursorPosition: point, mouseButton: button) {
            
            md.setIntegerValueField(.mouseEventClickState, value: clickState)
            mu.setIntegerValueField(.mouseEventClickState, value: clickState)
            
            md.post(tap: .cghidEventTap)
            try? await Task.sleep(for: .milliseconds(Int.random(in: 40...70))) // 模拟真实按压时长
            mu.post(tap: .cghidEventTap)
            
            if clickState == 2 {
                try? await Task.sleep(for: .milliseconds(80))
                md.post(tap: .cghidEventTap)
                try? await Task.sleep(for: .milliseconds(50))
                mu.post(tap: .cghidEventTap)
            }
        }
    }

    // MARK: - [✨重构] 带有节拍器的键盘引擎
    func simulateKeyboardInput(input: String, speedMode: String = "normal") async {
        let eventSource = CGEventSource(stateID: .hidSystemState)
        var i = input.startIndex
        
        while i < input.endIndex {
            let remainder = String(input[i...])
            
            // 匹配组合宏 [CMD+A]
            if let matchRange = remainder.range(of: #"^\[(?:CMD|SHIFT|OPT|CTRL|\+)+(?:[a-zA-Z0-9]|UP|DOWN|LEFT|RIGHT|ENTER|TAB|SPACE|ESC|DEL|BACKSPACE|HOME|END|F\d{1,2})\]"#, options: [.regularExpression, .caseInsensitive]) {
                let comboStr = String(remainder[matchRange])
                await executeHotkey(comboStr, source: eventSource)
                i = input.index(i, offsetBy: comboStr.count)
                try? await Task.sleep(for: .milliseconds(100)) // 宏触发完固定缓冲一下
                continue
            }
            
            // 匹配单键宏 [ENTER]
            if let specialRange = remainder.range(of: #"^\[(ENTER|TAB|SPACE|ESC|UP|DOWN|LEFT|RIGHT|DEL|BACKSPACE|HOME|END|F\d{1,2})\]"#, options: [.regularExpression, .caseInsensitive]) {
                let specialStr = String(remainder[specialRange])
                if let key = checkSpecialKey(specialStr) {
                    postKeyEvent(key: key, source: eventSource)
                }
                i = input.index(i, offsetBy: specialStr.count)
                continue
            }
            
            // 普通字符敲击
            let char = input[i]
            postCharacterEvent(char, source: eventSource)
            
            // 🌟 核心：动态随机延时调度
            let delayMs: Int
            switch speedMode {
            case "fast":
                delayMs = Int.random(in: 1...5)    // 极速灌入，几乎无延迟
            case "human":
                // 拟人模式：普通的键入速度偏慢，且 5% 概率模拟人类停顿思考
                if Int.random(in: 1...100) > 95 {
                    delayMs = Int.random(in: 300...600)
                } else {
                    delayMs = Int.random(in: 60...120)
                }
            default: // normal
                delayMs = Int.random(in: 20...50)  // 机械平滑输入
            }
            
            if delayMs > 0 {
                try? await Task.sleep(for: .milliseconds(delayMs))
            }
            
            i = input.index(after: i)
        }
    }
    
    // [✨修复] 精准滚屏补偿与方向修正
    func simulateScroll(type: String, amount: Int) async {
        // 1. 修正方向：
        // macOS CGEvent 底层逻辑：正数(+)向上滚，负数(-)向下滚
        let directionMultiplier: Int32 = (type == "scrollDown") ? -1 : 1
        
        // 2. 修正幅度：
        // 弃用微弱的 .line 单位，改用 .pixel。
        // 设定 1 逻辑行 ≈ 40 像素，这样用户输入 5 行，实际滚动 200 像素，幅度肉眼可见且精确。
        let pixelsPerLine: Int32 = 40
        let totalPixels = Int32(amount) * pixelsPerLine * directionMultiplier
        
        // 3. 拟人化平滑滚动：
        // 如果一瞬间把几百像素滚完，很多网页的 Vue/React 懒加载监听器会反应不过来。
        // 我们将其切分为 5 步平滑发出，模拟人类手指滑动触控板的物理惯性。
        let steps: Int32 = 5
        let stepPixels = totalPixels / steps
        
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        
        for _ in 0..<steps {
            if let scrollEvent = CGEvent(
                scrollWheelEvent2Source: source,
                units: .pixel, // 🌟 核心：强制使用 pixel 替代 line，解决滚动幅度太小的问题
                wheelCount: 1,
                wheel1: stepPixels,
                wheel2: 0,
                wheel3: 0
            ) {
                scrollEvent.post(tap: .cghidEventTap)
            }
            // 每次滚动间隔 15 毫秒，呈现丝滑的滚动动画
            try? await Task.sleep(nanoseconds: 15_000_000)
        }
    }
    
    func postCharacterEvent(_ char: Character, source: CGEventSource?) {
        let utf16 = Array(String(char).utf16)
        if let eventDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) { eventDown.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16); eventDown.post(tap: .cghidEventTap) }
        if let eventUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) { eventUp.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16); eventUp.post(tap: .cghidEventTap) }
    }
    
    func executeHotkey(_ input: String, source: CGEventSource?) async {
        var flags: CGEventFlags = []
        let upper = input.uppercased()
        if upper.contains("CMD") { flags.insert(.maskCommand) }; if upper.contains("SHIFT") { flags.insert(.maskShift) }; if upper.contains("OPT") { flags.insert(.maskAlternate) }; if upper.contains("CTRL") { flags.insert(.maskControl) }
        let parts = upper.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).components(separatedBy: "+")
        guard let mainKey = parts.last else { return }
        var keyCode: UInt16? = nil
        let keyMap: [String: UInt16] = ["A":0x00,"B":0x0B,"C":0x08,"D":0x02,"E":0x0E,"F":0x03,"G":0x05,"H":0x04,"I":0x22,"J":0x26,"K":0x28,"L":0x25,"M":0x2E,"N":0x2D,"O":0x1F,"P":0x23,"Q":0x0C,"R":0x0F,"S":0x01,"T":0x11,"U":0x20,"V":0x09,"W":0x0D,"X":0x07,"Y":0x10,"Z":0x06,"0":0x1D,"1":0x12,"2":0x13,"3":0x14,"4":0x15,"5":0x17,"6":0x16,"7":0x1A,"8":0x1C,"9":0x19]
        if let code = keyMap[mainKey] { keyCode = code } else if let code = checkSpecialKey(mainKey) { keyCode = code }
        if let finalCode = keyCode {
            let kd = CGEvent(keyboardEventSource: source, virtualKey: finalCode, keyDown: true); let ku = CGEvent(keyboardEventSource: source, virtualKey: finalCode, keyDown: false)
            kd?.flags = flags; ku?.flags = flags; kd?.post(tap: .cghidEventTap); ku?.post(tap: .cghidEventTap)
        }
    }
    
    func checkSpecialKey(_ input: String) -> UInt16? {
        let keyStr = input.uppercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        switch keyStr { case "ENTER": return 0x24; case "TAB": return 0x30; case "SPACE": return 0x31; case "ESC": return 0x35; case "UP": return 126; case "DOWN": return 125; case "LEFT": return 123; case "RIGHT": return 124; case "DEL": return 117; case "BACKSPACE": return 51; case "HOME": return 115; case "END": return 119; case "F1": return 122; case "F2": return 120; case "F3": return 99; case "F4": return 118; case "F5": return 96; default: return nil }
    }
    
    func postKeyEvent(key: UInt16, source: CGEventSource?) { CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)?.post(tap: .cghidEventTap); CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)?.post(tap: .cghidEventTap) }
    
    func log(_ msg: String) { logs.append("[\(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium))] \(msg)") }
    
    // [✨修改] 真正的流式追加（打字机效果的核心）
    @MainActor
    func appendLogChunk(_ chunk: String) {
        if logs.isEmpty {
            logs.append(chunk)
        } else {
            // 直接追加在最后一条日志字符串的末尾，不覆盖、不截断
            logs[logs.count - 1] += chunk
        }
    }
    
    @MainActor
    func requestUserConfirmation(title: String, message: String) -> Bool {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message; alert.alertStyle = .warning
        alert.addButton(withTitle: "允许执行"); alert.addButton(withTitle: "阻断")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
    
    // MARK: - [✨新增] 唤醒并前置目标浏览器
    @MainActor
    func activateBrowser(_ browser: String) async {
        if browser == "InternalBrowser" {
            BrowserWindowController.showSharedWindow()
            if BrowserViewModel.shared.tabs.isEmpty {
                BrowserViewModel.shared.addNewTab()
            }
            try? await Task.sleep(for: .milliseconds(500))
            
        } else if browser == "Safari" || browser == "Google Chrome" {
            // [✨修改] 支持通用外部浏览器的唤醒机制
            let bundleId = browser == "Safari" ? "com.apple.Safari" : "com.google.Chrome"
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true // 强制激活
                try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
                
                // 给浏览器的冷启动或前置留出缓冲时间
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

// MARK: - 鼠标和键盘控制
class NativeInputManager {
    static let shared = NativeInputManager()
    
    /// 物理鼠标悬停：控制光标瞬间移动到屏幕指定绝对坐标
    func hover(at point: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        let moveEvent = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)
        moveEvent?.post(tap: .cghidEventTap)
    }
    
    /// 物理鼠标点击：包含完整的 移动 -> 停留激活Hover -> 按下 -> 抬起 闭环
    func click(at point: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        
        // 1. 移动光标
        let moveEvent = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)
        moveEvent?.post(tap: .cghidEventTap)
        
        // 2. 停顿 50ms (非常重要！给系统或前端框架一个响应 Hover 态的时间)
        usleep(50_000)
        
        // 3. 按下左键
        let mouseDown = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
        mouseDown?.post(tap: .cghidEventTap)
        
        usleep(20_000) // 模拟人类按压停留 20ms
        
        // 4. 抬起左键
        let mouseUp = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
        mouseUp?.post(tap: .cghidEventTap)
    }
    
    /// 物理键盘输入：调用系统事件进行真实按键模拟
    func typeText(_ text: String) {
        // 对双引号和斜杠进行转义，防止 AppleScript 解析失败
        let safeText = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "System Events"
            keystroke "\(safeText)"
            delay 0.1
            key code 36 -- 模拟敲击回车键 (Enter)
        end tell
        """
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&error)
        }
    }
}


//////////////////////////////////////////////////////////////////
// 功能说明：RPA 运行时悬浮监控面板 (HUD)
//////////////////////////////////////////////////////////////////

// MARK: - 悬浮窗管理器
@MainActor
class ExecutionToolbarManager {
    static let shared = ExecutionToolbarManager()
    private var panel: NSPanel?
    private var cachedMainWindow: NSWindow?
    
    func show(engine: WorkflowEngine) {
        if cachedMainWindow == nil {
            if let mw = NSApp.windows.first(where: { !($0 is NSPanel) && String(describing: type(of: $0)).contains("Window") }) {
                mw.isReleasedWhenClosed = false
                cachedMainWindow = mw
            }
        }
        
        if panel == nil {
            let p = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 126, height: 52), // 默认收缩尺寸
                styleMask: [.borderless, .nonactivatingPanel, .hudWindow],
                backing: .buffered, defer: false
            )
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.backgroundColor = .clear
            p.hasShadow = true
            p.isOpaque = false
            p.isMovableByWindowBackground = true
            p.becomesKeyOnlyIfNeeded = true
            p.contentView = NSHostingView(rootView: ExecutionToolbarView(engine: engine))
            
            if let frame = NSScreen.main?.visibleFrame {
                p.setFrameTopLeftPoint(NSPoint(x: frame.maxX - 260, y: frame.maxY - 60))
            } else { p.center() }
            panel = p
        }
        
        if let panel = panel, !panel.isVisible { panel.orderFront(nil) }
    }
    
    func hide() { panel?.orderOut(nil) }
    
    // [✨协程重构] 精简的两段式动画执行器，锚定物理右上角
    func updatePanelSizeAsync(to size: CGSize, duration: TimeInterval = 0.15) async {
        guard let panel = panel else { return }
        await withCheckedContinuation { continuation in
            var frame = panel.frame
            let (topY, rightX) = (frame.maxY, frame.maxX) // 锁定右上角
            frame.size = size
            frame.origin = CGPoint(x: rightX - size.width, y: topY - size.height)
            
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = duration
                context.allowsImplicitAnimation = true
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            }, completionHandler: { continuation.resume() })
        }
    }
    
    func restoreMainWindow() {
        let targetWindow = cachedMainWindow ?? NSApp.windows.first(where: { !($0 is NSPanel) && String(describing: type(of: $0)).contains("Window") })
        if let mw = targetWindow {
            if mw.isMiniaturized { mw.deminiaturize(nil) }
            mw.makeKeyAndOrderFront(nil)
        } else {
            let config = NSWorkspace.OpenConfiguration(); config.activates = true
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in }
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - SwiftUI 监控面板视图
struct ExecutionToolbarView: View {
    @Environment(\.openWindow) private var openWindow
    var engine: WorkflowEngine
    
    @State private var isExpanded: Bool = false
    @State private var showContent: Bool = false
    @State private var isAnimating: Bool = false
    
    private let expandedSize = CGSize(width: 340, height: 210)
    private let collapsedSize = CGSize(width: 126, height: 52)
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerView.frame(height: 24).padding(.bottom, showContent ? 10 : 0)
            
            if showContent {
                contentView.transition(.opacity.combined(with: .move(edge: .top)))
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .background(VisualEffectBackground().clipShape(RoundedRectangle(cornerRadius: 16)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.15), lineWidth: 1))
        .onChange(of: engine.isRunning) { _, isRunning in
            if isRunning && !isExpanded { toggleExpansion(targetExpanded: true) }
        }
    }
    
    // MARK: - 核心两段式动画调度
    private func toggleExpansion(targetExpanded: Bool) {
        guard !isAnimating, isExpanded != targetExpanded else { return }
        isAnimating = true
        
        Task { @MainActor in
            if !targetExpanded {
                withAnimation(.easeOut(duration: 0.15)) { showContent = false }
                try? await Task.sleep(nanoseconds: 150_000_000)
                
                await ExecutionToolbarManager.shared.updatePanelSizeAsync(to: CGSize(width: expandedSize.width, height: collapsedSize.height))
                await ExecutionToolbarManager.shared.updatePanelSizeAsync(to: collapsedSize)
                
                isExpanded = false; isAnimating = false
            } else {
                isExpanded = true
                await ExecutionToolbarManager.shared.updatePanelSizeAsync(to: CGSize(width: expandedSize.width, height: collapsedSize.height))
                await ExecutionToolbarManager.shared.updatePanelSizeAsync(to: expandedSize)
                
                withAnimation(.easeIn(duration: 0.2)) { showContent = true }
                isAnimating = false
            }
        }
    }
    
    // MARK: - 子组件抽取 (更简洁)
    private var headerView: some View {
        HStack(spacing: 8) {
            if showContent {
                ExecutionBreatheLight(isRunning: engine.isRunning)
                
                let wfName = engine.currentWorkflowIndex != nil ? engine.workflows[engine.currentWorkflowIndex!].name : "工作流执行监控"
                Text(wfName).font(.system(size: 13, weight: .bold)).foregroundColor(.primary.opacity(0.8)).lineLimit(1).transition(.opacity)
                
                // [✨修改] 更多菜单接入真实窗口路由
                Menu {
                    Button {
                        engine.log("🌐 唤起内置浏览器")
                        BrowserWindowController.showSharedWindow()
                    } label: { Label("内置浏览器", systemImage: "safari") }
                    
                    Button {
                        engine.log("📚 唤起语料库")
                        // TODO: 替换为你实际的语料库窗体调度器
                        openWindow(id: "corpus-manager")
                    } label: { Label("语料库管理", systemImage: "text.book.closed") }
                    
                    Button {
                        engine.log("🤖 唤起 WebAgent")
                        // TODO: 替换为你实际的 WebAgent 窗体调度器
                        openWindow(id: "agentMonitor")
                    } label: { Label("WebAgent 监控", systemImage: "network") }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 14, weight: .bold)).foregroundColor(.primary.opacity(0.7)).frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 24).transition(.opacity)

                Spacer(minLength: 0)
            }
                        
            // 按钮群组
            Group {
                // 启停控制
                Button(action: {
                    if engine.isRunning {
                        engine.isRunning = false
                    } else {
                        Task { await engine.runCurrentWorkflow() }
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: engine.isRunning ? "stop.circle.fill" : "play.circle.fill")
                        if showContent { Text(engine.isRunning ? "终止" : "运行").transition(.opacity) }
                    }
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(engine.isRunning ? Color.red.opacity(0.8) : Color.green.opacity(0.8))
                    .cornerRadius(12)
                }
                
                // 展开/收缩
                Button(action: { toggleExpansion(targetExpanded: !isExpanded) }) {
                    Image(systemName: isExpanded ? "arrow.up.right.and.arrow.down.left" : "arrow.down.left.and.arrow.up.right")
                        .font(.system(size: 12, weight: .bold)).foregroundColor(.primary.opacity(0.7)).frame(width: 24, height: 24)
                        .background(Color.primary.opacity(0.05)).clipShape(Circle())
                }
                
                // 关闭
                Button(action: { ExecutionToolbarManager.shared.hide(); ExecutionToolbarManager.shared.restoreMainWindow() }) {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundColor(.primary.opacity(0.7))
                        .frame(width: 24, height: 24).background(Color.primary.opacity(0.1)).clipShape(Circle())
                }.opacity(engine.isRunning ? 0.6 : 1.0)
            }
            .buttonStyle(.plain)
        }
    }
    
    private var contentView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().opacity(0.5)
            actionStatusView
            recentLogsView
        }
    }
    
    private var actionStatusView: some View {
        Group {
            if let id = engine.currentActionId, let idx = engine.currentWorkflowIndex, let action = engine.workflows[idx].actions.first(where: { $0.id == id }) {
                HStack(spacing: 8) {
                    Image(systemName: action.type.icon).font(.system(size: 14)).foregroundColor(.blue)
                    Text(action.customName.isEmpty ? action.displayTitle : action.customName).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Spacer()
                    ProgressView().controlSize(.small)
                }
                .padding(8).background(Color.blue.opacity(0.1)).cornerRadius(6).animation(.easeInOut, value: action.id)
            } else {
                HStack {
                    Image(systemName: "hourglass").foregroundColor(.gray)
                    Text(engine.isRunning ? "引擎就绪，等待节点..." : "执行已结束").font(.system(size: 13)).foregroundColor(engine.isRunning ? .gray : .green)
                    Spacer()
                }.padding(8).background(Color.gray.opacity(0.05)).cornerRadius(6)
            }
        }
    }
    
    private var recentLogsView: some View {
        VStack(alignment: .leading, spacing: 2) {
            let recentLogs = Array(engine.logs.suffix(5))
            if recentLogs.isEmpty {
                Text("暂无日志输出...").font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
            } else {
                ForEach(recentLogs.indices, id: \.self) { i in
                    Text(recentLogs[i]).font(.system(size: 11, design: .monospaced)).foregroundColor(recentLogs[i].contains("❌") ? .red : .secondary).lineLimit(1).truncationMode(.tail)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading).frame(height: 90, alignment: .top).padding(.top, 2)
    }
}

// MARK: - macOS 毛玻璃与特效件
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView(); view.material = .hudWindow; view.blendingMode = .behindWindow; view.state = .active; return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct ExecutionBreatheLight: View {
    var isRunning: Bool
    @State private var breathePhase: CGFloat = 0.0
    var body: some View {
        Circle().fill(Color.green).frame(width: 10, height: 10)
            .opacity(isRunning ? (0.4 + breathePhase * 0.6) : 0.2)
            .shadow(color: .green, radius: isRunning ? (2 + breathePhase * 3) : 0)
            .onAppear { withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { breathePhase = 1.0 } }
    }
}
