//////////////////////////////////////////////////////////////////
// 文件名：ActionExecutors.swift
// 文件说明：RPA动作执行器集合，采用策略模式解耦执行逻辑
// 功能说明：存放所有的 RPA 节点具体执行逻辑。
// 代码要求：没有要求修改不用输出代码，请保证代码的逻辑和完整性，保留代码中的所有注释内容
//////////////////////////////////////////////////////////////////

import Foundation
import AppKit
import Vision
import Combine

// MARK: - [稳定性基建] 节点智能重试装饰器机制
extension RPAActionExecutor {
    /// 带有自动重试机制的执行包装器
    /// - Parameters:
    ///   - action: 当前执行的动作
    ///   - context: 引擎上下文
    ///   - maxRetries: 最大重试次数 (默认 3 次)
    ///   - baseDelay: 基础延迟秒数 (每次重试时间会递增)
    /// - Returns: 最终的执行状态
    func executeWithRetry(action: RPAAction, context: WorkflowEngine, maxRetries: Int = 3, baseDelay: Double = 2.0) async -> ConnectionCondition {
        var attempt = 1
        
        while attempt <= maxRetries {
            // 真正调用节点本身的 execute
            let result = await self.execute(action: action, context: context)
            
            if result == .success || result == .always {
                if attempt > 1 {
                    context.log("⚠️ 第 \\(attempt) 次重试成功。")
                }
                return result
            }
            
            if attempt < maxRetries {
                // 指数退避等待 (2s, 4s, 8s...)
                let delay = baseDelay * pow(2.0, Double(attempt - 1))
                context.log("⏳ 节点执行失败，准备第 \\(attempt + 1) 次重试 (等待 \\(String(format: \"%.1f\", delay)) 秒)...")
                
                // 异步休眠，不阻塞主线程
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                attempt += 1
            } else {
                context.log("❌ 节点已达到最大重试次数 (\\(maxRetries)次)，宣告失败。")
                break
            }
        }
        
        return .failure
    }
}

// MARK: - 执行器基础协议
/// 定义了所有 RPA 组件执行器必须遵循的基础协议
protocol RPAActionExecutor {
    /// 执行具体的 Action
    /// - Parameters:
    ///   - action: 当前动作配置
    ///   - context: 引擎上下文（用于读写变量、调用基础能力等）
    /// - Returns: 执行后的分支条件
    func execute(action: RPAAction, context: WorkflowEngine) async -> ConnectionCondition
}

// MARK: - 执行器工厂
/// 负责根据节点的类型生成并返回对应的独立执行器对象
struct ActionExecutorFactory {
    static func getExecutor(for type: ActionType) -> RPAActionExecutor {
        switch type {
        case .webAgent:         return WebAgentExecutor()
        case .uiInteraction:    return UIInteractionExecutor()
        case .setVariable:      return SetVariableExecutor()
        case .httpRequest:      return HTTPRequestExecutor()
        case .aiVision:         return AIVisionExecutor()
        case .openApp:          return OpenAppExecutor()
        case .openURL:          return OpenURLExecutor()
        case .typeText:         return TypeTextExecutor()
        case .wait:             return WaitExecutor()
        case .askUserInput:     return AskUserInputExecutor()
        case .condition:        return ConditionExecutor()
        case .showNotification: return ShowNotificationExecutor()
        case .ocrText:          return OCRTextExecutor()
        case .mouseOperation:   return MouseOperationExecutor()
        case .writeClipboard:   return WriteClipboardExecutor()
        case .readClipboard:    return ReadClipboardExecutor()
        case .runShell:         return RunShellExecutor()
        case .runAppleScript:   return RunAppleScriptExecutor()
        case .callWorkflow:     return CallWorkflowExecutor()
        case .fileOperation:    return FileOperationExecutor()
        case .dataExtraction:   return DataExtractionExecutor()
        case .windowOperation:  return WindowOperationExecutor()
        case .loopItems:        return LoopItemsExecutor()
        case .ocrExtract:       return OCRExtractExecutor()
        case .aiVisionLocator:  return AIVisionLocatorExecutor()
        case .aiDataParse:      return AITextParseExecutor()
        case .runWebJS:         return WebScriptExecutor()
        case .aiChat:           return AIChatExecutor()
        }
    }
}

// MARK: - 具体组件执行器实现

// MARK: - 原生 UI 交互执行器
/// 负责与 macOS 系统的 Accessibility API (AX) 进行深度对接，探测并操作原生界面元素
struct UIInteractionExecutor: RPAActionExecutor {
    func execute(action: RPAAction, context: WorkflowEngine) async -> ConnectionCondition {
        let parts = action.parameter.components(separatedBy: "|")
        guard parts.count >= 3 else {
            context.log("❌ UI交互参数不完整。需要重新配置。")
            return .failure
        }
        
        let appName = parts[0]
        let role = parts[1]
        let rawTitle = parts[2]
        
        let actionType = parts.count > 3 ? (parts[3].isEmpty ? "click" : parts[3]) : "click"
        let rawExtraValue = parts.count > 4 ? parts[4] : ""
        let timeout = parts.count > 5 ? (Int(parts[5]) ?? 5) : 5
        let matchMode = parts.count > 6 ? (parts[6].isEmpty ? "exact" : parts[6]) : "exact"
        let targetIndex = Int(parts.count > 7 ? (parts[7].isEmpty ? "0" : parts[7]) : "0") ?? 0
        let ignoreError = parts.count > 8 ? (parts[8] == "true") : false
        
        let title = context.parseVariables(rawTitle)
        let extraValue = context.parseVariables(rawExtraValue)
        
        if appName.isEmpty {
            context.log("❌ 缺失应用名称，无法定位。")
            return ignoreError ? .always : .failure
        }
        
        context.log("🔎 原生深度探测 [\(appName)] -> [\(title)] (模式:\(matchMode), 序号:\(targetIndex))...")
        
        // 强制激活应用
        let activateScript = "tell application \"\(appName)\" to activate"
        _ = NSAppleScript(source: activateScript)?.executeAndReturnError(nil)
        
        // ---------------------------------------------------------
        // 辅助方法：与拾取器保持 100% 一致的深层文本提取算法
        // ---------------------------------------------------------
        func extractComprehensiveTitle(from element: AXUIElement, depth: Int = 0) -> String {
            if depth > 3 { return "" }
            var valRef: CFTypeRef?
            for attr in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXHelpAttribute] {
                if AXUIElementCopyAttributeValue(element, attr as CFString, &valRef) == .success,
                   let str = valRef as? String, !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return str }
            }
            var childrenRef: CFTypeRef?
            // [✨修复 1] 替换为 as!
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success {
                let children = childrenRef as! [AXUIElement]
                for child in children {
                    var childRoleRef: CFTypeRef?; AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &childRoleRef)
                    if let childRole = childRoleRef as? String, childRole == "AXStaticText" {
                        if AXUIElementCopyAttributeValue(child, kAXValueAttribute as CFString, &valRef) == .success, let str = valRef as? String, !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return str }
                    }
                    let deepTitle = extractComprehensiveTitle(from: child, depth: depth + 1)
                    if !deepTitle.isEmpty { return deepTitle }
                }
            }
            return ""
        }
        
        struct MatchedUIElement { let element: AXUIElement; let role: String; let title: String }
        
        let startTime = Date()
        var success = false
        var extractedData = ""
        
        // ---------------------------------------------------------
        // 智能轮询引擎 (摒弃死板的 AppleScript，直接遍历 AX 树)
        // ---------------------------------------------------------
        while Date().timeIntervalSince(startTime) < Double(timeout) && context.isRunning {
            guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == appName }) else {
                try? await Task.sleep(nanoseconds: 500_000_000)
                continue
            }
            
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            var allMatches: [MatchedUIElement] = []
            
            func collectElementsDFS(in element: AXUIElement, currentDepth: Int) {
                if currentDepth > 20 { return } // 防止无限循环
                var childrenRef: CFTypeRef?
                // [修复 2] 替换为 as!
                if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success {
                    let children = childrenRef as! [AXUIElement]
                    for child in children {
                        var roleVal: CFTypeRef?; AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleVal)
                        let r = roleVal as? String ?? ""
                        let t = extractComprehensiveTitle(from: child)
                        
                        // 匹配逻辑校验
                        var titleMatches = false
                        if title.isEmpty {
                            titleMatches = true
                        } else {
                            if matchMode == "contains" { titleMatches = t.localizedCaseInsensitiveContains(title) }
                            else { titleMatches = (t == title) }
                        }
                        
                        let roleMatches = role.isEmpty || r == role || r.contains(role)
                        
                        if titleMatches && roleMatches && (!title.isEmpty || !role.isEmpty) {
                            allMatches.append(MatchedUIElement(element: child, role: r, title: t))
                        } else {
                            collectElementsDFS(in: child, currentDepth: currentDepth + 1)
                        }
                    }
                }
            }
            
            // 从所有窗口中搜索
            var windowsRef: CFTypeRef?
            // [修复 3] 替换为 as!
            if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success {
                let windows = windowsRef as! [AXUIElement]
                for window in windows { collectElementsDFS(in: window, currentDepth: 0) }
            }
            
            // 从顶部系统菜单栏搜索
            var menuBarRef: CFTypeRef?
            // [修复 4] 替换为 as!
            if AXUIElementCopyAttributeValue(appElement, kAXMenuBarAttribute as CFString, &menuBarRef) == .success {
                let menuBar = menuBarRef as! AXUIElement
                collectElementsDFS(in: menuBar, currentDepth: 0)
            }
            
            // ---------------------------------------------------------
            // 命中后的动作执行
            // ---------------------------------------------------------
            if allMatches.count > targetIndex {
                let finalTarget = allMatches[targetIndex]
                let targetEl = finalTarget.element
                
                if actionType == "read" {
                    extractedData = finalTarget.title
                } else if actionType == "write" {
                    // 1. 尝试调用底层 API 写入
                    AXUIElementSetAttributeValue(targetEl, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    let setResult = AXUIElementSetAttributeValue(targetEl, kAXValueAttribute as CFString, extraValue as CFTypeRef)
                    
                    // 2. 降级防线：如果有些自绘输入框不接受直接设值，我们用物理鼠标点击它，然后物理键盘键入！
                    if setResult != .success {
                        var posRef: CFTypeRef?; var sizeRef: CFTypeRef?
                        var pos = CGPoint.zero; var size = CGSize.zero
                        if AXUIElementCopyAttributeValue(targetEl, kAXPositionAttribute as CFString, &posRef) == .success { AXValueGetValue(posRef as! AXValue, .cgPoint, &pos) }
                        if AXUIElementCopyAttributeValue(targetEl, kAXSizeAttribute as CFString, &sizeRef) == .success { AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) }
                        
                        if size.width > 0 && size.height > 0 {
                            let center = CGPoint(x: pos.x + size.width/2, y: pos.y + size.height/2)
                            NativeInputManager.shared.click(at: center)
                            try? await Task.sleep(nanoseconds: 200_000_000)
                            NativeInputManager.shared.typeText(extraValue)
                        }
                    }
                } else {
                    // 点击动作 (Click)
                    let performResult = AXUIElementPerformAction(targetEl, kAXPressAction as CFString)
                    
                    // 降级防线：很多标签或纯文本没有原生 Press 动作，使用基于物理坐标的强行点击
                    if performResult != .success {
                        var posRef: CFTypeRef?; var sizeRef: CFTypeRef?
                        var pos = CGPoint.zero; var size = CGSize.zero
                        if AXUIElementCopyAttributeValue(targetEl, kAXPositionAttribute as CFString, &posRef) == .success { AXValueGetValue(posRef as! AXValue, .cgPoint, &pos) }
                        if AXUIElementCopyAttributeValue(targetEl, kAXSizeAttribute as CFString, &sizeRef) == .success { AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) }
                        
                        if size.width > 0 && size.height > 0 {
                            let center = CGPoint(x: pos.x + size.width/2, y: pos.y + size.height/2)
                            NativeInputManager.shared.click(at: center)
                        }
                    }
                }
                
                success = true
                break
            }
            
            // 轮询间隔 0.5 秒
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        
        // ---------------------------------------------------------
        // 结果汇报与异常软控制
        // ---------------------------------------------------------
        if success {
            if actionType == "read" && !extraValue.isEmpty {
                context.variables[extraValue] = extractedData
                context.log("✅ 读取文本并存入 [\(extraValue)]: \(extractedData)")
            } else if actionType == "write" {
                context.log("✅ 成功写入文本。")
            } else {
                context.log("✅ 成功定位并点击 UI 元素。")
            }
            return .always
        } else {
            if ignoreError {
                context.log("⚠️ 探测超时，未发现目标。已开启【忽略错误并继续】，放行下个节点。")
                return .always
            } else {
                context.log("❌ 探测超时 (\(timeout)s)，未能找到目标 UI 元素。")
                return .failure
            }
        }
    }
}

// MARK: - 变量设置执行器
/// 负责对引擎的运行时环境变量池进行写操作
struct SetVariableExecutor: RPAActionExecutor {
    func execute(action: RPAAction, context: WorkflowEngine) async -> ConnectionCondition {
        let parts = context.parseVariables(action.parameter).components(separatedBy: "|")
        if parts.count >= 2 {
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let val = parts[1]
            context.variables[key] = val
            context.log("🗂️ 设置变量: [\(key)] = \(val)")
        }
        return .always
    }
}

