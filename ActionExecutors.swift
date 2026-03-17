//////////////////////////////////////////////////////////////////
// 文件名：ActionExecutors.swift
// 文件说明：RPA动作执行器集合，采用策略模式解耦执行逻辑
// 功能说明：存放所有的 RPA 节点具体执行逻辑。
// 代码要求：没有要求修改不用输出代码，请保证代码的逻辑和完整性，保留代码中的所有注释内容
//////////////////////////////////////////////////////////////////

import Foundation
import AppKit
import Vision

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
        case .condition:        return ConditionExecutor()
        case .showNotification: return ShowNotificationExecutor()
        case .ocrText:          return OCRTextExecutor()
        case .mouseOperation:   return MouseOperationExecutor()
        case .writeClipboard:   return WriteClipboardExecutor()
        case .readClipboard:    return ReadClipboardExecutor()
        case .runShell:         return RunShellExecutor()
        case .runAppleScript:   return RunAppleScriptExecutor()
        case .callWorkflow:     return CallWorkflowExecutor()
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
        let currentLoc = CGEvent(source: nil)?.location ?? .zero
        
        if type == "drag" {
            let startCoords = val1.split(separator: ",")
            let endCoords = val2.split(separator: ",")
            
            if startCoords.count == 2, endCoords.count == 2,
               let sx = Double(startCoords[0].trimmingCharacters(in: .whitespaces)),
               let sy = Double(startCoords[1].trimmingCharacters(in: .whitespaces)),
               let ex = Double(endCoords[0].trimmingCharacters(in: .whitespaces)),
               let ey = Double(endCoords[1].trimmingCharacters(in: .whitespaces)) {
                let startPoint = isRelative ? CGPoint(x: currentLoc.x + sx, y: currentLoc.y + sy) : CGPoint(x: sx, y: sy)
                let endPoint = isRelative ? CGPoint(x: startPoint.x + ex, y: startPoint.y + ey) : CGPoint(x: ex, y: ey)
                await context.simulateDrag(from: startPoint, to: endPoint)
            } else {
                return .failure
            }
        } else if ["leftClick", "rightClick", "doubleClick", "move"].contains(type) {
            let coords = val1.split(separator: ",")
            if coords.count == 2, let x = Double(coords[0].trimmingCharacters(in: .whitespaces)), let y = Double(coords[1].trimmingCharacters(in: .whitespaces)) {
                let targetPoint = isRelative ? CGPoint(x: currentLoc.x + x, y: currentLoc.y + y) : CGPoint(x: x, y: y)
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

// MARK: - 系统消息弹窗执行器
/// 提供后台静默横幅，或者前端阻断式的交互提醒窗口
struct ShowNotificationExecutor: RPAActionExecutor {
    func execute(action: RPAAction, context: WorkflowEngine) async -> ConnectionCondition {
        let parsedParam = context.parseVariables(action.parameter)
        let parts = parsedParam.components(separatedBy: "|")
        
        let isOldFormat = parts.count == 1 && !action.parameter.contains("|")
        
        let title = isOldFormat ? "RPA 提醒" : (parts.count > 0 ? parts[0] : "RPA 提醒")
        let body = isOldFormat ? parsedParam : (parts.count > 1 ? parts[1] : "")
        let notifyType = parts.count > 2 ? parts[2] : "banner"
        let playSound = parts.count > 3 ? (parts[3] == "true") : true
        
        // [✨核心优化] 防注入与多行换行符处理
        let safeTitle = title.replacingOccurrences(of: "\"", with: "\\\"")
        
        // 对于 AppleScript，如果直接注入 \n 会导致脚本多行截断报错。
        let safeBodyForAppleScript = body
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\" & return & \"")
        
        if notifyType == "alert" {
            await MainActor.run {
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = title
                alert.informativeText = body // NSAlert 原生支持 \n 换行，无需特殊处理
                alert.alertStyle = .informational
                alert.addButton(withTitle: "确定")
                
                if playSound { NSSound.beep() }
                alert.runModal()
            }
            context.log("💬 [弹窗确认] 用户已阅: \(title)")
        } else {
            // 使用安全处理过多行字符的字符串注入 AppleScript
            var scriptSource = "display notification \"\(safeBodyForAppleScript)\" with title \"\(safeTitle)\""
            if playSound {
                scriptSource += " sound name \"Glass\""
            }
            
            if let script = NSAppleScript(source: scriptSource) {
                var error: NSDictionary?
                script.executeAndReturnError(&error)
                
                if let err = error {
                    context.log("⚠️ 横幅通知发送受阻: \(err)")
                } else {
                    // 为了日志整洁，把换行符替换为空格输出到日志
                    let logBody = body.replacingOccurrences(of: "\n", with: " ")
                    context.log("💬 [横幅通知] \(title) - \(logBody)")
                }
            }
        }
        
        return .always
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

