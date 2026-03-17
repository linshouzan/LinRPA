//////////////////////////////////////////////////////////////////
// 文件名：ActionExecutors.swift
// 文件说明：RPA动作执行器集合，采用策略模式解耦执行逻辑
// 功能说明：存放所有的 RPA 节点具体执行逻辑。
// 代码要求：没有要求修改不用输出代码，请保证代码的逻辑和完整性，保留代码中的所有注释内容
//////////////////////////////////////////////////////////////////

import Foundation
import AppKit
import Vision

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
                // [✨修复 2] 替换为 as!
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
            // [✨修复 3] 替换为 as!
            if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success {
                let windows = windowsRef as! [AXUIElement]
                for window in windows { collectElementsDFS(in: window, currentDepth: 0) }
            }
            
            // 从顶部系统菜单栏搜索
            var menuBarRef: CFTypeRef?
            // [✨修复 4] 替换为 as!
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
        
        // [✨解析滚屏新参数]
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
            
            // [✨终极优化] 智能定点滚屏
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
        
        // [✨核心优化 1] 智能补全 HTTP 协议，防止用户只填域名导致崩溃
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
            // [✨核心优化 2] 采用 macOS 现代化 NSWorkspace API 打开系统默认浏览器
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

// MARK: - 条件判断执行器
/// 提供基础的包含、等于验证逻辑，用于指引流程在工作流中的走向
struct ConditionExecutor: RPAActionExecutor {
    func execute(action: RPAAction, context: WorkflowEngine) async -> ConnectionCondition {
        let parts = context.parseVariables(action.parameter).components(separatedBy: "|")
        if parts.count >= 3 {
            let leftValue = parts[0]
            let op = parts[1]
            let rightValue = parts[2]
            var isMatched = false
            
            if op == "==" {
                isMatched = (leftValue == rightValue)
            } else if op == "contains" {
                isMatched = leftValue.contains(rightValue)
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
            // 🌟 【原生强制弹窗模式】直接调用 AppKit 原生 NSAlert，100% 居中阻塞弹窗
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
            
        } else {
            // 🌟 【横幅通知模式】使用 AppleScript 触发系统级静默横幅
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

// MARK: - Web 智能体执行器
/// WebAgent 4.0 的核心逻辑：循环获取结构、触发多模态模型、下发行为，最后通过双引擎断言验证
struct WebAgentExecutor: RPAActionExecutor {
    func execute(action: RPAAction, context: WorkflowEngine) async -> ConnectionCondition {
        let params = WebAgentParams.parse(from: action.parameter)
        
        context.log("🌟 [WebAgent 4.0] 准备接管 [\(params.browser == "InternalBrowser" ? "内置浏览器" : "Safari")]...")
        await context.activateBrowser(params.browser)
        
        await MainActor.run {
            AgentMonitorManager.shared.showWindow(isAutoTrigger: true)
            AgentMonitorManager.shared.resetForNewTask()
        }
        
        let maxRounds = AppSettings.shared.webAgentMaxRounds
        var currentRound = 0
        var isTaskCompleted = false
        var actionHistory: [String] = []
        
        // ==========================================
        // 第一阶段：感知与决策执行循环
        // ==========================================
        while currentRound < maxRounds && !isTaskCompleted && context.isRunning {
            currentRound += 1
            context.log("🔄 [WebAgent] 第 \(currentRound) 轮感知与决策...")
            
            let domContext = await context.injectSoMAndGetDOM(browser: params.browser)
            if domContext.contains("Error") {
                context.log("❌ [WebAgent] 获取网页结构失败: \(domContext)")
                await MainActor.run { AgentMonitorManager.shared.isProcessing = false }
                return .failure
            }
            
            await MainActor.run { AgentMonitorManager.shared.domSummary = domContext }
            try? await Task.sleep(for: .milliseconds(300))
            
            let targetCaptureApp: String? = (params.captureMode == "fullscreen") ? nil : (params.browser == "InternalBrowser" ? ProcessInfo.processInfo.processName : params.browser)
            let targetWindowTitle: String? = (params.captureMode == "fullscreen") ? nil : (params.browser == "InternalBrowser" ? "开发者浏览器" : nil)
            
            guard let screenCGImage = try? await ScreenCaptureUtility.captureScreen(forAppName: targetCaptureApp, targetWindowTitle: targetWindowTitle) else {
                context.log("❌ [WebAgent] 截屏失败，请检查屏幕录制权限。")
                await MainActor.run { AgentMonitorManager.shared.isProcessing = false }
                return .failure
            }
            
            await MainActor.run { AgentMonitorManager.shared.currentVision = NSImage(cgImage: screenCGImage, size: .zero) }
            await context.cleanupSoM(browser: params.browser)
            
            let historyStr = actionHistory.isEmpty ? "无" : actionHistory.enumerated().map{ "\($0.offset+1). \($0.element)" }.joined(separator: "\n")

            let prompt = AppSettings.shared.webAgentPrompt
                .replacingOccurrences(of: "{{TaskDesc}}", with: params.taskDesc)
                .replacingOccurrences(of: "{{SuccessAssertion}}", with: params.successAssertion.isEmpty ? "无 (自主判断)" : params.successAssertion)
                .replacingOccurrences(of: "{{Manual}}", with: params.manualText.isEmpty ? "无" : params.manualText)
                .replacingOccurrences(of: "{{History}}", with: historyStr)
                .replacingOccurrences(of: "{{DOM}}", with: domContext)
            
            context.log("🧠 [WebAgent] 大脑运转中 (图文多模态推理)...")
            context.log("🌊 正在思考: ")
            
            await MainActor.run {
                AgentMonitorManager.shared.llmThought = ""
                AgentMonitorManager.shared.plannedSteps.removeAll()
            }
            
            do {
                let nsImage = NSImage(cgImage: screenCGImage, size: .zero)
                let message = LLMMessage(role: .user, text: prompt, images: [nsImage])
                let stream = LLMService.shared.stream(messages: [message])
                
                var aiResponse = ""
                var chunkBuffer = ""
                var lastReportTime = CFAbsoluteTimeGetCurrent()
                
                for try await chunk in stream {
                    guard context.isRunning else {
                        await MainActor.run { AgentMonitorManager.shared.isProcessing = false }
                        break
                    }
                    aiResponse += chunk
                    chunkBuffer += chunk
                    
                    let now = CFAbsoluteTimeGetCurrent()
                    if now - lastReportTime > 0.1 {
                        let textToAppend = chunkBuffer
                        let currentFullResponse = aiResponse
                        chunkBuffer = ""
                        await MainActor.run {
                            context.appendLogChunk(textToAppend)
                            AgentMonitorManager.shared.llmThought = currentFullResponse
                        }
                        lastReportTime = now
                    }
                }
                
                guard context.isRunning else { return .failure }
                if !chunkBuffer.isEmpty {
                    let finalResponse = aiResponse
                    await MainActor.run {
                        context.appendLogChunk(chunkBuffer)
                        AgentMonitorManager.shared.llmThought = finalResponse
                    }
                }
                
                guard let jsonStr = aiResponse.extractJSON(),
                      let jsonData = jsonStr.data(using: .utf8),
                      let plan = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                    context.log("\n⚠️ [WebAgent] JSON 格式异常，重试。")
                    actionHistory.append("上一步模型输出格式错误，请严格输出 JSON。")
                    continue
                }
                
                let thought = plan["thought"] as? String ?? ""
                context.log("\n💡 思考结果: \(thought)")
                
                guard let steps = plan["steps"] as? [[String: Any]], !steps.isEmpty else {
                    context.log("⚠️ Agent 返回的动作列表为空，强制重新思考。")
                    actionHistory.append("上一步未返回任何有效动作(steps为空)，请重新规划。")
                    continue
                }
                
                await MainActor.run {
                    AgentMonitorManager.shared.plannedSteps = steps.enumerated().map { index, step in
                        let aType = step["action_type"] as? String ?? "未知"
                        let tId = step["target_id"] as? String ?? ""
                        let iVal = step["input_value"] as? String ?? ""
                        let valDesc = iVal.isEmpty ? "" : " | 输入: \(iVal)"
                        return "第\(index + 1)步: [\(aType)] ID: \(tId)\(valDesc)"
                    }
                }
                
                if params.requireConfirm {
                    let stepsDesc = steps.map { "[\($0["action_type"] ?? "")] ID:\($0["target_id"] ?? "") \($0["input_value"] ?? "")" }.joined(separator: "\n")
                    let confirmMsg = "思考: \(thought)\n\n计划连续执行以下动作:\n\(stepsDesc)"
                    if !(await context.requestUserConfirmation(title: "Agent 连续动作确认", message: confirmMsg)) {
                        context.log("🛑 用户终止操作。")
                        await MainActor.run { AgentMonitorManager.shared.isProcessing = false }
                        return .failure
                    }
                }
                
                for (index, step) in steps.enumerated() {
                    let actionType = step["action_type"] as? String ?? "fail"
                    let targetId = step["target_id"] as? String ?? ""
                    let rawInputValue = step["input_value"] as? String ?? ""
                    
                    let inputValue = context.parseVariables(rawInputValue)
                    let isSensitive = rawInputValue.contains("{{") && rawInputValue.contains("}}") && rawInputValue != inputValue
                    let displayValue = isSensitive ? "****** (已安全隔离注入)" : inputValue
                    
                    if actionType == "finish" {
                        context.log("🏁 [WebAgent] AI 判断任务已执行完毕。")
                        isTaskCompleted = true
                        break
                    } else if actionType == "fail" {
                        context.log("🛑 [WebAgent] 主动请求人工介入。")
                        await MainActor.run { AgentMonitorManager.shared.isProcessing = false }
                        return .failure
                    }
                    
                    context.log("⚙️ 执行步骤 \(index + 1): \(actionType) -> [\(targetId)]")
                    actionHistory.append("[\(actionType)] 目标ID:\(targetId) 输入:\(rawInputValue)")
                    
                    let (injectedScript, scriptResult) = await context.injectActionJS(browser: params.browser, action: actionType, targetId: targetId, value: inputValue)
                    
                    let nodeName = action.displayTitle
                    let logMessage = """
                    ➤ 节点名称: \(nodeName)
                    ➤ 动作意图: \(actionType) (目标ID: \(targetId.isEmpty ? "无" : targetId))
                    ➤ 注入操作:
                    \(isSensitive ? "// 🔒 安全脱敏，已隐藏底层注入脚本与真实凭据内容" : injectedScript)
                    ➤ 返回结果: \(scriptResult.isEmpty ? "undefined / 无返回值" : scriptResult)
                    """
                    
                    await MainActor.run {
                        AgentMonitorManager.shared.actionExecutionLogs.append(logMessage)
                    }
                    
                    let sleepTime: UInt64 = (index == steps.count - 1) ? 1_500_000_000 : 300_000_000
                    try? await Task.sleep(nanoseconds: sleepTime)
                    
                    if !context.isRunning { break }
                }
                
            } catch {
                context.log("❌ [WebAgent] 推理失败: \(error.localizedDescription)")
                await MainActor.run { AgentMonitorManager.shared.isProcessing = false }
                return .failure
            }
        }
        
        // ==========================================
        // 第二阶段：[✨升级] 支持双引擎的最终视觉断言阶段
        // ==========================================
        if !params.successAssertion.isEmpty {
            let modeStr = params.assertionType == "ocr" ? "极速 OCR 识字" : "AI 多模态裁判"
            context.log("🔍 [WebAgent] 开始最终独立视觉断言检查 (模式: \(modeStr))...")
            await MainActor.run { AgentMonitorManager.shared.llmThought = "正在执行最终视觉断言 (\(modeStr))..." }
            
            // 1. 给页面的跳转、加载或动画留出充足的缓冲时间
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            
            // 2. 截取屏幕区域
            let targetCaptureApp: String? = (params.captureMode == "fullscreen") ? nil : (params.browser == "InternalBrowser" ? ProcessInfo.processInfo.processName : params.browser)
            let targetWindowTitle: String? = (params.captureMode == "fullscreen") ? nil : (params.browser == "InternalBrowser" ? "开发者浏览器" : nil)
            
            if let assertionImage = try? await ScreenCaptureUtility.captureScreen(forAppName: targetCaptureApp, targetWindowTitle: targetWindowTitle) {
                
                await MainActor.run { AgentMonitorManager.shared.currentVision = NSImage(cgImage: assertionImage, size: .zero) }
                
                if params.assertionType == "ocr" {
                    // ------------------------------------------
                    // 分支 A：本地 Vision OCR 极速断言
                    // ------------------------------------------
                    context.log("📸 [WebAgent] 正在限定视觉区域内扫描文本: '\(params.successAssertion)'")
                    
                    let request = VNRecognizeTextRequest()
                    request.recognitionLanguages = ["zh-Hans", "en-US"]
                    request.usesLanguageCorrection = true
                    
                    do {
                        let handler = VNImageRequestHandler(cgImage: assertionImage, options: [:])
                        try handler.perform([request])
                        
                        if let observations = request.results as? [VNRecognizedTextObservation] {
                            let isFound = observations.contains { obs in
                                let text = obs.topCandidates(1).first?.string ?? ""
                                return text.localizedCaseInsensitiveContains(params.successAssertion)
                            }
                            
                            if isFound {
                                context.log("✅ [OCR 断言通过]: 在视觉区域内成功匹配到目标文字 '\(params.successAssertion)'")
                                isTaskCompleted = true
                            } else {
                                context.log("❌ [OCR 断言失败]: 视觉区域内未找到指定文字 '\(params.successAssertion)'")
                                isTaskCompleted = false
                            }
                        } else {
                            context.log("❌ [OCR 断言失败]: 屏幕内容无法被识别。")
                            isTaskCompleted = false
                        }
                    } catch {
                        context.log("❌ [OCR 断言失败]: Vision 引擎执行异常: \(error.localizedDescription)")
                        isTaskCompleted = false
                    }
                    
                } else {
                    // ------------------------------------------
                    // 分支 B：原生 AI 大模型推理断言
                    // ------------------------------------------
                    let assertionPrompt = """
                    你是一个客观、严格的 RPA 视觉断言裁判。请观察截图，判断当前页面是否已经满足以下成功条件：
                    【断言条件】: \(params.successAssertion)
                    
                    请严格输出 JSON 格式：
                    {
                        "is_success": true或者false,
                        "reason": "简短的判断理由"
                    }
                    """
                    
                    let nsImage = NSImage(cgImage: assertionImage, size: .zero)
                    let message = LLMMessage(role: .user, text: assertionPrompt, images: [nsImage])
                    
                    context.log("🧠 裁判介入，校验最终任务结果...")
                    if let resultStr = try? await LLMService.shared.generate(messages: [message]),
                       let jsonStr = resultStr.extractJSON(),
                       let jsonData = jsonStr.data(using: .utf8),
                       let resultDict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                       let isSuccess = resultDict["is_success"] as? Bool {
                        
                        let reason = resultDict["reason"] as? String ?? "无"
                        if isSuccess {
                            context.log("✅ [AI 断言通过]: \(reason)")
                            isTaskCompleted = true
                        } else {
                            context.log("❌ [AI 断言失败]: \(reason)")
                            isTaskCompleted = false // 强行扭转结果为失败
                        }
                    } else {
                        context.log("⚠️ 最终断言解析失败，降级依赖运行状态。")
                    }
                }
            } else {
                context.log("⚠️ 断言截屏失败，降级依赖运行状态。")
            }
        } else if currentRound >= maxRounds && !isTaskCompleted {
            context.log("🛑 [WebAgent] 已达到系统设置的最大允许轮数 (\(maxRounds) 轮)，强制中断。")
        }
        
        await MainActor.run { AgentMonitorManager.shared.isProcessing = false }
        return isTaskCompleted ? .success : .failure
    }
}

struct CallWorkflowExecutor: RPAActionExecutor {
    func execute(action: RPAAction, context: WorkflowEngine) async -> ConnectionCondition {
        // 【✨核心修复】强力清除可能的隐藏空格和换行符
        let targetIdStr = context.parseVariables(action.parameter).trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard let targetId = UUID(uuidString: targetIdStr) else {
            context.log("❌ 调用的子工作流 ID 格式无效: [\(targetIdStr)]")
            return .failure
        }
        
        context.log("🔗 开始进入子工作流: \(targetIdStr)...")
        let success = await context.runWorkflow(by: targetId)
        context.log("🔗 子工作流执行完毕，返回主流程。")
        
        return success ? .success : .failure
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
            context.log("📁 检查文件: \(filePath) -> \(exists ? "存在" : "不存在")")
            return exists ? .success : .failure
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
        
        // 尝试将来源数据解析为 JSON 数组
        guard let jsonData = sourceData.data(using: .utf8),
              let jsonArray = try? JSONSerialization.jsonObject(with: jsonData) as? [Any] else {
            context.log("❌ 循环遍历失败：数据源无法解析为合法的 JSON 数组。\n数据: \(sourceData.prefix(50))...")
            return .failure
        }
        
        if jsonArray.isEmpty {
            context.log("⚠️ 遍历数据为空，跳过循环。")
            return .success
        }
        
        context.log("🔁 开始循环遍历，共 \(jsonArray.count) 条数据...")
        
        for (index, item) in jsonArray.enumerated() {
            guard context.isRunning else { break }
            
            // 将当前项转换为字符串（如果是字典或数组，序列化为 JSON 字符串；如果是标量，转为普通字符串）
            var itemString = ""
            if let dictOrArr = item as? [String: Any] {
                if let data = try? JSONSerialization.data(withJSONObject: dictOrArr), let str = String(data: data, encoding: .utf8) { itemString = str }
            } else if let arr = item as? [Any] {
                if let data = try? JSONSerialization.data(withJSONObject: arr), let str = String(data: data, encoding: .utf8) { itemString = str }
            } else {
                itemString = "\(item)"
            }
            
            // 注入变量池
            context.variables[itemVarName] = itemString
            context.log("🔄 [循环 \(index + 1)/\(jsonArray.count)] 已注入变量 {{\(itemVarName)}}")
            
            // 阻塞式调用子流程
            let success = await context.runWorkflow(by: targetId)
            
            if !success {
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