// MARK: - HTTP 请求执行器
/// 轻量级 API 调用封装，支持将状态码和结果直接写回上下文环境变量中
struct HTTPRequestExecutor: RPAActionExecutor {
    func execute(action: RPAAction, context: WorkflowEngine) async -> ConnectionCondition {
        let parts = context.parseVariables(action.parameter).components(separatedBy: "|")
        let urlStr = parts.count > 0 ? parts[0] : ""
        let method = parts.count > 1 ? parts[1] : "GET"
        
        if let url = URL(string: urlStr) {
            var req = URLRequest(url: url)
            req.httpMethod = method
            
            if let (data, resp) = try? await URLSession.shared.data(for: req), let response = resp as? HTTPURLResponse {
                if let str = String(data: data, encoding: .utf8) {
                    context.variables["http_response"] = str
                }
                context.variables["http_status"] = "\(response.statusCode)"
                context.log("🌐 HTTP \(method) 完成: 状态码 \(response.statusCode)")
                return .success
            }
        }
        
        context.log("❌ HTTP 请求失败或无效 URL")
        return .failure
    }
}

// MARK: - OCR 文本识别执行器
/// 负责屏幕区域截取、图像增强、基于 Vision 的文本识别及点击互动调度
struct OCRTextExecutor: RPAActionExecutor {
    func execute(action: RPAAction, context: WorkflowEngine) async -> ConnectionCondition {
        let parsedParam = context.parseVariables(action.parameter)
        let parts = parsedParam.components(separatedBy: "|")
        
        let targetText = parts.count > 0 ? parts[0] : parsedParam
        let regionStr = parts.count > 2 ? parts[2] : ""
        let targetApp = parts.count > 3 ? parts[3] : ""
        
        let actionType = parts.count > 4 ? parts[4] : (parts.count > 1 && parts[1] == "true" ? "leftClick" : "none")
        let matchMode = parts.count > 5 ? parts[5] : "contains"
        let timeout = Double(parts.count > 6 ? parts[6] : "5.0") ?? 5.0
        let targetIndex = Int(parts.count > 7 ? parts[7] : "-1") ?? -1
        let variableName = parts.count > 8 ? parts[8] : "ocr_result"
        let autoScroll = parts.count > 9 ? (parts[9] == "true") : false
        let fuzzyTolerance = Int(parts.count > 10 ? parts[10] : "1") ?? 1
        let enhanceContrast = parts.count > 11 ? (parts[11] == "true") : false
        
        // [解析滚屏新参数]
        let scrollDirection = parts.count > 12 ? parts[12] : "down"
        let scrollAmount = Int(parts.count > 13 ? parts[13] : "5") ?? 5
        
        var regionRect: CGRect? = nil
        if !regionStr.isEmpty {
            let coords = regionStr.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if coords.count == 4 { regionRect = CGRect(x: coords[0], y: coords[1], width: coords[2], height: coords[3]) }
        }
        
        let modeDesc = matchMode == "fuzzy" ? "容错:\(fuzzyTolerance)" : matchMode
        context.log("📸 OCR 寻找 [\((targetApp.isEmpty ? "全屏" : targetApp))]: '\(targetText)' (模式:\(modeDesc), 滚屏:\(autoScroll ? scrollDirection : "关"))")
        
        if !targetApp.isEmpty && actionType != "none" && actionType != "waitVanish" {
            if targetApp == "InternalBrowser" {
                await MainActor.run { BrowserWindowController.showSharedWindow() }
                try? await Task.sleep(nanoseconds: 300_000_000)
            } else if let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == targetApp }) {
                app.activate(options: .activateIgnoringOtherApps)
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        
        let startTime = Date()
        var attemptCount = 0
        
        let actualAppName = (targetApp == "InternalBrowser") ? ProcessInfo.processInfo.processName : (targetApp.isEmpty ? nil : targetApp)
        let actualWindowTitle = (targetApp == "InternalBrowser") ? "开发者浏览器" : nil
        
        let executeSearch = { () async -> (CGPoint, String)? in
            return await context.findTextOnScreen(
                text: targetText,
                sampleBase64: action.sampleImageBase64,
                region: regionRect,
                appName: actualAppName,
                windowTitle: actualWindowTitle,
                matchMode: matchMode,
                targetIndex: targetIndex,
                fuzzyTolerance: fuzzyTolerance,
                enhanceContrast: enhanceContrast
            )
        }
        
        if actionType == "waitVanish" {
            while Date().timeIntervalSince(startTime) < timeout && context.isRunning {
                attemptCount += 1
                let result = await executeSearch()
                if result == nil {
                    context.log("✅ 成功：第 \(attemptCount) 次轮询确认目标文字已从屏幕消失。")
                    return .success
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            context.log("❌ 超时 (\(timeout)s)，目标文字依然存在。")
            return .failure
        }
        
        while Date().timeIntervalSince(startTime) < timeout && context.isRunning {
            attemptCount += 1
            if let result = await executeSearch() {
                let finalPoint = CGPoint(x: result.0.x + action.offsetX, y: result.0.y + action.offsetY)
                
                if actionType == "read" {
                    context.variables[variableName] = result.1
                    context.log("📖 第 \(attemptCount) 次寻找成功，提取文字存入 {{\(variableName)}}: \(result.1)")
                } else if actionType != "none" {
                    context.log("🎯 第 \(attemptCount) 次寻找成功，落点: (\(Int(finalPoint.x)), \(Int(finalPoint.y)))，执行 \(actionType)")
                    await context.simulateMouseOperation(type: actionType, at: finalPoint)
                } else {
                    context.log("🎯 第 \(attemptCount) 次寻找成功发现目标 (仅等待)。")
                }
                return .success
            }
            
            // [终极优化] 智能定点滚屏
            if autoScroll {
                let dirText = scrollDirection == "up" ? "向上" : "向下"
                context.log("⏬ 未发现文字，准备\(dirText)滚动 (幅度:\(scrollAmount))...")
                
                // 1. 智能寻址：如果配置了搜索区域，先将鼠标悄悄移到区域中心，确保滚动的是该子容器！
                if let rect = regionRect {
                    let centerX = rect.origin.x + rect.size.width / 2.0
                    let centerY = rect.origin.y + rect.size.height / 2.0
                    let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: centerX, y: centerY), mouseButton: .left)
                    moveEvent?.post(tap: .cghidEventTap)
                    try? await Task.sleep(nanoseconds: 100_000_000) // 极短延时让前端响应 hover 状态
                }
                
                // 2. 触发系统级物理滚动
                let mappedType = scrollDirection == "up" ? "scrollUp" : "scrollDown"
                await context.simulateScroll(type: mappedType, amount: scrollAmount)
                
                // 3. 动画补偿：等待UI停止滚动且文字渲染清晰
                try? await Task.sleep(nanoseconds: 800_000_000)
            } else {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        
        context.log("❌ OCR 寻找超时 (\(timeout)s)，未发现目标文字。")
        return .failure
    }
}

// MARK: - 打开应用程序执行器
/// 负责应用的启动，支持新实例多开与静默唤起
struct OpenAppExecutor: RPAActionExecutor {
    func execute(action: RPAAction, context: WorkflowEngine) async -> ConnectionCondition {
        let parts = context.parseVariables(action.parameter).components(separatedBy: "|")
        let appTarget = parts.count > 0 ? (parts[0].isEmpty ? "Safari" : parts[0]) : "Safari"
        let silent = parts.count > 1 ? (parts[1] == "true") : false
        let newInstance = parts.count > 2 ? (parts[2] == "true") : false
        
        var appURL: URL?
        
        // 1. 尝试作为绝对路径解析 (如 /Applications/WeChat.app)
        if appTarget.hasPrefix("/") && appTarget.hasSuffix(".app") {
            appURL = URL(fileURLWithPath: appTarget)
        }
        // 2. 尝试作为 Bundle Identifier 解析 (如 com.tencent.xinWeChat)
        else if appTarget.contains(".") {
            appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appTarget)
        }
        
        // 3. 优先执行：现代化 NSWorkspace API (macOS 10.15+)
        if let url = appURL {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = !silent                // 是否强制拉到前台激活
            config.createsNewApplicationInstance = newInstance // 是否多开新实例
            
            do {
                try await NSWorkspace.shared.openApplication(at: url, configuration: config)
                let modeStr = silent ? "静默唤起" : "激活前置"
                let instanceStr = newInstance ? " [新实例]" : ""
                context.log("📂 现代化应用启动 (\(modeStr))\(instanceStr): \(url.lastPathComponent)")
                
                try? await Task.sleep(nanoseconds: silent ? 500_000_000 : 1_500_000_000)
                return .always
            } catch {
                context.log("⚠️ 现代化启动异常，尝试降级命令启动: \(error.localizedDescription)")
            }
        }
        
        // 4. 降级防线：如果用户执意手敲了中文 "微信" 或 "Safari"
        let task = Process()
        task.launchPath = "/usr/bin/open"
        var args = ["-a", appTarget]
        if silent { args.insert("-g", at: 0) }      // -g 后台启动
        if newInstance { args.insert("-n", at: 0) } // -n 多开实例
        task.arguments = args
        
        do {
            try task.run()
            let modeStr = silent ? "静默唤起" : "激活前置"
            let instanceStr = newInstance ? " [新实例多开]" : ""
            context.log("📂 降级命令启动 (\(modeStr))\(instanceStr): \(appTarget)")
            
            if !silent {
                let script = "tell application \"\(appTarget)\" to activate"
                var errorInfo: NSDictionary?
                NSAppleScript(source: script)?.executeAndReturnError(&errorInfo)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            } else {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        } catch {
            context.log("❌ 唤起应用失败: 未找到该应用或执行受阻。")
            return .failure
        }
        
        return .always
    }
}

// MARK: - 打开网址执行器
/// 负责操控浏览器，支持系统内置浏览器调度与外部浏览器拉起
struct OpenURLExecutor: RPAActionExecutor {
    func execute(action: RPAAction, context: WorkflowEngine) async -> ConnectionCondition {
        let parsedParam = context.parseVariables(action.parameter)
        let parts = parsedParam.components(separatedBy: "|")
        
        let rawUrl = parts.count > 0 ? parts[0] : parsedParam
        let browser = parts.count > 1 ? parts[1] : "InternalBrowser"
        let silent = parts.count > 2 ? (parts[2] == "true") : false
        let incognito = parts.count > 3 ? (parts[3] == "true") : false
        
        // [核心优化 1] 智能补全 HTTP 协议，防止用户只填域名导致崩溃
        var finalUrlStr = rawUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if !finalUrlStr.lowercased().hasPrefix("http") && !finalUrlStr.isEmpty {
            finalUrlStr = "https://" + finalUrlStr
        }
        
        guard let encodedURLString = finalUrlStr.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: encodedURLString) else {
            context.log("❌ 无效的 URL 格式: \(rawUrl)")
            return .failure
        }
        
        if browser == "InternalBrowser" {
            await MainActor.run {
                // 如果非静默，主动把浏览器窗口拉到最前
                if !silent {
                    BrowserWindowController.showSharedWindow()
                }
                
                let vm = BrowserViewModel.shared
                if vm.tabs.isEmpty {
                    vm.addNewTab(request: URLRequest(url: url), makeActive: !silent)
                } else {
                    if vm.activeTab == nil {
                        vm.activeTabId = vm.tabs.first?.id
                    }
                    if let activeTab = vm.activeTab {
                        activeTab.loadURL(url.absoluteString)
                    } else {
                        vm.addNewTab(request: URLRequest(url: url), makeActive: !silent)
                    }
                }
            }
            let modeStr = silent ? " (后台静默加载)" : ""
            context.log("🌐 [内置浏览器] 打开网址\(modeStr): \(finalUrlStr)")
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            
        } else if browser == "System" {
            // [核心优化 2] 采用 macOS 现代化 NSWorkspace API 打开系统默认浏览器
            if let targetAppUrl = NSWorkspace.shared.urlForApplication(toOpen: url) {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = !silent // 彻底实现静默控制
                
                do {
                    try await NSWorkspace.shared.open([url], withApplicationAt: targetAppUrl, configuration: config)
                    let modeStr = silent ? " (后台静默)" : ""
                    context.log("🌐 [系统默认] 打开网址\(modeStr): \(finalUrlStr)")
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    context.log("❌ 无法唤起系统默认浏览器: \(error.localizedDescription)")
                    return .failure
                }
            } else {
                // 兜底：如果找不到默认应用，退回旧版 API
                NSWorkspace.shared.open(url)
            }
            
        } else {
            // 指定外部浏览器 (Safari, Chrome, Edge)
            let task = Process()
            task.launchPath = "/usr/bin/open"
            var args: [String] = []
            
            // [✨核心优化 3] 修复旧版底层漏传 -g (静默启动) 的 Bug
            if silent { args.append("-g") }
            
            args.append(contentsOf: ["-a", browser])
            
            // [✨核心优化 4] 无痕模式参数注入 (针对 Chromium 内核)
            if incognito && (browser.contains("Chrome") || browser.contains("Edge")) {
                args.append("--args")
                args.append("--incognito")
            }
            
            args.append(url.absoluteString)
            task.arguments = args
            
            do {
                try task.run()
                let modeStr = silent ? " (后台静默)" : ""
                let incStr = incognito ? " [无痕模式]" : ""
                context.log("🌐 [\(browser)] 打开网址\(modeStr)\(incStr): \(finalUrlStr)")
                
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            } catch {
                context.log("❌ 无法唤起 \(browser) 浏览器: \(error.localizedDescription)")
                return .failure
            }
        }
        return .always
    }
}

// MARK: - 鼠标操作执行器
/// 处理点击、移动、双击、滚轮、拖拽等原生物理光标输入
struct MouseOperationExecutor: RPAActionExecutor {
    func execute(action: RPAAction, context: WorkflowEngine) async -> ConnectionCondition {
        let parsedParam = context.parseVariables(action.parameter)
        let parts = parsedParam.components(separatedBy: "|")
        let type = parts.count > 0 ? parts[0] : "leftClick"
        let val1 = parts.count > 1 ? parts[1] : parsedParam
        let val2 = parts.count > 2 ? parts[2] : "0, 0"
        let isRelative = parts.count > 3 ? (parts[3] == "true") : false
        
        // [✨核心防呆] 拦截占位符，如果没填应用名，则当作绝对坐标处理
        let rawTargetApp = parts.count > 4 ? parts[4] : ""
        let targetApp = rawTargetApp == "__WAIT_INPUT__" ? "" : rawTargetApp
        
        let currentLoc = CGEvent(source: nil)?.location ?? .zero
        
        var appOriginOffset = CGPoint.zero
        if !targetApp.isEmpty {
            let options = CGWindowListOption(arrayLiteral: .excludeDesktopElements, .optionOnScreenOnly)
            if let windowListInfo = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] {
                for info in windowListInfo {
                    if let ownerName = info[kCGWindowOwnerName as String] as? String, ownerName == targetApp {
                        if let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                           let bounds = CGRect(dictionaryRepresentation: boundsDict) {
                            
                            appOriginOffset = bounds.origin
                            context.log("🪟 动态锁定 [\(targetApp)] 窗口坐标: (\(Int(appOriginOffset.x)), \(Int(appOriginOffset.y)))")
                            break
                        }
                    }
                }
            }
            if appOriginOffset == .zero {
                context.log("⚠️ 未在屏幕上检测到 [\(targetApp)] 的活动窗口，降级为全屏绝对坐标...")
            }
        }
        
