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
    
    init() {
        isLoading = true; workflows = StorageManager.shared.load(); selectedWorkflowId = workflows.first?.id; isLoading = false
        hasUnsavedChanges = false; checkPermissions(); setupHotkeys()
        // 初始化时加载文件夹
        if let savedFolders = UserDefaults.standard.stringArray(forKey: "RPA_Folders") {
            self.folders = savedFolders
        }
        if !self.folders.contains("默认文件夹") { self.folders.insert("默认文件夹", at: 0) }
        
        // 绑定录制器回调
        MacroRecorder.shared.onActionRecorded = { [weak self] action in self?.addRecordedAction(action) }
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
    
    deinit {
        if let monitor = globalKeyMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = localKeyMonitor { NSEvent.removeMonitor(monitor) }
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
    
    func addAction(_ type: ActionType) {
        guard let idx = currentWorkflowIndex else { return }
        var param = ""
        if type == .aiVision { param = "提取屏幕上的主要内容：" }
        if type == .condition { param = "{{clipboard}}|contains|成功" }
        if type == .showNotification { param = "banner|RPA 提醒|工作流执行到了这里" }
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
        
        // [✨修改] 如果设置允许，自动最小化主窗口，并呼出右上角悬浮工具栏
        if AppSettings.shared.minimizeOnRun {
            await MainActor.run {
                if let mainWindow = NSApp.windows.first(where: { $0.className.contains("AppKitWindow") }) {
                    mainWindow.miniaturize(nil)
                }
                // 呼出正在执行的悬浮监控面板
                ExecutionToolbarManager.shared.show(engine: self)
            }
        }
        
        log("⏱️ 准备执行，倒计时 3 秒...")
        await showCountdownHUD()

        guard isRunning else {
            // 倒计时期间如果被紧急中止，也要收回工具栏
            await MainActor.run { ExecutionToolbarManager.shared.hide() }
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
            ExecutionToolbarManager.shared.hide()
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
    func findTextOnScreen(text: String, sampleBase64: String, region: CGRect?, appName: String? = nil, matchMode: String = "contains", targetIndex: Int = -1, fuzzyTolerance: Int = 0, enhanceContrast: Bool = false) async -> (point: CGPoint, text: String)? {
            
            guard let fullCGImage = try? await ScreenCaptureUtility.captureScreen(forAppName: appName) else { return nil }
            
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
    
    func simulateMouseOperation(type: String, at point: CGPoint) async {
        CGWarpMouseCursorPosition(point); if type == "move" { return }
        try? await Task.sleep(for: .milliseconds(200)); let eventSource = CGEventSource(stateID: .hidSystemState)
        var mdType: CGEventType = .leftMouseDown; var muType: CGEventType = .leftMouseUp; var button: CGMouseButton = .left; var clickState: Int64 = 1
        if type == "rightClick" { mdType = .rightMouseDown; muType = .rightMouseUp; button = .right } else if type == "doubleClick" { clickState = 2 }
        if let md = CGEvent(mouseEventSource: eventSource, mouseType: mdType, mouseCursorPosition: point, mouseButton: button), let mu = CGEvent(mouseEventSource: eventSource, mouseType: muType, mouseCursorPosition: point, mouseButton: button) {
            md.setIntegerValueField(.mouseEventClickState, value: clickState); mu.setIntegerValueField(.mouseEventClickState, value: clickState)
            md.post(tap: .cghidEventTap); try? await Task.sleep(for: .milliseconds(50)); mu.post(tap: .cghidEventTap)
            if clickState == 2 { try? await Task.sleep(for: .milliseconds(80)); md.post(tap: .cghidEventTap); try? await Task.sleep(for: .milliseconds(50)); mu.post(tap: .cghidEventTap) }
        }
    }
    
    func simulateScroll(type: String, amount: Int) async {
        let isUp = (type == "scrollUp" || type == "cmdScrollUp"); let wheel1Value = isUp ? Int32(amount) : Int32(-amount)
        if let event = CGEvent(scrollWheelEvent2Source: CGEventSource(stateID: .hidSystemState), units: .line, wheelCount: 1, wheel1: wheel1Value, wheel2: 0, wheel3: 0) {
            if type.hasPrefix("cmd") { event.flags = .maskCommand }; event.post(tap: .cghidEventTap)
        }
    }
    
    func simulateKeyboardInput(input: String) async {
        let eventSource = CGEventSource(stateID: .hidSystemState); var i = input.startIndex
        while i < input.endIndex {
            let remainder = String(input[i...])
            if let matchRange = remainder.range(of: #"^\[(?:CMD|SHIFT|OPT|CTRL|\+)+(?:[a-zA-Z0-9]|UP|DOWN|LEFT|RIGHT|ENTER|TAB|SPACE|ESC|DEL|BACKSPACE|HOME|END|F\d{1,2})\]"#, options: [.regularExpression, .caseInsensitive]) {
                let comboStr = String(remainder[matchRange]); await executeHotkey(comboStr, source: eventSource); i = input.index(i, offsetBy: comboStr.count); continue
            }
            if let specialRange = remainder.range(of: #"^\[(ENTER|TAB|SPACE|ESC|UP|DOWN|LEFT|RIGHT|DEL|BACKSPACE|HOME|END|F\d{1,2})\]"#, options: [.regularExpression, .caseInsensitive]) {
                let specialStr = String(remainder[specialRange]); if let key = checkSpecialKey(specialStr) { postKeyEvent(key: key, source: eventSource) }; i = input.index(i, offsetBy: specialStr.count); continue
            }
            let char = input[i]; postCharacterEvent(char, source: eventSource); try? await Task.sleep(for: .milliseconds(Int.random(in: 30...80))); i = input.index(after: i)
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
    
    // MARK: - [✨3.0 双引擎底层支持] 内置 WKWebView & Safari 动态路由
        
    /// 统一的 JavaScript 执行路由
    @MainActor
    private func executeJS(browser: String, script: String) async throws -> String {
        if browser == "InternalBrowser" {
            // 路由 A：原生 WKWebView 极速执行
            guard let tab = BrowserViewModel.shared.activeTab else {
                throw NSError(domain: "RPA", code: 404, userInfo: [NSLocalizedDescriptionKey: "内置浏览器未打开或无活跃标签页"])
            }
            return try await tab.evaluateJSAsync(script)
        } else {
            // 路由 B：Safari AppleScript 桥接执行
            // 完美转义 JS 字符串以适应 AppleScript 的双引号环境
            let escapedScript = script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let appleScript = """
            tell application "Safari"
                if not (exists document 1) then return "Error: No document open"
                do JavaScript "\(escapedScript)" in front document
            end tell
            """
            var errorInfo: NSDictionary?
            if let scriptObj = NSAppleScript(source: appleScript) {
                let output = scriptObj.executeAndReturnError(&errorInfo)
                if errorInfo == nil { return output.stringValue ?? "" }
            }
            throw NSError(domain: "RPA", code: 500, userInfo: [NSLocalizedDescriptionKey: "Safari 脚本执行失败"])
        }
    }
    
    // MARK: - [✨3.0 终极版] 穿透 Iframe/ShadowDOM + Set-of-Mark 坐标锚点绘制
    @MainActor
    func injectSoMAndGetDOM(browser: String) async -> String {
        let script = """
        (function() {
            document.querySelectorAll('.rpa-som').forEach(e => e.remove());
            let summary = [];
            let index = 0;
            
            // [✨ 深度获取] 递归遍历 DOM, ShadowDOM, 以及 Iframe，并携带坐标偏移量
            function getAllElements(root, offsetX = 0, offsetY = 0) {
                let elements = [];
                let walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT, null, false);
                let node;
                
                while (node = walker.nextNode()) {
                    // 记录元素的绝对坐标偏移
                    node._rpaOffsetX = offsetX;
                    node._rpaOffsetY = offsetY;
                    elements.push(node);
                    
                    // 1. 穿透 Shadow DOM
                    if (node.shadowRoot) {
                        elements = elements.concat(getAllElements(node.shadowRoot, offsetX, offsetY));
                    }
                    
                    // 2. 穿透 同源 Iframe
                    if (node.tagName.toLowerCase() === 'iframe') {
                        try {
                            let iframeDoc = node.contentDocument || node.contentWindow.document;
                            if (iframeDoc) {
                                let rect = node.getBoundingClientRect();
                                // 累加 iframe 在父级窗口中的坐标
                                elements = elements.concat(getAllElements(iframeDoc.body, offsetX + rect.left, offsetY + rect.top));
                            }
                        } catch(e) {
                            // 跨域 iframe 会触发 DOMException，此处静默忽略
                        }
                    }
                }
                return elements;
            }
            
            let allNodes = getAllElements(document.body);
            let interactiveTags = ['button', 'input', 'a', 'select', 'textarea'];
            
            let elements = allNodes.filter(el => {
                let tag = el.tagName.toLowerCase();
                let role = el.getAttribute('role');
                let style = window.getComputedStyle(el);
                let className = (el.className && typeof el.className === 'string') ? el.className.toLowerCase() : '';
                
                // [✨ 增强的感知雷达] 增加指针样式、事件、类名、多角色识别
                return interactiveTags.includes(tag) || 
                       ['button', 'link', 'tab', 'menuitem', 'switch', 'checkbox'].includes(role) || 
                       el.hasAttribute('tabindex') || 
                       el.hasAttribute('onclick') || 
                       style.cursor === 'pointer' || 
                       className.includes('btn') || 
                       className.includes('button');
            });
            
            for(let i=0; i<elements.length; i++) {
                let el = elements[i];
                let rect = el.getBoundingClientRect();
                let style = window.getComputedStyle(el);
                
                // 排除不可见、被隐藏(aria-hidden)的元素
                if(rect.width > 5 && rect.height > 5 && 
                   style.display !== 'none' && style.visibility !== 'hidden' && style.opacity !== '0' &&
                   el.getAttribute('aria-hidden') !== 'true') {
                    
                    // 叠加由 iframe 传导下来的坐标偏移
                    let finalLeft = rect.left + window.scrollX + (el._rpaOffsetX || 0);
                    let finalTop = rect.top + window.scrollY + (el._rpaOffsetY || 0);
                    
                    // [✨ 新增] 计算绝对中心坐标
                    let centerX = Math.round(finalLeft + rect.width / 2);
                    let centerY = Math.round(finalTop + rect.height / 2);
                    
                    el.setAttribute('data-rpa-id', index.toString());
                    
                    // ==========================================
                    // 1. 绘制主体高亮边框
                    // ==========================================
                    let marker = document.createElement('div');
                    marker.className = 'rpa-som';
                    marker.style.position = 'absolute';
                    marker.style.left = finalLeft + 'px';
                    marker.style.top = finalTop + 'px';
                    marker.style.width = rect.width + 'px';
                    marker.style.height = rect.height + 'px';
                    marker.style.border = '2px solid rgba(255, 0, 0, 0.6)';
                    marker.style.boxSizing = 'border-box';
                    marker.style.zIndex = '2147483647';
                    marker.style.pointerEvents = 'none'; 
                    
                    // 左上角数字 ID 标签
                    let label = document.createElement('div');
                    label.innerText = index;
                    label.style.position = 'absolute';
                    label.style.top = '-16px'; label.style.left = '-2px';
                    label.style.background = 'rgba(255,0,0,0.9)'; label.style.color = 'white';
                    label.style.padding = '1px 5px'; label.style.fontSize = '12px'; label.style.fontWeight = 'bold';
                    label.style.borderRadius = '3px';
                    label.style.boxShadow = '0 1px 3px rgba(0,0,0,0.3)';
                    marker.appendChild(label);
                    
                    // ==========================================
                    // 2. [✨ 融合] 绘制中心坐标圆点 (瞄准点)
                    // ==========================================
                    let centerDot = document.createElement('div');
                    centerDot.style.position = 'absolute';
                    centerDot.style.left = 'calc(50% - 3px)';
                    centerDot.style.top = 'calc(50% - 3px)';
                    centerDot.style.width = '6px';
                    centerDot.style.height = '6px';
                    centerDot.style.background = 'blue';
                    centerDot.style.borderRadius = '50%';
                    centerDot.style.boxShadow = '0 0 2px white';
                    marker.appendChild(centerDot);
                    
                    // ==========================================
                    // 3. [✨ 融合] 绘制右下角坐标文本 (供大模型读取)
                    // ==========================================
                    let coordLabel = document.createElement('div');
                    coordLabel.innerText = '(' + centerX + ', ' + centerY + ')';
                    coordLabel.style.position = 'absolute';
                    coordLabel.style.bottom = '-12px'; 
                    coordLabel.style.right = '-2px';
                    coordLabel.style.background = 'rgba(0, 0, 255, 0.8)'; 
                    coordLabel.style.color = 'white';
                    coordLabel.style.padding = '1px 3px'; 
                    coordLabel.style.fontSize = '9px';
                    coordLabel.style.fontFamily = 'monospace';
                    coordLabel.style.borderRadius = '2px';
                    marker.appendChild(coordLabel);

                    document.body.appendChild(marker);
                    
                    // ==========================================
                    // 4. [✨ 融合] 提取携带状态和坐标的 DOM 上下文
                    // ==========================================
                    let text = el.innerText || el.value || el.placeholder || el.getAttribute('aria-label') || '';
                    let state = el.disabled ? " [Disabled]" : "";
                    let isChecked = el.checked ? " [Checked]" : "";
                    let typeInfo = el.type ? `(${el.type})` : "";
                    let cleanText = text.trim().replace(/\\n/g, ' ').substring(0, 40);
                    
                    summary.push(`[${index}] ${el.tagName.toLowerCase()}${typeInfo} | Coord: (${centerX}, ${centerY}) | Text: ${cleanText}${state}${isChecked}`);
                    index++;
                }
            }
            return summary.join('\\n');
        })();
        """
        do {
            return try await executeJS(browser: browser, script: script)
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }
    
    @MainActor
    func cleanupSoM(browser: String) async {
        let script = "document.querySelectorAll('.rpa-som').forEach(e => e.remove());"
        _ = try? await executeJS(browser: browser, script: script)
    }
    
    @MainActor
    func waitForPageToStabilize(browser: String) async {
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(500))
            if let state = try? await executeJS(browser: browser, script: "document.readyState"), state == "complete" {
                break
            }
        }
    }
    
    // [✨修改] 返回生成的脚本和执行的真实结果，而不是内部消化掉
    @MainActor
    func injectActionJS(browser: String, action: String, targetId: String, value: String) async -> (script: String, result: String) {
        var jsCommand = ""
        if action == "scroll_down" {
            jsCommand = "(function() {window.scrollBy({top: window.innerHeight * 0.8, behavior: 'smooth'}); return 'Scrolled Down';})();"
        }
        else if action == "scroll_up" {
            jsCommand = "(function() {window.scrollBy({top: -window.innerHeight * 0.8, behavior: 'smooth'}); return 'Scrolled Up';})();"
        }
        else if action == "hover" {
            jsCommand = """
            (function() {
                let el = document.querySelector('[data-rpa-id="\(targetId)"]');
                if (!el) return 'Element Not Found';
                let eventParams = { bubbles: true, cancelable: true, view: window };
                el.dispatchEvent(new MouseEvent('mouseover', eventParams));
                el.dispatchEvent(new MouseEvent('mouseenter', eventParams));
                el.dispatchEvent(new MouseEvent('mousemove', eventParams));
                return 'Hover Triggered';
            })();
            """
        }
        else if action == "click" {
            jsCommand = """
            (function() {
                let el = document.querySelector('[data-rpa-id="\(targetId)"]'); 
                if(!el) return 'Element Not Found';
                el.focus(); 
                el.click();
                return 'Clicked';
            })();
            """
        }
        else if action == "input" {
            let safeValue = value.replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "")
            jsCommand = """
            (function() {
                let el = document.querySelector('[data-rpa-id="\(targetId)"]');
                if (!el) return 'Element Not Found';
                
                el.focus();
                
                let nativeSetter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value')?.set;
                if (el.tagName.toLowerCase() === 'textarea') {
                    nativeSetter = Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value')?.set;
                }
                
                if (nativeSetter) {
                    nativeSetter.call(el, "\(safeValue)");
                } else {
                    el.value = "\(safeValue)";
                }
                
                el.dispatchEvent(new Event('input', { bubbles: true }));
                el.dispatchEvent(new Event('change', { bubbles: true }));
                el.dispatchEvent(new KeyboardEvent('keydown', { bubbles: true, key: 'Enter', code: 'Enter' }));
                el.dispatchEvent(new KeyboardEvent('keyup', { bubbles: true, key: 'Enter', code: 'Enter' }));
                el.blur();
                return 'Input Injected: \(safeValue)';
            })();
            """
        }
        
        do {
            let res = try await executeJS(browser: browser, script: jsCommand)
            return (jsCommand, res)
        } catch {
            return (jsCommand, "执行抛出异常: \(error.localizedDescription)")
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
            // 召唤我们自己开发的内置开发者浏览器
            BrowserWindowController.showSharedWindow()
            
            // 容错处理：如果浏览器打开了，但是里面一个 Tab 都没有，主动新建一个
            if BrowserViewModel.shared.tabs.isEmpty {
                BrowserViewModel.shared.addNewTab()
            }
            
            // 给 UI 渲染和界面弹出留出极短的缓冲时间
            try? await Task.sleep(for: .milliseconds(500))
            
        } else if browser == "Safari" {
            // 使用 macOS 底层 API 唤醒 Safari 并强制将其拉到前台
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true // 强制激活
                try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
                
                // 给 Safari 的冷启动或前置留出缓冲时间
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
    
    // MARK: - WebAgent 辅助：获取页面可见文本用于断言
    @MainActor
    func getPageText(browser: String) async -> String {
        // 使用 innerText 可以过滤掉隐藏元素，完美模拟用户的“视觉可见文本”
        let script = "document.body.innerText"
        return (try? await executeJS(browser: browser, script: script)) ?? ""
    }
    
    // MARK: - [✨ 原生引擎桥梁] 获取元素在屏幕上的物理绝对坐标
    @MainActor
    func getElementScreenCoordinates(browser: String, targetId: String) async -> CGPoint? {
        let script = """
        (function() {
            let el = document.querySelector('[data-rpa-id="\(targetId)"]');
            if (!el) return null;
            let rect = el.getBoundingClientRect();
            
            // 计算浏览器 UI 栏(如顶部的地址栏、书签栏)的高度补偿
            let toolbarHeight = window.outerHeight - window.innerHeight;
            let sidebarWidth = window.outerWidth - window.innerWidth;
            
            // 换算为操作系统的全局绝对坐标 (获取元素的中心点)
            let screenX = window.screenX + (sidebarWidth > 0 ? sidebarWidth / 2 : 0) + rect.left + (rect.width / 2);
            let screenY = window.screenY + toolbarHeight + rect.top + (rect.height / 2);
            
            return screenX + "," + screenY;
        })();
        """
        
        if let result = try? await executeJS(browser: browser, script: script),
           let coords = result as? String, coords.contains(",") {
            let parts = coords.split(separator: ",")
            if parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) {
                return CGPoint(x: x, y: y)
            }
        }
        return nil
    }
    
    // MARK: - [✨ 原生引擎桥梁] 执行物理动作
    @MainActor
    func executeNativeAction(browser: String, action: String, targetId: String, value: String) async -> Bool {
        // 1. 获取物理坐标
        guard let point = await getElementScreenCoordinates(browser: browser, targetId: targetId) else {
            return false
        }
        
        // 2. 根据动作指令调用物理外设
        if action == "native_hover" {
            NativeInputManager.shared.hover(at: point)
        } else if action == "native_click" {
            NativeInputManager.shared.click(at: point)
        } else if action == "native_input" {
            // 输入动作：物理鼠标先点过去激活光标，然后再进行物理键盘敲击
            NativeInputManager.shared.click(at: point)
            try? await Task.sleep(nanoseconds: 300_000_000) // 等待0.3秒聚焦和动画完成
            NativeInputManager.shared.typeText(value)
        }
        return true
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