        if type == "drag" {
            let startCoords = val1.split(separator: ",")
            let endCoords = val2.split(separator: ",")
            
            if startCoords.count == 2, endCoords.count == 2,
               let sx = Double(startCoords[0].trimmingCharacters(in: .whitespaces)),
               let sy = Double(startCoords[1].trimmingCharacters(in: .whitespaces)),
               let ex = Double(endCoords[0].trimmingCharacters(in: .whitespaces)),
               let ey = Double(endCoords[1].trimmingCharacters(in: .whitespaces)) {
                
                let startPoint = isRelative ? CGPoint(x: currentLoc.x + sx, y: currentLoc.y + sy) : CGPoint(x: sx + appOriginOffset.x, y: sy + appOriginOffset.y)
                let endPoint = isRelative ? CGPoint(x: startPoint.x + ex, y: startPoint.y + ey) : CGPoint(x: ex + appOriginOffset.x, y: ey + appOriginOffset.y)
                await context.simulateDrag(from: startPoint, to: endPoint)
            } else {
                return .failure
            }
        } else if ["leftClick", "rightClick", "doubleClick", "move"].contains(type) {
            let coords = val1.split(separator: ",")
            if coords.count == 2, let x = Double(coords[0].trimmingCharacters(in: .whitespaces)), let y = Double(coords[1].trimmingCharacters(in: .whitespaces)) {
                
                // [✨坐标换算] 根据模式：(相对鼠标 / 应用相对偏移 / 绝对坐标)
                let targetPoint = isRelative ? CGPoint(x: currentLoc.x + x, y: currentLoc.y + y) : CGPoint(x: x + appOriginOffset.x, y: y + appOriginOffset.y)
                
                await context.simulateMouseOperation(type: type, at: targetPoint)
            } else {
                return .failure
            }
        } else if type.lowercased().contains("scroll") {
            let amount = Int(val1.trimmingCharacters(in: .whitespaces)) ?? 1
            await context.simulateScroll(type: type, amount: amount)
        }
        return .always
    }
}

// MARK: - 键盘输入执行器
/// 负责模拟人类打字以及全局键盘组合键的发送
struct TypeTextExecutor: RPAActionExecutor {
    func execute(action: RPAAction, context: WorkflowEngine) async -> ConnectionCondition {
        let parts = action.parameter.components(separatedBy: "|")
        let text = parts.count > 0 ? parts[0] : action.parameter
        let speed = parts.count > 1 ? parts[1] : "normal"
        
        let parsedText = context.parseVariables(text)
        await context.simulateKeyboardInput(input: parsedText, speedMode: speed)
        return .always
    }
}

// MARK: - 等待延时执行器
/// 负责阻塞当前流程，进行单纯的睡眠等待
struct WaitExecutor: RPAActionExecutor {
    func execute(action: RPAAction, context: WorkflowEngine) async -> ConnectionCondition {
        let sec = Double(context.parseVariables(action.parameter)) ?? 1.0
        try? await Task.sleep(for: .seconds(sec))
        return .always
    }
}

// MARK: - 人机协同：人工介入执行器
/// 挂起当前协程，切回主线程弹出 macOS 原生 Alert 拦截用户，拿到结果后恢复执行
struct AskUserInputExecutor: RPAActionExecutor {
    func execute(action: RPAAction, context: WorkflowEngine) async -> ConnectionCondition {
        let parts = context.parseVariables(action.parameter).components(separatedBy: "|")
        let promptText = parts.count > 0 ? parts[0] : "需要人工干预"
        let dialogType = parts.count > 1 ? parts[1] : "input"
        let targetVar = parts.count > 3 ? parts[3] : "user_input"
        
        context.log("🙋‍♂️ 流程暂停，等待人工介入：\\(promptText)")
        
        // 播放系统提示音，提醒用户回到电脑前
        NSSound(named: "Glass")?.play()
        
        // 使用 Continuation 将异步任务挂起，等待基于回调的 UI 弹窗结果
        let userResult: (success: Bool, value: String) = await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "RPA 需要您的协助"
                alert.informativeText = promptText
                alert.alertStyle = .warning
                
                // 确保弹窗无论如何都在最前沿
                NSApp.activate(ignoringOtherApps: true)
                
                var inputTextField: NSTextField?
                
                if dialogType == "input" {
                    alert.addButton(withTitle: "提交")
                    alert.addButton(withTitle: "取消中断")
                    
                    let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
                    textField.placeholderString = "请在此输入..."
                    alert.accessoryView = textField
                    inputTextField = textField
                    
                    // 自动获得焦点
                    alert.window.initialFirstResponder = textField
                } else {
                    alert.addButton(withTitle: "确认继续")
                    alert.addButton(withTitle: "取消并停止")
                }
                
                let response = alert.runModal()
                
                if response == .alertFirstButtonReturn {
                    // 用户点击了 提交/确认
                    let val = inputTextField?.stringValue ?? "true"
                    continuation.resume(returning: (true, val))
                } else {
                    // 用户点击了 取消
                    continuation.resume(returning: (false, ""))
                }
            }
        }
        
        if userResult.success {
            if dialogType == "input" {
                context.variables[targetVar] = userResult.value
                context.log("✅ 用户输入完毕，值已存入 {{\\(targetVar)}}，流程继续。")
            } else {
                context.log("✅ 用户已确认，流程继续。")
            }
            return .success
        } else {
            context.log("❌ 用户取消了人工介入或拒绝了操作，流程将走向失败分支。")
            return .failure
        }
    }
}

// MARK: - [优化] 条件判断执行器 (增加类型感知校验)
struct ConditionExecutor: RPAActionExecutor {
    func execute(action: RPAAction, context: WorkflowEngine) async -> ConnectionCondition {
        let parts = context.parseVariables(action.parameter).components(separatedBy: "|")
        if parts.count >= 3 {
            let leftValue = parts[0].trimmingCharacters(in: .whitespaces)
            let op = parts[1]
            let rightValue = parts[2].trimmingCharacters(in: .whitespaces)
            var isMatched = false
            
            // 强化处理：如果是比较数字，强转 Double 比较避免 "02" != "2" 的低级错误
            if let leftNum = Double(leftValue), let rightNum = Double(rightValue) {
                if op == "==" { isMatched = (leftNum == rightNum) }
                else if op == ">" { isMatched = (leftNum > rightNum) }
                else if op == "<" { isMatched = (leftNum < rightNum) }
                else if op == "contains" { isMatched = leftValue.contains(rightValue) } // 降级为字符串
            } else {
                // 传统字符串比对
                if op == "==" { isMatched = (leftValue == rightValue) }
                else if op == "contains" { isMatched = leftValue.contains(rightValue) }
                else if op == "!=" { isMatched = (leftValue != rightValue) }
            }
            
            context.log("⚖️ 判断: '\(leftValue)' \(op) '\(rightValue)' -> \(isMatched)")
            return isMatched ? .success : .failure
        }
        return .failure
    }
}

// MARK: - 系统消息提醒执行器 (重构优化版)
/// 负责发送 macOS 原生系统通知，支持【横幅通知】与【原生强制弹窗】两种模式
struct ShowNotificationExecutor: RPAActionExecutor {
    func execute(action: RPAAction, context: WorkflowEngine) async -> ConnectionCondition {
        let parsedParam = context.parseVariables(action.parameter)
        let parts = parsedParam.components(separatedBy: "|")
        
        // 严格按照新版规范解构参数
        let rawTitle = parts.count > 0 ? parts[0].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let title = rawTitle.isEmpty ? "LinRPA 机器人通知" : rawTitle
        
        let rawMessage = parts.count > 1 ? parts[1] : ""
        let mode = parts.count > 2 && !parts[2].isEmpty ? parts[2].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() : "banner"
        let playSound = parts.count > 3 ? (parts[3] == "true") : true
        
        // 1. 智能格式化与美化 (支持 JSON 漂亮打印，方便开发者直接在通知里打印 API 返回值)
        let formattedMessage = formatToReadableText(rawMessage)
        
        if mode == "dialog" {
            // 【原生强制弹窗模式】直接调用 AppKit 原生 NSAlert，100% 居中阻塞弹窗
            await MainActor.run {
                if playSound {
                    // 弹窗模式下触发清脆的系统提示音 (修复：使用字符串字面量调用 macOS 经典系统音效)
                    NSSound(named: "Glass")?.play()
                }
                
                let alert = NSAlert()
                alert.messageText = title
                
                // 弹窗模式可以容纳更多字符
                let maxLength = 2000
                alert.informativeText = formattedMessage.count > maxLength
                    ? String(formattedMessage.prefix(maxLength)) + "\n...(内容过长已截断)"
                    : formattedMessage
                
                alert.alertStyle = .informational
                alert.addButton(withTitle: "确定")
                
                // 强制将 RPA App 提至最前，确保弹窗绝对可见，不被遮挡
                NSApp.activate(ignoringOtherApps: true)
                
                // 阻塞式运行弹窗，直到用户点击
                alert.runModal()
            }
            context.log("🔔 触达原生强制弹窗 [\(title)]")
            
        } else if mode == "hud" || mode == "floating" {
            // 【新增：沉浸式科技悬浮窗模式】
            await MainActor.run {
                if playSound { NSSound(named: "Glass")?.play() }
                // 设为 5 秒自动隐藏，防止永远留在屏幕上
                AIThoughtHUDManager.shared.showNotification(title: title, content: formattedMessage, autoHideDelay: 5.0)
            }
            context.log("🔔 触达屏幕居中悬浮窗 [\(title)]")
            
        } else {
            // 【横幅通知模式】使用 AppleScript 触发系统级静默横幅
            let maxLength = 300
            let finalMessage = formattedMessage.count > maxLength
                ? String(formattedMessage.prefix(maxLength)) + "\n...(内容过长已截断)"
                : formattedMessage
            
            // 安全转义双引号，防止 AppleScript 语法错误
            let safeTitle = title.replacingOccurrences(of: "\"", with: "\\\"")
            let safeMessage = finalMessage.replacingOccurrences(of: "\"", with: "\\\"")
            
            // [✨补齐能力] 动态拼接声音参数
            let soundScript = playSound ? " sound name \"Glass\"" : ""
            let scriptStr = "display notification \"\(safeMessage)\" with title \"\(safeTitle)\"\(soundScript)"
            
            var errorInfo: NSDictionary?
            if let scriptObj = NSAppleScript(source: scriptStr) {
                scriptObj.executeAndReturnError(&errorInfo)
                if let err = errorInfo {
                    context.log("⚠️ 横幅通知发送失败: \(err)")
                } else {
                    context.log("🔔 触达横幅通知 [\(title)]")
                }
            }
        }
        
        // 通知不参与逻辑流阻断（除非是等待用户点击），固定返回 .success 顺利推进下一个节点
        return .success
    }
    
    /// 用于对 JSON 格式的变量字符串进行 Pretty Print 美化，提升可读性
    private func formatToReadableText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if (trimmed.hasPrefix("{") && trimmed.hasSuffix("}")) || (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")) {
            if let data = trimmed.data(using: .utf8),
               let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []),
               let prettyData = try? JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted, .withoutEscapingSlashes]),
               let prettyString = String(data: prettyData, encoding: .utf8) {
                return prettyString
            }
        }
        return text
    }
}

// MARK: - 剪贴板写入执行器
/// 覆写操作系统剪贴板
struct WriteClipboardExecutor: RPAActionExecutor {
    func execute(action: RPAAction, context: WorkflowEngine) async -> ConnectionCondition {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(context.parseVariables(action.parameter), forType: .string)
        return .always
    }
}

// MARK: - 剪贴板读取执行器
/// 读取剪贴板内容并存入内置的 clipboard 变量中
struct ReadClipboardExecutor: RPAActionExecutor {
    func execute(action: RPAAction, context: WorkflowEngine) async -> ConnectionCondition {
        if let text = NSPasteboard.general.string(forType: .string) {
            context.variables["clipboard"] = text
            context.log("📋 剪贴板已读取")
            return .success
        }
        return .failure
    }
}

// MARK: - Shell 脚本执行器
/// 负责直接从底层调度 `/bin/bash` 执行系统命令
struct RunShellExecutor: RPAActionExecutor {
    func execute(action: RPAAction, context: WorkflowEngine) async -> ConnectionCondition {
        let task = Process()
        task.launchPath = "/bin/bash"
        task.arguments = ["-c", context.parseVariables(action.parameter)]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        try? task.run()
        task.waitUntilExit()
        
        if let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8), !output.isEmpty {
            context.log("💻 Shell 输出:\n\(output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return .always
    }
}

// MARK: - AppleScript 执行器
/// 通过 OSA 框架执行苹果专用 AppleScript 自动化脚本
struct RunAppleScriptExecutor: RPAActionExecutor {
    func execute(action: RPAAction, context: WorkflowEngine) async -> ConnectionCondition {
        var err: NSDictionary?
        if let scriptObj = NSAppleScript(source: context.parseVariables(action.parameter)) {
            scriptObj.executeAndReturnError(&err)
            if let e = err {
                context.log("❌ AS 错误: \(e)")
            } else {
                context.log("✅ AS 执行完成")
            }
        }
        return .always
    }
}

// MARK: - AI 纯视觉分析执行器
/// 用于单纯的截屏并结合 prompt 将图像分析出结果
struct AIVisionExecutor: RPAActionExecutor {
    func execute(action: RPAAction, context: WorkflowEngine) async -> ConnectionCondition {
        do {
            let cgImage = try await ScreenCaptureUtility.captureScreen()
            let nsImage = NSImage(cgImage: cgImage, size: .zero)
            let promptText = context.parseVariables(action.parameter)
            
            let message = LLMMessage(role: .user, text: promptText, images: [nsImage])
            let stream = LLMService.shared.stream(messages: [message])
            
            var fullResult = ""
            var chunkBuffer = ""
            
            context.log("🌊 正在思考: ")
            
            var lastReportTime = CFAbsoluteTimeGetCurrent()
            
            for try await chunk in stream {
                guard context.isRunning else {
                    await MainActor.run { context.log("\n🛑 流程已终止，AI 响应流已切断。") }
                    break
                }
                
                fullResult += chunk
                chunkBuffer += chunk
                
                let now = CFAbsoluteTimeGetCurrent()
                if now - lastReportTime > 0.1 {
                    let textToAppend = chunkBuffer
                    chunkBuffer = ""
                    await MainActor.run { context.appendLogChunk(textToAppend) }
                    lastReportTime = now
                }
            }
            
            guard context.isRunning else { return .failure }
            
            if !chunkBuffer.isEmpty {
                await MainActor.run { context.appendLogChunk(chunkBuffer) }
            }
            
            context.log("🧠 AI 分析完成:\n\(fullResult)")
            return .success
        } catch {
            context.log("❌ AI 分析失败: \(error.localizedDescription)")
            return .failure
        }
    }
}

// MARK: - Web 智能体执行器 (终极架构：DOM降级自愈 + AXTree + 全息观测)
/// WebAgent 4.0 核心逻辑：循环获取结构、触发多模态模型、下发行为。
/// [✨防卡死进化]：当检测到 DOM 死锁时，自动抽取 macOS 原生 AXTree 辅助破局。
/// [✨精准制导]：采用 @AX-ID 路由映射机制，彻底解决 Retina 缩放与坐标漂移。
/// [✨全息监控]：完美对接 AgentMonitorManager，实现每轮截图、Prompt、DOM、AXTree 的打包与归档。
/// [✨自愈降级]：修复了 request_full_dom 无法获取真实全量 DOM 的空转 Bug。
/// [✨新增能力]：引入 SoM 视觉红框标记、React 框架智能清洗、支持 Wait 与 Open URL 动作。
struct WebAgentExecutor: RPAActionExecutor {
    
    func execute(action: RPAAction, context: WorkflowEngine) async -> ConnectionCondition {
        let params = WebAgentParams.parse(from: action.parameter)
        
        context.log("🌟 [WebAgent 4.0] 准备接管 [\(params.browser == "InternalBrowser" ? "内置浏览器" : params.browser)]...")
        await context.activateBrowser(params.browser)
        
        await MainActor.run {
            AgentMonitorManager.shared.showWindow(isAutoTrigger: true)
            AgentMonitorManager.shared.resetForNewTask()
        }
        
        let maxRounds = AppSettings.shared.webAgentMaxRounds
        var currentRound = 0
        var isTaskCompleted = false
        var actionHistory: [String] = []
        var useExtremeCompression = false
        var usedCorpusRecordIDs: Set<UUID> = []
        var successfulStepsJSON = "[]"
        
        // 状态追踪器
        var previousDOMContext = ""
        var unchangedDOMCount = 0
        var previousStepsSignature = ""
        
        // ==========================================
        // 阶段一：感知与决策执行循环
        // ==========================================
        while currentRound < maxRounds && !isTaskCompleted && context.isRunning {
            currentRound += 1
            let modeName = useExtremeCompression ? "极限压缩模式" : "完整DOM模式"
            context.log("🔄 [WebAgent] 第 \(currentRound) 轮感知与决策 (\(modeName))...")
            
            // 0. 任务开始前先快速视觉断言，已经达到断言要求就直接跳过节点。
            if context.isRunning && !isTaskCompleted && !params.successAssertion.isEmpty {
                context.log("🔍 [快速断言] 核查屏幕目标: '\(params.successAssertion)'")
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if await performOCRAssertion(assertionText: params.successAssertion, browser: params.browser, captureMode: params.captureMode, context: context, updateVision: false) {
                    context.log("✅ [快速视觉断言] 目标特征已出现，提前判定任务完成！")
                    isTaskCompleted = true
                    break
                }
            }
            
            // 本轮全息日志收集桶
            var roundExecLogs: [String] = []
            var currentPrompt = ""
            var currentThought = ""
            var currentStepsDesc: [String] = []
            
            // 1. 环境感知 (加入 SoM 红框标记 与 React 专属清洗分支)
            guard let env = await fetchEnvironmentState(params: params, useExtremeCompression: useExtremeCompression, context: context) else {
                return .failure
            }
            
            // 防卡死：比对 DOM
            if env.dom == previousDOMContext && !previousDOMContext.isEmpty {
                unchangedDOMCount += 1
                context.log("⚠️ 探测到当前页面 DOM 与上一次完全相同 (已停滞 \(unchangedDOMCount) 轮)。")
            } else {
                unchangedDOMCount = 0
            }
            previousDOMContext = env.dom
            
            // 降维打击：提取 AXTree，建立物理坐标路由字典
            var axTreeContext = ""
            var currentAXNodeMap: [String: CGPoint] = [:]
            
            if unchangedDOMCount > 0 {
                context.log("👁️ 启动深度透视：正在提取 macOS 原生 AXTree 并建立物理坐标路由映射...")
                let axData = await extractAXTree(browser: params.browser)
                axTreeContext = axData.tree
                currentAXNodeMap = axData.nodeMap
            }
            
            // 实时投递 AXTree 到监控台
            await MainActor.run { AgentMonitorManager.shared.axTreeSummary = axTreeContext }
            
            // 2. 查阅语料库与组装动态提示词
            let dynamicManual = buildDynamicManual(params: params, usedIDs: &usedCorpusRecordIDs, context: context)
            
            // 3. AI 推理规划
            let inferenceResult = await performAIInference(
                params: params, dom: env.dom, axTree: axTreeContext, image: env.image,
                history: actionHistory, unchangedCount: unchangedDOMCount, manual: dynamicManual, context: context
            )
            
            guard let (plan, promptUsed) = inferenceResult else {
                actionHistory.append("上一步模型输出格式错误，请严格输出 JSON。")
                await archiveRoundSnapshot(round: currentRound, image: env.image, prompt: "Prompt 构建/推理失败", thought: "模型推理异常/解析失败", dom: env.dom, axTree: axTreeContext, steps: [], logs: ["ERROR: 输出格式异常"], context: context)
                continue
            }
            
            currentPrompt = promptUsed
            currentThought = plan["thought"] as? String ?? ""
            guard let steps = plan["steps"] as? [[String: Any]], !steps.isEmpty else {
                context.log("⚠️ Agent 返回的动作列表为空，强制重新思考。")
                actionHistory.append("上一步未返回任何有效动作(steps为空)，请重新规划。")
                await archiveRoundSnapshot(round: currentRound, image: env.image, prompt: currentPrompt, thought: currentThought, dom: env.dom, axTree: axTreeContext, steps: [], logs: ["ERROR: Agent 未返回任何操作步骤"], context: context)
                continue
            }
            
            // 组装用于显示的 steps 描述
            currentStepsDesc = steps.enumerated().map { index, step in
                let aType = step["action_type"] as? String ?? "未知"; let tId = step["target_id"] as? String ?? ""; let iVal = step["input_value"] as? String ?? ""
                return "[\(aType)] ID: \(tId)" + (iVal.isEmpty ? "" : " | 输入: \(iVal)")
            }
            
            if let stepsData = try? JSONSerialization.data(withJSONObject: steps),
               let jsonStr = String(data: stepsData, encoding: .utf8) {
                successfulStepsJSON = jsonStr
            }
            
            // 防死锁：硬拦截重复动作
            let currentStepsSignature = steps.map { "\($0["action_type"] ?? "")-\($0["target_id"] ?? "")-\($0["input_value"] ?? "")" }.joined(separator: "|")
            if unchangedDOMCount > 0 && currentStepsSignature == previousStepsSignature {
                context.log("🛑 [防死锁硬拦截] 页面无变化且 AI 企图执行完全重复的动作！拦截下发。")
                actionHistory.append("【系统拦截】：你上一步操作未引起页面变化且企图执行重复动作！请使用 wait、open_url 或原生节点突破遮挡。")
                previousStepsSignature = currentStepsSignature
                
                roundExecLogs.append("⛔️ 系统硬熔断：拦截重复无效动作。")
                await archiveRoundSnapshot(round: currentRound, image: env.image, prompt: currentPrompt, thought: currentThought, dom: env.dom, axTree: axTreeContext, steps: currentStepsDesc, logs: roundExecLogs, context: context)
                continue
            }
            previousStepsSignature = currentStepsSignature
            
            // 降级逻辑落实
            if let firstStep = steps.first, let aType = firstStep["action_type"] as? String, aType == "request_full_dom" {
                if useExtremeCompression {
                    context.log("⚠️ AI 自主要求降级使用【完整 DOM】...")
                    
                    // 将降级动作也写入全息快照，方便日后回溯
                    roundExecLogs.append("🔄 触发降级机制：切换至完整 DOM 模式并重新感知。")
                    await archiveRoundSnapshot(round: currentRound, image: env.image, prompt: currentPrompt, thought: currentThought, dom: env.dom, axTree: axTreeContext, steps: currentStepsDesc, logs: roundExecLogs, context: context)
                    
                    useExtremeCompression = false
                    currentRound -= 1 // 回退轮次计数，降级重试不消耗总探索轮数
                    continue
                } else {
                    context.log("❌ 即使使用完整 DOM，AI 依然无法定位目标。")
                    roundExecLogs.append("❌ AI 宣告失败：无法在完整 DOM 中找到目标。")
                    await archiveRoundSnapshot(round: currentRound, image: env.image, prompt: currentPrompt, thought: currentThought, dom: env.dom, axTree: axTreeContext, steps: currentStepsDesc, logs: roundExecLogs, context: context)
                    await MainActor.run { AgentMonitorManager.shared.isProcessing = false }
                    return .failure
                }
            }
            
            // 4. UI 确认与派发执行
            let execResult = await executeActionChain(
                steps: steps, thought: currentThought, params: params,
                nodeTitle: action.displayTitle, context: context,
                actionHistory: &actionHistory, axNodeMap: currentAXNodeMap, roundExecLogs: &roundExecLogs
            )
            
            // 一轮正常结束，归档保存
            await archiveRoundSnapshot(
                round: currentRound, image: env.image, prompt: currentPrompt,
                thought: currentThought, dom: env.dom, axTree: axTreeContext,
                steps: currentStepsDesc, logs: roundExecLogs, context: context
            )
            
            if execResult.isTaskFinished {
                isTaskCompleted = true
                break
            } else if execResult.isInterrupted {
                return .failure
            }
            
            // 每当有实质性操作下发后，下一轮重置为压缩模式，避免 Token 长期爆炸
            useExtremeCompression = true
        }
        
        if currentRound >= maxRounds && !isTaskCompleted { context.log("🛑 已达最大轮数强制中断。") }
        
        // 清理探针
        _ = BrowserScriptBridge.runJS(in: params.browser, js: BrowserScriptBridge.probeTeardownJS)
        
        if !params.successAssertion.isEmpty && isTaskCompleted { isTaskCompleted = await runFinalAssertion(params: params, context: context) }
        // 知识库自我成长脚本，先注释暂停使用，代码不要删
        // if isTaskCompleted && currentRound > 1 && !actionHistory.isEmpty { await triggerSelfEvolution(params: params, successfulStepsJSON: successfulStepsJSON, context: context) }
        if !usedCorpusRecordIDs.isEmpty { await processDarwinianSettlement(usedIDs: usedCorpusRecordIDs, isSuccess: isTaskCompleted, context: context) }

        await MainActor.run { AgentMonitorManager.shared.isProcessing = false }
        return isTaskCompleted ? .success : .failure
    }
    
    // MARK: - 内部解耦模块：快照生成器
    private func archiveRoundSnapshot(round: Int, image: CGImage, prompt: String, thought: String, dom: String, axTree: String, steps: [String], logs: [String], context: WorkflowEngine) async {
        await MainActor.run {
            let nsImage = NSImage(cgImage: image, size: .zero)
            AgentMonitorManager.shared.archiveRound(
                round: round, vision: nsImage, prompt: prompt,
                thought: thought, dom: dom, axTree: axTree,
                steps: steps, logs: logs
            )
            context.log("📸 已对第 \(round) 轮进行全息快照沉淀。")
        }
    }
    
    // MARK: - 内部解耦模块：提取原生 AXTree
    private func extractAXTree(browser: String, maxDepth: Int = 8) async -> (tree: String, nodeMap: [String: CGPoint]) {
        let appName = browser == "InternalBrowser" ? ProcessInfo.processInfo.processName : browser
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == appName }) else {
            return ("无法获取应用进程", [:])
        }
        
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var result = ""
        var nodeMap: [String: CGPoint] = [:]
        var counter = 0
        
        func traverse(_ element: AXUIElement, depth: Int) {
            if depth > maxDepth { return }
            let indent = String(repeating: "  ", count: depth)
            
            var roleRef: CFTypeRef?; AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
            var titleRef: CFTypeRef?; AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef)
            
            let role = roleRef as? String ?? "Unknown"
            let title = titleRef as? String ?? ""
            
            let isInteractive = role.contains("Button") || role.contains("TextField") || role.contains("PopUp") || role.contains("Link") || role.contains("Menu") || role.contains("Tab") || role.contains("Window")
            
            if !title.isEmpty || isInteractive {
                var posRef: CFTypeRef?; var sizeRef: CFTypeRef?
                var pos = CGPoint.zero; var size = CGSize.zero
                
                if AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
                   AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
                   let pVal = posRef, CFGetTypeID(pVal) == AXValueGetTypeID(),
                   let sVal = sizeRef, CFGetTypeID(sVal) == AXValueGetTypeID() {
                    
                    AXValueGetValue(pVal as! AXValue, .cgPoint, &pos)
                    AXValueGetValue(sVal as! AXValue, .cgSize, &size)
                    
                    if size.width > 0 && size.height > 0 {
                        counter += 1
                        let nodeId = "@AX-\(counter)"
                        let absoluteCenterX = pos.x + size.width / 2.0
                        let absoluteCenterY = pos.y + size.height / 2.0
                        
                        nodeMap[nodeId] = CGPoint(x: absoluteCenterX, y: absoluteCenterY)
                        result += "\(indent)[\(nodeId)] [\(role)] '\(title)'\n"
                    }
                }
            }
            
            var childrenRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
               let children = childrenRef as? [AXUIElement] {
                for child in children { traverse(child, depth: depth + 1) }
            }
        }
        
        traverse(appElement, depth: 0)
        return (result.isEmpty ? "AXTree提取为空" : result, nodeMap)
    }

    // MARK: - 环境感知提取模块 (融合 React 嗅探与红框标记)
    private func fetchEnvironmentState(params: WebAgentParams, useExtremeCompression: Bool, context: WorkflowEngine) async -> (dom: String, image: CGImage)? {
        
        // 1. 嗅探是否为 React 框架
        let framework = await MainActor.run { BrowserScriptBridge.runJS(in: params.browser, js: BrowserScriptBridge.detectFrameworkJS) } ?? "None"
        context.log("⚛️ 探测到当前页面框架：" + framework)
        
        // 2. 选择合适的提取脚本
        let extractJS: String
        if useExtremeCompression {
            extractJS = BrowserScriptBridge.extractDOMJS
        } else {
            extractJS = (framework == "React") ? BrowserScriptBridge.reactEnvDomJs : BrowserScriptBridge.envDomJs
        }
        
        var domContext = await MainActor.run { BrowserScriptBridge.runJS(in: params.browser, js: extractJS) } ?? "NEED_INJECTION"
        
        if domContext == "PAGE_LOADING" {
            context.log("⏳ 检测到网页尚未渲染完成，等待 1.5 秒后重试提取...")
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            domContext = await MainActor.run { BrowserScriptBridge.runJS(in: params.browser, js: extractJS) } ?? "NEED_INJECTION"
        }
        
        if domContext == "NEED_INJECTION" || domContext == "NOT_FOUND" || domContext.isEmpty {
            await MainActor.run { _ = BrowserScriptBridge.runJS(in: params.browser, js: BrowserScriptBridge.probeInjectionJS) }
            try? await Task.sleep(nanoseconds: 200_000_000)
            await MainActor.run { _ = BrowserScriptBridge.runJS(in: params.browser, js: BrowserScriptBridge.forceTagJS) }
            domContext = await MainActor.run { BrowserScriptBridge.runJS(in: params.browser, js: extractJS) } ?? "页面暂无交互元素"
        }
        
        if domContext.contains("Error") || domContext.contains("ERROR:") {
            context.log("❌ DOM 提取异常: \(domContext)")
            return nil
        }
        
        await MainActor.run { AgentMonitorManager.shared.domSummary = domContext }
        
        // 3. [✨新增] 截图前注入并在页面上渲染红色边框和 ID，供大模型视觉辅助
        await MainActor.run { _ = BrowserScriptBridge.runJS(in: params.browser, js: BrowserScriptBridge.drawBBoxJS) }
        try? await Task.sleep(nanoseconds: 250_000_000) // 极短睡眠等待前端渲染完毕
        
        // 4. 执行截图
        let targetApp: String? = (params.captureMode == "fullscreen") ? nil : (params.browser == "InternalBrowser" ? ProcessInfo.processInfo.processName : params.browser)
        let targetTitle: String? = (params.captureMode == "fullscreen") ? nil : (params.browser == "InternalBrowser" ? "开发者浏览器" : nil)
        
        guard let screenImage = try? await ScreenCaptureUtility.captureScreen(forAppName: targetApp, targetWindowTitle: targetTitle) else { return nil }
        
        // 5. [✨新增] 截图完成后，隐蔽地抹去红框，不影响用户的正常交互和下一轮判定
        await MainActor.run { _ = BrowserScriptBridge.runJS(in: params.browser, js: BrowserScriptBridge.clearBBoxJS) }
        
        await MainActor.run { AgentMonitorManager.shared.currentVision = NSImage(cgImage: screenImage, size: .zero) }
        return (domContext, screenImage)
    }
    
    private func buildDynamicManual(params: WebAgentParams, usedIDs: inout Set<UUID>, context: WorkflowEngine) -> String {
        let relevantRecords = CorpusDatabase.shared.searchTopRelevantAdvanced(intent: params.taskDesc, topK: 10)
        var dynamicManual = params.manualText
        if !relevantRecords.isEmpty {
            dynamicManual += "\n\n【经验库】：\n"
            for (idx, record) in relevantRecords.enumerated() {
                usedIDs.insert(record.id)
                if let steps = record.synthesizedStepsJSON { dynamicManual += "案例\(idx+1): \(record.userIntent) -> \(steps)\n" }
            }
        }
        return dynamicManual
    }
    
    private func performAIInference(params: WebAgentParams, dom: String, axTree: String, image: CGImage, history: [String], unchangedCount: Int, manual: String, context: WorkflowEngine) async -> (plan: [String: Any], prompt: String)? {
        let historyStr = history.isEmpty ? "无" : history.enumerated().map{ "\($0.offset+1). \($0.element)" }.joined(separator: "\n")

        var prompt = AppSettings.shared.webAgentPrompt
            .replacingOccurrences(of: "{{TaskDesc}}", with: params.taskDesc)
            .replacingOccurrences(of: "{{SuccessAssertion}}", with: params.successAssertion.isEmpty ? "无" : params.successAssertion)
            .replacingOccurrences(of: "{{Manual}}", with: manual.isEmpty ? "无" : manual)
            .replacingOccurrences(of: "{{History}}", with: historyStr)
            .replacingOccurrences(of: "{{DOM}}", with: dom)
        
        if unchangedCount > 0 && !axTree.isEmpty {
            prompt += """
            
            ⚠️【系统级极高优警告与双重视野辅助】：
            你上一步的 DOM 动作已失效，页面 DOM 未发生改变！
            这通常意味着：
            1. 目标被网页内的悬浮层遮挡。
            2. 【极有可能】触发了脱离网页 DOM 的浏览器/系统原生弹窗（如文件选择器、权限允许框、原生 Alert 等）。
            
            为了突破原生弹窗遮挡，系统已为你打通底层，提取了当前窗口的 macOS 原生 UI 树 (AXTree)：
            
            ====== macOS Native AXTree ======
            \(axTree)
            =================================
            
            【你的决策逻辑必须遵守以下规范】：
            - 网页内部的元素寻找，继续依赖上方的 DOM 摘要，并使用普通的 action_type。
            - 如果你判断当前被 **系统原生弹窗/原生按钮** 阻塞，且能在 AXTree 中找到对应的原生按钮(如“允许”、“打开”、“取消”)，请**立即提取上方的原生节点 ID (如 @AX-5)**，并严格输出以下格式，没有发现不要发出执行。底层将直接接管系统鼠标物理点击该原生按钮：
            {"action_type": "physical_click", "target_id": "@AX-5"}
            """
        }
            
        context.log("🧠 [WebAgent] 大脑运转中...")
        await MainActor.run { AgentMonitorManager.shared.llmThought = ""; AgentMonitorManager.shared.plannedSteps.removeAll() }
        
        do {
            let nsImage = NSImage(cgImage: image, size: .zero)
            let message = LLMMessage(role: .user, text: prompt, images: [nsImage])
            let stream = LLMService.shared.stream(messages: [message])
            
            var aiResponse = ""; var chunkBuffer = ""; var lastReportTime = CFAbsoluteTimeGetCurrent()
            for try await chunk in stream {
                guard context.isRunning else { return nil }
                aiResponse += chunk; chunkBuffer += chunk
                let now = CFAbsoluteTimeGetCurrent()
                if now - lastReportTime > 0.1 {
                    let appendStr = chunkBuffer; let fullStr = aiResponse; chunkBuffer = ""
                    await MainActor.run { context.appendLogChunk(appendStr); AgentMonitorManager.shared.llmThought = fullStr }
                    lastReportTime = now
                }
            }
            guard context.isRunning else { return nil }
            if !chunkBuffer.isEmpty { await MainActor.run { context.appendLogChunk(chunkBuffer); AgentMonitorManager.shared.llmThought = aiResponse } }
            
            guard let jsonStr = aiResponse.extractJSON(), let jsonData = jsonStr.data(using: .utf8) else { return nil }
            let plan = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
            context.log("\n💡 思考结果: \(plan?["thought"] as? String ?? "")")
            return plan != nil ? (plan!, prompt) : nil
        } catch { return nil }
    }
    
    // MARK: - 动作派发下行 (支持了 wait 和 open_url)
    private func executeActionChain(steps: [[String: Any]], thought: String, params: WebAgentParams, nodeTitle: String, context: WorkflowEngine, actionHistory: inout [String], axNodeMap: [String: CGPoint], roundExecLogs: inout [String]) async -> (isInterrupted: Bool, isTaskFinished: Bool) {
        
        await MainActor.run {
            AgentMonitorManager.shared.plannedSteps = steps.enumerated().map { index, step in
                let aType = step["action_type"] as? String ?? "未知"; let tId = step["target_id"] as? String ?? ""; let iVal = step["input_value"] as? String ?? ""
                return "第\(index + 1)步: [\(aType)] ID: \(tId)" + (iVal.isEmpty ? "" : " | 输入: \(iVal)")
            }
        }
        
        for (index, step) in steps.enumerated() {
            let actionType = step["action_type"] as? String ?? "fail"
            let targetId = step["target_id"] as? String ?? ""
            let rawInputValue = step["input_value"] as? String ?? ""
            
            if actionType == "finish" { context.log("🏁 [WebAgent] 任务完毕。"); return (false, true) }
            else if actionType == "fail" { context.log("🛑 主动请求介入。"); return (true, false) }
            
            let inputValue = context.parseVariables(rawInputValue)
            context.log("⚙️ 步骤 \(index + 1): \(actionType) -> [\(targetId.isEmpty ? inputValue : targetId)]")
            
            var scriptResult = ""
            
            // [✨新增] 处理等待动作
            if actionType == "wait" {
                let waitSecs = Double(inputValue) ?? 1.0
                context.log("⏳ AI 发起自主等待: 休眠 \(waitSecs) 秒...")
                try? await Task.sleep(nanoseconds: UInt64(waitSecs * 1_000_000_000))
                scriptResult = "SUCCESS_WAIT"
            }
            // [✨新增] 处理页面跳转动作 (支持相对路径智能计算)
            else if actionType == "open_url" {
                context.log("🌐 AI 发起页面跳转: \(inputValue)")
                let safeUrl = inputValue.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "'", with: "\\'")
                let openUrlJS = BrowserScriptBridge.openUrlJS(safeUrl: safeUrl)
                scriptResult = await MainActor.run { BrowserScriptBridge.runJS(in: params.browser, js: openUrlJS) ?? "" }
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 强制给跳转动作预留基础加载时间
            }
            // 处理原生物理点击
            else if actionType == "physical_click" {
                if let absolutePoint = axNodeMap[targetId] {
                    context.log("🖱️ [原生强制接管] 匹配到底层节点 \(targetId)，正狙击系统绝对坐标 (\(Int(absolutePoint.x)), \(Int(absolutePoint.y)))...")
                    await context.simulateMouseOperation(type: "leftClick", at: absolutePoint)
                    scriptResult = "SUCCESS_PHYSICAL_CLICK"
                } else {
                    scriptResult = "Error: 系统无法映射该目标 ID，可能窗口已关闭或 AI 输出了无效 ID"
                }
            }
            // 默认的 DOM 交互回放
            else {
                let playbackJS = BrowserScriptBridge.generatePlaybackJS(targetId: targetId, actionType: actionType, inputValue: inputValue)
                scriptResult = await MainActor.run { BrowserScriptBridge.runJS(in: params.browser, js: playbackJS) ?? "" }
            }
            
            context.log("💻 执行返回: \(scriptResult.isEmpty ? "SUCCESS" : scriptResult)")
            
            let currentLog = "[\(actionType)] \(targetId.isEmpty ? inputValue : targetId) -> \(scriptResult.isEmpty ? "SUCCESS" : scriptResult)"
            roundExecLogs.append(currentLog)
            await MainActor.run { AgentMonitorManager.shared.actionExecutionLogs.append(currentLog) }
            
            if scriptResult.contains("Not Found") || scriptResult.contains("Error") {
                context.log("⚠️ 动作阻断，强制重评...")
                actionHistory.append("[\(actionType)] \(targetId) 失败: \(scriptResult)。")
                break
            } else {
                actionHistory.append("[\(actionType)] 目标:\(targetId.isEmpty ? inputValue : targetId) 成功")
            }
            
            try? await Task.sleep(nanoseconds: (index == steps.count - 1) ? 1_500_000_000 : 800_000_000)
            if !context.isRunning { return (true, false) }
        }
        return (false, false)
    }

    // ================= 断言与进化模块 =================
    private func runFinalAssertion(params: WebAgentParams, context: WorkflowEngine) async -> Bool {
        context.log("⏳ 等待渲染完成执行断言...")
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        if params.assertionType == "ocr" {
            let res = await performOCRAssertion(assertionText: params.successAssertion, browser: params.browser, captureMode: params.captureMode, context: context, updateVision: true)
            context.log(res ? "✅ [OCR 断言通过]" : "❌ [OCR 断言失败]")
            return res
        } else {
            let (res, reason) = await performAIAssertion(assertionText: params.successAssertion, browser: params.browser, captureMode: params.captureMode, context: context)
            context.log(res ? "✅ [AI 断言通过]: \(reason)" : "❌ [AI 断言失败]: \(reason)")
            return res
        }
    }
    
    private func triggerSelfEvolution(params: WebAgentParams, successfulStepsJSON: String, context: WorkflowEngine) async {
        let safeDOM = await MainActor.run { AgentMonitorManager.shared.domSummary }
        let newRecord = WebCorpusRecord(id: UUID(), timestamp: Date(), userIntent: params.taskDesc, beforeDOM: safeDOM, actionType: "sequence", targetId: "multi", inputValue: successfulStepsJSON, successCount: 1, failCount: 0, groupName: "AI 探索", isAutoGenerated: true)
        await MainActor.run { CorpusDatabase.shared.addRecord(newRecord) }
        await WebCorpusManager.shared.manualTranslate(recordId: newRecord.id)
    }
    
    private func processDarwinianSettlement(usedIDs: Set<UUID>, isSuccess: Bool, context: WorkflowEngine) async {
        await MainActor.run {
            let db = CorpusDatabase.shared; var isChanged = false
            for id in usedIDs {
                if let idx = db.records.firstIndex(where: { $0.id == id }) {
                    if isSuccess { db.records[idx].successCount += 1 } else { db.records[idx].failCount += 1 }
                    isChanged = true
                }
            }
            if isChanged { db.objectWillChange.send(); db.save() }
        }
    }

    private func performOCRAssertion(assertionText: String, browser: String, captureMode: String, context: WorkflowEngine, updateVision: Bool) async -> Bool {
        let app: String? = (captureMode == "fullscreen") ? nil : (browser == "InternalBrowser" ? ProcessInfo.processInfo.processName : browser)
        guard let img = try? await ScreenCaptureUtility.captureScreen(forAppName: app) else { return false }
        if updateVision { await MainActor.run { AgentMonitorManager.shared.currentVision = NSImage(cgImage: img, size: .zero) } }
        let req = VNRecognizeTextRequest()
        req.recognitionLanguages = ["zh-Hans", "en-US"]
        do {
            try VNImageRequestHandler(cgImage: img, options: [:]).perform([req])
            if let obs = req.results as? [VNRecognizedTextObservation] {
                return obs.contains { ($0.topCandidates(1).first?.string ?? "").localizedCaseInsensitiveContains(assertionText) }
            }
        } catch {}
        return false
    }
    
    private func performAIAssertion(assertionText: String, browser: String, captureMode: String, context: WorkflowEngine) async -> (Bool, String) {
        let app: String? = (captureMode == "fullscreen") ? nil : (browser == "InternalBrowser" ? ProcessInfo.processInfo.processName : browser)
        guard let img = try? await ScreenCaptureUtility.captureScreen(forAppName: app) else { return (false, "截屏失败") }
        await MainActor.run { AgentMonitorManager.shared.currentVision = NSImage(cgImage: img, size: .zero) }
        let prompt = "判断是否满足：\(assertionText)。输出 JSON: {\"is_success\": true/false, \"reason\": \"理由\"}"
        do {
            let res = try await LLMService.shared.generate(messages: [LLMMessage(role: .user, text: prompt, images: [NSImage(cgImage: img, size: .zero)])])
            if let json = res.extractJSON()?.data(using: .utf8), let dict = try JSONSerialization.jsonObject(with: json) as? [String: Any], let isSucc = dict["is_success"] as? Bool {
                return (isSucc, dict["reason"] as? String ?? "无")
            }
        } catch { return (false, "模型推理失败") }
        return (false, "解析失败")
    }
}

// MARK: - [✨重构] 流程调用执行器 (显式参数映射与隔离防抖)
struct CallWorkflowExecutor: RPAActionExecutor {
    func execute(action: RPAAction, context: WorkflowEngine) async -> ConnectionCondition {
        // 参数格式约定: target_uuid|{"子入参名":"父变量或文本", ...}
        let parts = action.parameter.components(separatedBy: "|")
        let targetIdStr = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard let targetId = UUID(uuidString: targetIdStr) else {
            context.log("❌ 调用的子工作流 ID 格式无效: [\(targetIdStr)]")
            return .failure
        }
        
        // 1. 显式参数映射解析 (Explicit Parameter Mapping)
        var explicitArgs: [String: String] = [:]
        if parts.count > 1 {
            let mappingJsonStr = parts[1]
            if let mappingData = mappingJsonStr.data(using: .utf8),
               let mappingDict = try? JSONSerialization.jsonObject(with: mappingData) as? [String: String] {
                
                for (childKey, parentExpression) in mappingDict {
                    // 动态解析父流程环境中的表达式或变量，赋值给子流程的 Key
                    explicitArgs[childKey] = context.parseVariables(parentExpression)
                }
            }
        }
        
        context.log("🔗 准备进入子工作流 (携带 \(explicitArgs.count) 个显式入参)...")
        
        // 2. 发起沙盒调用 (利用引擎内置深度控制，不用在此强算 depth)
        // 注意：这里 depth 取 0 仅仅是个占位，实际深度在引擎栈内已经通过 pop/append 得到宏观管控
        let result = await context.runWorkflow(by: targetId, args: explicitArgs, depth: 1)
        
        // 3. 将子工作流暴露的 isOutput 变量，合并写入到当前（父）工作流的变量池中
        if result.success {
            for (outKey, outValue) in result.outputs {
                context.variables[outKey] = outValue
                context.log("📥 接收子流程出参: [\(outKey)] = \(outValue.count > 30 ? "\(outValue.prefix(30))..." : outValue)")
            }
        }
        
        return result.success ? .success : .failure
    }
}

// MARK: - 文件操作执行器
struct FileOperationExecutor: RPAActionExecutor {
    func execute(action: RPAAction, context: WorkflowEngine) async -> ConnectionCondition {
        let parts = action.parameter.components(separatedBy: "|")
        let opType = parts.count > 0 ? parts[0] : "read"
        let rawFilePath = parts.count > 1 ? parts[1] : ""
        let rawContentOrVar = parts.count > 2 ? parts[2] : ""
        
        // 解析路径中的环境变量
        let filePath = context.parseVariables(rawFilePath).trimmingCharacters(in: .whitespacesAndNewlines)
        let fileURL = URL(fileURLWithPath: filePath)
        let fm = FileManager.default
        
        if opType == "exists" {
            let exists = fm.fileExists(atPath: filePath)
            if !rawContentOrVar.isEmpty { context.variables[rawContentOrVar] = exists ? "true" : "false" }
            context.log("📁 检查文件/目录: \(filePath) -> \(exists ? "存在" : "不存在")")
            return exists ? .success : .failure
        }
        
        // [✨新增] 新建文件逻辑
        if opType == "create" {
            let dirPath = fileURL.deletingLastPathComponent()
            do {
                // 1. 自动级联创建父目录 (防报错机制)
                if !fm.fileExists(atPath: dirPath.path) {
                    try fm.createDirectory(at: dirPath, withIntermediateDirectories: true, attributes: nil)
                }
                
                // 2. 幂等性校验：如果文件已经存在，视为成功（防止覆盖原本的重要数据）
                if fm.fileExists(atPath: filePath) {
                    context.log("⚠️ 文件已存在，自动跳过新建: \(filePath)")
                    return .success
                }
                
                // 3. 创建空文件
                let success = fm.createFile(atPath: filePath, contents: nil, attributes: nil)
                if success {
                    context.log("📄 成功新建空文件: \(filePath)")
                    return .success
                } else {
                    context.log("❌ 新建文件失败: 权限不足或路径不合法。")
                    return .failure
                }
            } catch {
                context.log("❌ 新建文件时无法创建父级目录: \(error.localizedDescription)")
                return .failure
            }
        }
        
        if opType == "read" {
            do {
                let content = try String(contentsOf: fileURL, encoding: .utf8)
                if !rawContentOrVar.isEmpty { context.variables[rawContentOrVar] = content }
                context.log("📖 成功读取文件: \(filePath) (\(content.count) 字符)")
                return .success
            } catch {
                context.log("❌ 读取文件失败: \(error.localizedDescription)")
                return .failure
            }
        }
        
        let contentToWrite = context.parseVariables(rawContentOrVar)
        
        // [✨全局优化] 写入和追加时，同样赋予自动创建父目录的安全防线
        let dirPath = fileURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: dirPath.path) {
            try? fm.createDirectory(at: dirPath, withIntermediateDirectories: true, attributes: nil)
        }
        
        if opType == "write" {
            do {
                try contentToWrite.write(to: fileURL, atomically: true, encoding: .utf8)
                context.log("✍️ 成功覆写文件: \(filePath)")
                return .success
            } catch {
                context.log("❌ 写入文件失败: \(error.localizedDescription)")
                return .failure
            }
        }
        
        if opType == "append" {
            if !fm.fileExists(atPath: filePath) {
                do { try contentToWrite.write(to: fileURL, atomically: true, encoding: .utf8) }
                catch { return .failure }
            } else {
                do {
                    let fileHandle = try FileHandle(forWritingTo: fileURL)
                    fileHandle.seekToEndOfFile()
                    if let data = contentToWrite.data(using: .utf8) {
                        fileHandle.write(data)
                        fileHandle.closeFile()
                    }
                } catch {
                    context.log("❌ 追加文件失败: \(error.localizedDescription)")
                    return .failure
                }
            }
            context.log("➕ 成功追加内容至文件: \(filePath)")
            return .success
        }
        return .failure
    }
}

// MARK: - 数据提取执行器
struct DataExtractionExecutor: RPAActionExecutor {
    func execute(action: RPAAction, context: WorkflowEngine) async -> ConnectionCondition {
        let parts = action.parameter.components(separatedBy: "|")
        let sourceData = context.parseVariables(parts.count > 0 ? parts[0] : "")
        let extractType = parts.count > 1 ? parts[1] : "json"
        let rule = context.parseVariables(parts.count > 2 ? parts[2] : "")
        let targetVar = parts.count > 3 ? parts[3] : "extracted_value"
        
        if extractType == "regex" {
            do {
                let regex = try NSRegularExpression(pattern: rule, options: [])
                let nsString = sourceData as NSString
                let results = regex.matches(in: sourceData, options: [], range: NSRange(location: 0, length: nsString.length))
                
                if let firstMatch = results.first {
                    let extracted = nsString.substring(with: firstMatch.range)
                    context.variables[targetVar] = extracted
                    context.log("🔍 正则提取成功: 找到 [\(extracted)] 并存入 {{\(targetVar)}}")
                    return .success
                } else {
                    context.log("⚠️ 正则提取未找到匹配项")
                    return .failure
                }
            } catch {
                context.log("❌ 正则规则无效: \(error.localizedDescription)")
                return .failure
            }
        }
        else if extractType == "json" {
            // 轻量级简易 JSON 解析 (支持如 data.user.id 的按层级点语法获取)
            guard let data = sourceData.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                context.log("❌ 数据来源不是合法的 JSON 对象")
                return .failure
            }
            
            let keys = rule.split(separator: ".").map(String.init)
            var currentObj: Any = json
            
            for key in keys {
                if let dict = currentObj as? [String: Any], let nextObj = dict[key] {
                    currentObj = nextObj
                } else {
                    context.log("⚠️ JSON 提取失败: 未找到键路径 [\(rule)]")
                    return .failure
                }
            }
            
            let resultStr = String(describing: currentObj)
            context.variables[targetVar] = resultStr
            context.log("🔍 JSON 提取成功: [\(rule)] = \(resultStr)")
            return .success
        }
        
        return .failure
    }
}

// MARK: - 窗口控制执行器
/// 负责调度系统级 AppleScript 对指定应用的窗口进行操纵
struct WindowOperationExecutor: RPAActionExecutor {
    func execute(action: RPAAction, context: WorkflowEngine) async -> ConnectionCondition {
        let parts = context.parseVariables(action.parameter).components(separatedBy: "|")
        let appName = parts.count > 0 ? parts[0] : ""
        let operation = parts.count > 1 ? parts[1] : "maximize"
        let bounds = parts.count > 2 ? parts[2] : "0, 0, 800, 600"
        
        guard !appName.isEmpty else {
            context.log("❌ 窗口控制失败：目标应用名称为空。")
            return .failure
        }
        
        var scriptStr = ""
        
        // 使用 AppleScript 进行原生的窗口控制
        switch operation {
        case "maximize":
            scriptStr = """
            tell application "System Events"
                tell process "\(appName)"
                    set frontmost to true
                    try
                        click (button 2 of window 1) -- 点击全屏/最大化按钮(绿灯)
                    on error
                        set value of attribute "AXFullScreen" of window 1 to true
                    end try
                end tell
            end tell
            """
        case "minimize":
            scriptStr = """
            tell application "System Events"
                tell process "\(appName)"
                    set value of attribute "AXMinimized" of window 1 to true
                end tell
            end tell
            """
        case "close":
            scriptStr = "tell application \"\(appName)\" to close window 1"
        case "bounds":
            let coords = bounds.components(separatedBy: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            if coords.count == 4 {
                scriptStr = """
                tell application "System Events"
                    tell process "\(appName)"
                        set frontmost to true
                        set position of window 1 to {\(coords[0]), \(coords[1])}
                        set size of window 1 to {\(coords[2]), \(coords[3])}
                    end tell
                end tell
                """
            } else {
                context.log("❌ 窗口坐标格式解析失败。")
                return .failure
            }
        default:
            return .failure
        }
        
        var errorInfo: NSDictionary?
        if let scriptObj = NSAppleScript(source: scriptStr) {
            scriptObj.executeAndReturnError(&errorInfo)
            
            if let err = errorInfo {
                // [✨体验优化] 精准捕获 macOS 经典的 -1743 权限拦截错误
                if let errNumber = err["NSAppleScriptErrorNumber"] as? Int, errNumber == -1743 {
                    context.log("⛔️ 窗口控制被系统拦截！请进入 [系统设置] -> [隐私与安全性] -> [自动化]，允许本程序控制 System Events。")
                    // 可选：你甚至可以直接调用引擎方法打开隐私面板
                    // await MainActor.run { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!) }
                } else {
                    context.log("⚠️ 窗口控制 [\(operation)] 执行受阻 (目标可能未启动或无窗口): \(err["NSAppleScriptErrorMessage"] ?? err)")
                }
                return .failure
            } else {
                context.log("🪟 成功对 [\(appName)] 执行窗口控制: \(operation)")
                return .success
            }
        }
        return .failure
    }
}

// MARK: - 循环遍历执行器
/// 将复杂的循环逻辑降维转换为：数组解析 -> 设置单项变量 -> 递归调用子流程
/// [✨新增] 支持智能降级解析：标准 JSON -> 单引号非标准 JSON -> 简易纯数组 -> 换行 -> 逗号 -> 单元素
struct LoopItemsExecutor: RPAActionExecutor {
    func execute(action: RPAAction, context: WorkflowEngine) async -> ConnectionCondition {
        let parts = action.parameter.components(separatedBy: "|")
        let rawSource = parts.count > 0 ? parts[0] : ""
        let itemVarName = parts.count > 1 ? parts[1] : "item"
        let rawWorkflowId = parts.count > 2 ? parts[2] : ""
        
        let sourceData = context.parseVariables(rawSource).trimmingCharacters(in: .whitespacesAndNewlines)
        let targetIdStr = context.parseVariables(rawWorkflowId).trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard let targetId = UUID(uuidString: targetIdStr) else {
            context.log("❌ 循环遍历失败：调用的子工作流 ID 格式无效。")
            return .failure
        }
        
        var itemsArray: [Any] = []
        var parseMode = "标准 JSON 数组"
        
        // ---------------------------------------------------------
        // 🌟 智能解析引擎 (Smart Fallback Parsing)
        // ---------------------------------------------------------
        if let jsonData = sourceData.data(using: .utf8),
           let jsonArray = try? JSONSerialization.jsonObject(with: jsonData) as? [Any] {
            itemsArray = jsonArray
        }
        else if let jsonData = sourceData.replacingOccurrences(of: "'", with: "\"").data(using: .utf8),
                let jsonArray = try? JSONSerialization.jsonObject(with: jsonData) as? [Any] {
            itemsArray = jsonArray
            parseMode = "非标准 JSON 数组(单引号)"
        }
        else if sourceData.hasPrefix("[") && sourceData.hasSuffix("]") {
            let innerContent = String(sourceData.dropFirst().dropLast())
            itemsArray = innerContent.components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
                .filter { !$0.isEmpty }
            parseMode = "简易纯数组剥离"
        }
        else if sourceData.contains("\n") {
            itemsArray = sourceData.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            parseMode = "多行文本"
        }
        else if sourceData.contains(",") || sourceData.contains("，") {
            let normalizedData = sourceData.replacingOccurrences(of: "，", with: ",")
            itemsArray = normalizedData.components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            parseMode = "逗号分隔文本"
        }
        else if !sourceData.isEmpty {
            itemsArray = [sourceData]
            parseMode = "单文本元素"
        }
        
        if itemsArray.isEmpty {
            context.log("⚠️ 遍历数据解析后为空 (模式:\(parseMode))，跳过循环。")
            return .success
        }
        
        context.log("🔁 开始循环遍历 (解析模式: \(parseMode))，共 \(itemsArray.count) 条数据...")
        
        // ---------------------------------------------------------
        // 迭代与子工作流调度
        // ---------------------------------------------------------
        for (index, item) in itemsArray.enumerated() {
            guard context.isRunning else { break }
            
            var itemString = ""
            if let dictOrArr = item as? [String: Any] {
                if let data = try? JSONSerialization.data(withJSONObject: dictOrArr), let str = String(data: data, encoding: .utf8) { itemString = str }
            } else if let arr = item as? [Any] {
                if let data = try? JSONSerialization.data(withJSONObject: arr), let str = String(data: data, encoding: .utf8) { itemString = str }
            } else {
                itemString = "\(item)"
            }
            
            // 为了向下兼容，依然向当前父上下文注入变量
            context.variables[itemVarName] = itemString
            
            let displayString = itemString.count > 40 ? String(itemString.prefix(40)) + "..." : itemString
            context.log("🔄 [循环 \(index + 1)/\(itemsArray.count)] 已注入变量 {{\(itemVarName)}} = \(displayString)")
            
            // [✨修复编译错误] 适配新的元组返回值，并利用显式 args 传递单项数据
            let result = await context.runWorkflow(by: targetId, args: [itemVarName: itemString], depth: 1)
            
            // 访问元组的 .success 属性进行逻辑判断
            if !result.success {
                context.log("⚠️ 循环在第 \(index + 1) 次时遇到子流程异常，循环提前终止。")
                return .failure
            }
        }
        
        context.log("✅ 循环遍历执行完毕。")
        return .success
    }
}

// MARK: - OCR 结构化全文提取执行器
/// 负责截取屏幕/窗口/区域，通过 Vision 框架提取全部文字，并进行 macOS 物理坐标系智能翻转计算
struct OCRExtractExecutor: RPAActionExecutor {
    func execute(action: RPAAction, context: WorkflowEngine) async -> ConnectionCondition {
        let parsedParam = context.parseVariables(action.parameter)
        let parts = parsedParam.components(separatedBy: "|")
        
        let regionStr = parts.count > 0 ? parts[0] : ""
        let targetApp = parts.count > 1 ? parts[1] : ""
        let outputFormat = parts.count > 2 ? parts[2] : "json"
        let languages = parts.count > 3 ? parts[3] : "zh-Hans,en-US"
        let level = parts.count > 4 ? parts[4] : "accurate"
        let variableName = parts.count > 5 ? parts[5] : "ocr_data"
        
        // 1. 区域解析
        var regionRect: CGRect? = nil
        if !regionStr.isEmpty {
            let coords = regionStr.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if coords.count == 4 { regionRect = CGRect(x: coords[0], y: coords[1], width: coords[2], height: coords[3]) }
        }
        
        // 2. 截取屏幕资源
        let actualAppName = (targetApp == "InternalBrowser") ? ProcessInfo.processInfo.processName : (targetApp.isEmpty ? nil : targetApp)
        let actualWindowTitle = (targetApp == "InternalBrowser") ? "开发者浏览器" : nil
        
        guard let fullCGImage = try? await ScreenCaptureUtility.captureScreen(forAppName: actualAppName, targetWindowTitle: actualWindowTitle) else {
            context.log("❌ 截屏失败，无法提取文本。请检查应用名称或屏幕录制权限。")
            return .failure
        }
        
        let bounds = CGDisplayBounds(CGMainDisplayID())
        var targetCGImage = fullCGImage
        var cropOffset = CGPoint.zero
        var cropSize = bounds.size
        
        // 3. 裁剪处理
        if let r = regionRect {
            let safeRect = r.intersection(bounds)
            if !safeRect.isNull {
                // [✨核心修复] Retina 屏幕缩放比适配 (Points -> Pixels)
                let scaleX = CGFloat(fullCGImage.width) / bounds.width
                let scaleY = CGFloat(fullCGImage.height) / bounds.height
                
                let pixelRect = CGRect(
                    x: safeRect.origin.x * scaleX,
                    y: safeRect.origin.y * scaleY,
                    width: safeRect.width * scaleX,
                    height: safeRect.height * scaleY
                )
                
                if let cropped = fullCGImage.cropping(to: pixelRect) {
                    targetCGImage = cropped
                    cropOffset = safeRect.origin // 记录逻辑偏移，因为最终抛出的坐标需是逻辑坐标
                    cropSize = safeRect.size     // 记录逻辑尺寸
                } else {
                    context.log("⚠️ 警告：图像裁切越界，降级使用全图。")
                }
            }
        }
        
        context.log("📸 正在提取[\(targetApp.isEmpty ? "全屏" : targetApp)]文本 (语言:\(languages), 精度:\(level))...")
        
        // 4. 配置 Vision OCR 引擎
        let request = VNRecognizeTextRequest()
        request.recognitionLanguages = languages.components(separatedBy: ",")
        request.recognitionLevel = level == "fast" ? .fast : .accurate
        request.usesLanguageCorrection = true
        
        do {
            let handler = VNImageRequestHandler(cgImage: targetCGImage, options: [:])
            try handler.perform([request])
            
            guard let observations = request.results as? [VNRecognizedTextObservation] else {
                context.log("⚠️ 提取完毕，但未发现任何有效文本。")
                context.variables[variableName] = outputFormat == "json" ? "[]" : ""
                return .success
            }
            
            // 5. 数据处理与坐标翻转
            if outputFormat == "json" {
                var jsonResult: [[String: Any]] = []
                
                for obs in observations {
                    if let topCandidate = obs.topCandidates(1).first {
                        // 🌟 核心算法：Vision 的 Y 轴是自底向上的 (0~1)，且是基于裁剪图像的比例
                        // 我们必须将其翻转并映射回 macOS 全局屏幕坐标 (Top-Left 原点)
                        let rawBox = obs.boundingBox
                        
                        let width = rawBox.width * cropSize.width
                        let height = rawBox.height * cropSize.height
                        
                        let localX = rawBox.minX * cropSize.width
                        let localY = (1.0 - rawBox.maxY) * cropSize.height // Top-Left 翻转
                        
                        let absoluteX = cropOffset.x + localX
                        let absoluteY = cropOffset.y + localY
                        
                        jsonResult.append([
                            "text": topCandidate.string,
                            "confidence": topCandidate.confidence,
                            "x": Int(absoluteX),
                            "y": Int(absoluteY),
                            "width": Int(width),
                            "height": Int(height)
                        ])
                    }
                }
                
                let jsonData = try JSONSerialization.data(withJSONObject: jsonResult, options: [.prettyPrinted])
                let jsonString = String(data: jsonData, encoding: .utf8) ?? "[]"
                context.variables[variableName] = jsonString
                context.log("✅ 成功提取 \(jsonResult.count) 条结构化 JSON 数据并存入 {{\(variableName)}}")
                
            } else {
                // 纯文本合并模式
                let allText = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                context.variables[variableName] = allText
                context.log("✅ 成功提取纯文本 (\(allText.count) 字) 并存入 {{\(variableName)}}")
            }
            
            return .success
            
        } catch {
            context.log("❌ OCR 提取引擎发生异常: \(error.localizedDescription)")
            return .failure
        }
    }
}

// MARK: - AI 视觉元素定位执行器 (终极版)
/// 支持窗口隔离以降低幻觉，支持区域框选裁剪(节省Token与耗时)，并支持自定义坐标偏移修正
struct AIVisionLocatorExecutor: RPAActionExecutor {
    func execute(action: RPAAction, context: WorkflowEngine) async -> ConnectionCondition {
        let parts = context.parseVariables(action.parameter).components(separatedBy: "|")
        let targetDesc = parts.count > 0 ? parts[0] : ""
        let actionType = parts.count > 1 ? parts[1] : "leftClick"
        let ignoreError = parts.count > 3 ? (parts[3] == "true") : false
        let targetApp = parts.count > 4 ? parts[4] : ""
        let offsetStr = parts.count > 5 ? parts[5] : "0,0"
        let regionStr = parts.count > 6 ? parts[6] : ""
        
        if targetDesc.isEmpty {
            context.log("❌ 视觉定位失败：目标描述为空。")
            return ignoreError ? .always : .failure
        }
        
        // 解析坐标偏移
        var offsetX: Double = 0; var offsetY: Double = 0
        let offsetParts = offsetStr.split(separator: ",")
        if offsetParts.count == 2 {
            offsetX = Double(offsetParts[0].trimmingCharacters(in: .whitespaces)) ?? 0
            offsetY = Double(offsetParts[1].trimmingCharacters(in: .whitespaces)) ?? 0
        }
        
        // 解析框选区域
        var regionRect: CGRect? = nil
        if !regionStr.isEmpty {
            let coords = regionStr.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if coords.count == 4 { regionRect = CGRect(x: coords[0], y: coords[1], width: coords[2], height: coords[3]) }
        }
        
        do {
            // 1. 截取屏幕 (如果指定了 App，会过滤出该 App 的图层)
            let fullCGImage = try await ScreenCaptureUtility.captureScreen(forAppName: targetApp.isEmpty ? nil : targetApp)
            
            let bounds = CGDisplayBounds(CGMainDisplayID())
            var targetCGImage = fullCGImage
            var cropOffset = CGPoint.zero
            var cropSize = bounds.size // 逻辑尺寸
            
            // 2. 图像裁剪 (Viewport Cropping)
            if let r = regionRect {
                let safeRect = r.intersection(bounds)
                if !safeRect.isNull {
                    // 处理 Retina 屏幕缩放比 (Points -> Pixels)
                    let scaleX = CGFloat(fullCGImage.width) / bounds.width
                    let scaleY = CGFloat(fullCGImage.height) / bounds.height
                    
                    let pixelRect = CGRect(
                        x: safeRect.origin.x * scaleX,
                        y: safeRect.origin.y * scaleY,
                        width: safeRect.width * scaleX,
                        height: safeRect.height * scaleY
                    )
                    
                    if let cropped = fullCGImage.cropping(to: pixelRect) {
                        targetCGImage = cropped
                        cropOffset = safeRect.origin // 记录裁剪在全屏中的逻辑偏移坐标
                        cropSize = safeRect.size     // 记录裁剪的逻辑宽高
                    } else {
                        context.log("⚠️ 警告：设定的视觉区域越界，降级使用全图分析。")
                    }
                }
            }
            
            let width = targetCGImage.width
            let height = targetCGImage.height
            let nsImage = NSImage(cgImage: targetCGImage, size: .zero)
            
            let scopeStr = targetApp.isEmpty ? "全屏" : "[\(targetApp)]窗口"
            let regionLog = regionRect != nil ? " 指定区域内" : ""
            context.log("📸 [AI视觉定位] 正在 \(scopeStr)\(regionLog) 寻找: '\(targetDesc)' ...")
            
            // 3. 构造强约束 Prompt
            let prompt = """
            你是一个精准的屏幕坐标定位 AI。这是一张尺寸为 \(width)x\(height) 像素的屏幕截图（左上角为 0,0）。
            请在图中找到描述为：“\(targetDesc)” 的目标元素，并估算其【正中心点】的 X 和 Y 坐标像素值。
            
            你必须且只能输出如下 JSON 格式，绝不允许输出任何其他解释性文字：
            {"x": 120, "y": 50}
            """
            
            let message = LLMMessage(role: .user, text: prompt, images: [nsImage])
            let resultStr = try await LLMService.shared.generate(messages: [message])
            
            guard let jsonStr = resultStr.extractJSON(),
                  let jsonData = jsonStr.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let xStr = dict["x"], let yStr = dict["y"],
                  let x = Double("\(xStr)"), let y = Double("\(yStr)") else {
                
                context.log("⚠️ AI 无法确定目标位置，原始回复: \(resultStr.prefix(50))...")
                return ignoreError ? .always : .failure
            }
            
            // 4. 坐标缩放映射 (局部像素 -> 局部逻辑点 -> 全局逻辑点)
            let scaleX = cropSize.width / CGFloat(width)
            let scaleY = cropSize.height / CGFloat(height)
            
            // 计算出的局部逻辑点 + 裁剪框在全屏的偏移量 + 用户自定义微调偏移量
            let finalPoint = CGPoint(
                x: cropOffset.x + (x * scaleX) + offsetX,
                y: cropOffset.y + (y * scaleY) + offsetY
            )
            
            let offsetLog = (offsetX != 0 || offsetY != 0) ? " (含偏移 X:\(offsetX) Y:\(offsetY))" : ""
            context.log("🎯 AI 定位成功，全局落点: (\(Int(finalPoint.x)), \(Int(finalPoint.y)))\(offsetLog)，执行 \(actionType)")
            
            // 5. 执行鼠标动作
            await context.simulateMouseOperation(type: actionType, at: finalPoint)
            return .success
            
        } catch {
            context.log("❌ AI 视觉定位调用异常: \(error.localizedDescription)")
            return ignoreError ? .always : .failure
        }
    }
}

// MARK: - AI 智能数据结构化执行器 (进阶版)
/// 支持强 Schema 约束，确保输出数据的稳定性和代码鲁棒性
struct AITextParseExecutor: RPAActionExecutor {
    func execute(action: RPAAction, context: WorkflowEngine) async -> ConnectionCondition {
        let parts = action.parameter.components(separatedBy: "|")
        let sourceData = context.parseVariables(parts.count > 0 ? parts[0] : "")
        let instruction = context.parseVariables(parts.count > 1 ? parts[1] : "")
        let targetVar = parts.count > 2 ? parts[2] : "parsed_data"
        let jsonTemplate = context.parseVariables(parts.count > 3 ? parts[3] : "")
        
        if sourceData.isEmpty || instruction.isEmpty {
            context.log("⚠️ AI 解析跳过：数据源或指令为空。")
            return .failure
        }
        
        context.log("🧠 正在使用 AI 解析与清洗文本数据 (长度: \(sourceData.count))...")
        
        // [✨进阶升级] 动态组装强约束 Prompt
        var prompt = """
        【处理任务】
        \(instruction)
        
        【原始数据】
        \(sourceData)
        
        【要求】
        请只输出合法的 JSON 字符串，不要包含任何 Markdown 格式(如```json)或额外的解释性文字。
        """
        
        if !jsonTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            prompt += """
            
            【强制输出结构】
            请严格按照以下 JSON 结构输出你的提取结果。如果原始数据中找不到某个字段，请使用 null、空字符串或 0 填充。
            模板：
            \(jsonTemplate)
            """
        }
        
        let message = LLMMessage(role: .user, text: prompt)
        
        do {
            let resultStr = try await LLMService.shared.generate(messages: [message])
            
            // 使用你的 String 扩展提取 JSON，剔除废话
            let cleanJSON = resultStr.extractJSON() ?? resultStr
            
            context.variables[targetVar] = cleanJSON
            context.log("✅ AI 数据结构化完成，存入 {{\(targetVar)}}。")
            
            return .success
        } catch {
            context.log("❌ AI 解析调用失败: \(error.localizedDescription)")
            return .failure
        }
    }
}

// MARK: - Web 脚本控制执行器 (终极版)
struct WebScriptExecutor: RPAActionExecutor {
    func execute(action: RPAAction, context: WorkflowEngine) async -> ConnectionCondition {
        let parts = action.parameter.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
        let browser = parts.count > 0 ? parts[0] : "InternalBrowser"
        let targetVar = parts.count > 1 ? parts[1] : ""
        let timeout = parts.count > 2 ? (Double(parts[2]) ?? 10.0) : 10.0
        let rawJsCode = parts.count > 3 ? parts[3] : ""
        
        // 1. 传统的字符串占位符替换 (向下兼容)
        let jsCode = context.parseVariables(rawJsCode)
        
        if jsCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            context.log("⚠️ 网页 JS 执行跳过: 脚本内容为空。")
            return .success
        }
        
        // 2. [✨核心架构升级] 将 RPA 全局变量池安全地注入为 JS 全局对象
        // 这样可以彻底解决文本中存在单双引号或换行符导致 JS 语法树(AST)崩溃的致命缺陷
        var safeInjectedJS = jsCode
        if let varsData = try? JSONSerialization.data(withJSONObject: context.variables, options: []),
           let varsJsonStr = String(data: varsData, encoding: .utf8) {
            safeInjectedJS = """
            const RPA = \(varsJsonStr);
            \(jsCode)
            """
        }
        
        context.log("🌐 开始向 [\(browser)] 注入异步 JS 脚本 (限时 \(timeout) 秒)...")
        
        // 传递 timeout 给 Bridge，并执行经过安全包裹的 JS 代码
        let result = await BrowserScriptBridge.runJSAsync(in: browser, js: safeInjectedJS, timeout: timeout, context: context)
        
        if let res = result {
            if res.hasPrefix("ERROR:") || res.hasPrefix("TIMEOUT:") {
                context.log("❌ 网页 JS 执行异常: \(res)")
                return .failure
            }
            
            if !targetVar.isEmpty {
                context.variables[targetVar] = res
                context.log("✅ 网页 JS 异步执行成功，返回值已存入 {{\(targetVar)}}。")
            } else {
                context.log("✅ 网页 JS 异步执行成功。无变量接收。")
            }
            return .success
        } else {
            context.log("❌ 网页 JS 执行失败：找不到对应的浏览器窗口或标签页未就绪。")
            return .failure
        }
    }
}

// MARK: - AI 智能对话执行器 (支持后台静默与前端多轮交互)
struct AIChatExecutor: RPAActionExecutor {
    func execute(action: RPAAction, context: WorkflowEngine) async -> ConnectionCondition {
        let parts = action.parameter.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
        
        let rawSystemPrompt = parts.count > 0 ? parts[0] : ""
        let targetVar = parts.count > 1 ? parts[1] : "ai_result"
        let rawUserPrompt = parts.count > 2 ? parts[2] : ""
        let showHUD = parts.count > 3 ? (parts[3] == "true") : true
        
        let systemPrompt = context.parseVariables(rawSystemPrompt).trimmingCharacters(in: .whitespacesAndNewlines)
        let userPrompt = context.parseVariables(rawUserPrompt).trimmingCharacters(in: .whitespacesAndNewlines)
        
        if showHUD {
            context.log("🧠 正在呼出 AI 悬浮窗，移交用户控制权...")
            
            // 阻塞式调用：挂起 RPA 流程，直到用户在悬浮窗中完成所有多轮交互并点击关闭
            let finalResult = await AIThoughtHUDManager.shared.showInteractiveChat(
                title: "AI 思考与协作中",
                systemPrompt: systemPrompt,
                initialInput: userPrompt
            )
            
            // 将最后一轮的对话结果写入全局变量池，供下一个动作使用
            if !targetVar.isEmpty {
                context.variables[targetVar] = finalResult
                context.log("✅ AI 交互已由用户主动结束，最终结果已存入 {{\\(targetVar)}}")
            }
            return .success
            
        } else {
            // ==========================================
            // 后台静默模式 (不弹窗，直接调用 API 并保存)
            // ==========================================
            if userPrompt.isEmpty {
                context.log("⚠️ AI 对话跳过：静默模式下未检测到用户提示词。")
                return .failure
            }
            
            context.log("🧠 正在后台静默请求 AI 大模型...")
            var finalPrompt = userPrompt
            if !systemPrompt.isEmpty {
                finalPrompt = "【系统设定/前提约束】\\n\\(systemPrompt)\\n\\n【用户指令】\\n\\(userPrompt)"
            }
            
            let message = LLMMessage(role: .user, text: finalPrompt)
            
            do {
                let stream = LLMService.shared.stream(messages: [message])
                var fullResult = ""
                var chunkBuffer = ""
                var lastReportTime = CFAbsoluteTimeGetCurrent()
                
                context.log("🌊 AI 响应中: ")
                for try await chunk in stream {
                    guard context.isRunning else {
                        await MainActor.run { context.log("\\n🛑 流程已终止。") }
                        break
                    }
                    fullResult += chunk
                    chunkBuffer += chunk
                    
                    let now = CFAbsoluteTimeGetCurrent()
                    if now - lastReportTime > 0.1 {
                        let textToAppend = chunkBuffer
                        chunkBuffer = ""
                        await MainActor.run { context.appendLogChunk(textToAppend) }
                        lastReportTime = now
                    }
                }
                
                guard context.isRunning else { return .failure }
                if !chunkBuffer.isEmpty { await MainActor.run { context.appendLogChunk(chunkBuffer) } }
                
                if !targetVar.isEmpty {
                    context.variables[targetVar] = fullResult
                    context.log("\\n✅ 后台 AI 思考完成，结果已存入 {{\\(targetVar)}}")
                }
                return .success
                
            } catch {
                context.log("\\n❌ AI 调用异常: \\(error.localizedDescription)")
                return .failure
            }
        }
    }
}
