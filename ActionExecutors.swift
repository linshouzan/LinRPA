//////////////////////////////////////////////////////////////////
// 文件名：ActionExecutors.swift
// 文件说明：RPA动作执行器集合，采用策略模式解耦执行逻辑
// 功能说明：
// 代码要求：没有要求修改不用输出代码，请保证代码的逻辑和完整性，保留代码中的所有注释内容
//////////////////////////////////////////////////////////////////

import Foundation
import AppKit

// MARK: - 执行器协议
protocol RPAActionExecutor {
    /// 执行具体的 Action
    /// - Parameters:
    ///   - action: 当前动作配置
    ///   - context: 引擎上下文（用于读写变量、调用基础能力等）
    /// - Returns: 执行后的分支条件
    func execute(action: RPAAction, context: WorkflowEngine) async -> ConnectionCondition
}

// MARK: - 执行器工厂
struct ActionExecutorFactory {
    static func getExecutor(for type: ActionType) -> RPAActionExecutor {
        switch type {
        case .webAgent: return WebAgentExecutor()
        case .uiInteraction: return UIInteractionExecutor()
        case .setVariable: return SetVariableExecutor()
        case .httpRequest: return HTTPRequestExecutor()
        case .aiVision: return AIVisionExecutor()
        case .openApp: return OpenAppExecutor()
        case .openURL: return OpenURLExecutor()
        case .typeText: return TypeTextExecutor()
        case .wait: return WaitExecutor()
        case .condition: return ConditionExecutor()
        case .showNotification: return ShowNotificationExecutor()
        case .ocrText: return OCRTextExecutor()
        case .mouseOperation: return MouseOperationExecutor()
        case .writeClipboard: return WriteClipboardExecutor()
        case .readClipboard: return ReadClipboardExecutor()
        case .runShell: return RunShellExecutor()
        case .runAppleScript: return RunAppleScriptExecutor()
        case .callWorkflow: return CallWorkflowExecutor()
        }
    }
}

// MARK: - 具体组件执行器实现

struct UIInteractionExecutor: RPAActionExecutor {
    func execute(action: RPAAction, context: WorkflowEngine) async -> ConnectionCondition {
        let parsedParam = context.parseVariables(action.parameter)
        let parts = parsedParam.components(separatedBy: "|")
        guard parts.count >= 4 else { return .failure }
        
        let targetApp = parts[0]
        let targetRole = parts[1]
        let targetTitle = parts[2]
        let actType = parts[3]
        let matchMode = parts.count > 4 ? parts[4] : "exact"
        let targetIndexStr = parts.count > 5 ? parts[5] : "-1"
        let targetIndex = Int(targetIndexStr) ?? -1
        
        context.log("🔍 寻找 [\(targetApp)] 元素 (Role:[\(targetRole.isEmpty ? "不限" : targetRole)], 模式:\(matchMode), 索引:\(targetIndex))...")
        
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == targetApp }) else {
            context.log("❌ 未找到运行中的应用: \(targetApp)")
            return .failure
        }
        
        app.activate(options: .activateIgnoringOtherApps)
        try? await Task.sleep(for: .milliseconds(300))
        
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var startElement = appElement
        var mainWindowRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXMainWindowAttribute as CFString, &mainWindowRef) == .success,
           let mainWindow = mainWindowRef {
            startElement = mainWindow as! AXUIElement
            context.log("🎯 已锁定主窗口，开始深层递归扫描...")
        }
        
        struct MatchedUIElement { let element: AXUIElement; let rect: CGRect; let role: String; let title: String }
        var allMatches: [MatchedUIElement] = []
        
        func extractComprehensiveTitle(from element: AXUIElement, depth: Int = 0) -> String {
            if depth > 3 { return "" }
            var valRef: CFTypeRef?
            for attr in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXHelpAttribute] {
                if AXUIElementCopyAttributeValue(element, attr as CFString, &valRef) == .success,
                   let str = valRef as? String, !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return str }
            }
            var childrenRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success, let children = childrenRef as? [AXUIElement] {
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
        
        func collectElementsDFS(in element: AXUIElement, roleToFind: String, titleToFind: String, currentDepth: Int) {
            if currentDepth > 20 { return }
            var childrenRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success, let children = childrenRef as? [AXUIElement] {
                for child in children {
                    var roleVal: CFTypeRef?; AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleVal)
                    let r = roleVal as? String ?? ""
                    let t = extractComprehensiveTitle(from: child)
                    let roleMatches = roleToFind.isEmpty || r == roleToFind
                    var titleMatches = false
                    
                    if titleToFind.isEmpty { titleMatches = true }
                    else if matchMode == "exact" { titleMatches = (t == titleToFind) }
                    else if matchMode == "contains" { titleMatches = t.localizedCaseInsensitiveContains(titleToFind) }
                    else if matchMode == "regex" { titleMatches = (t.range(of: titleToFind, options: [.regularExpression, .caseInsensitive]) != nil) }
                    
                    if roleMatches && titleMatches && !t.isEmpty {
                        var posRef: CFTypeRef?; var sizeRef: CFTypeRef?; var position = CGPoint.zero; var size = CGSize.zero
                        if AXUIElementCopyAttributeValue(child, kAXPositionAttribute as CFString, &posRef) == .success, let pVal = posRef, CFGetTypeID(pVal) == AXValueGetTypeID() { AXValueGetValue(pVal as! AXValue, .cgPoint, &position) }
                        if AXUIElementCopyAttributeValue(child, kAXSizeAttribute as CFString, &sizeRef) == .success, let sVal = sizeRef, CFGetTypeID(sVal) == AXValueGetTypeID() { AXValueGetValue(sVal as! AXValue, .cgSize, &size) }
                        if size.width > 0 && size.height > 0 {
                            allMatches.append(MatchedUIElement(element: child, rect: CGRect(origin: position, size: size), role: r, title: t))
                            context.log("   ↳ 命中: 尺寸=(\(Int(size.width))x\(Int(size.height))), Role=[\(r)], Title=[\(t)]")
                        }
                    }
                    collectElementsDFS(in: child, roleToFind: roleToFind, titleToFind: titleToFind, currentDepth: currentDepth + 1)
                }
            }
        }
        
        collectElementsDFS(in: startElement, roleToFind: targetRole, titleToFind: targetTitle, currentDepth: 0)
        if allMatches.isEmpty { context.log("❌ 未找到任何符合条件的元素。"); return .failure }
        
        var validMatches = allMatches.filter { $0.rect.height < 150 }
        validMatches.sort { a, b in abs(a.rect.minY - b.rect.minY) > 10 ? a.rect.minY < b.rect.minY : a.rect.minX < b.rect.minX }
        
        if validMatches.isEmpty { return .failure }
        let finalTarget: MatchedUIElement
        if targetIndex == -1 { finalTarget = validMatches[0] }
        else if targetIndex >= 0 && targetIndex < validMatches.count { finalTarget = validMatches[targetIndex] }
        else { context.log("❌ 填写的序号(Index: \(targetIndex)) 越界！"); return .failure }
        
        context.log("🎯 锁定最终元素 [序号 \(targetIndex)] -> Role: \(finalTarget.role)")
        
        if actType == "click" {
            AXUIElementPerformAction(finalTarget.element, kAXPressAction as CFString)
            let clickX = finalTarget.rect.minX + 20; let clickY = finalTarget.rect.midY
            context.log("🖱️ 执行物理点击，坐标: (\(Int(clickX)), \(Int(clickY)))")
            await context.simulateMouseOperation(type: "leftClick", at: CGPoint(x: clickX, y: clickY))
            CGWarpMouseCursorPosition(CGPoint(x: finalTarget.rect.maxX + 50, y: finalTarget.rect.maxY + 50))
        } else if actType == "read" {
            context.variables["ui_text"] = finalTarget.title
            context.log("📖 读取文本: \(context.variables["ui_text"]!)")
        }
        return .success
    }
}

struct SetVariableExecutor: RPAActionExecutor {
    func execute(action: RPAAction, context: WorkflowEngine) async -> ConnectionCondition {
        let parts = context.parseVariables(action.parameter).components(separatedBy: "|")
        if parts.count >= 2 {
            let key = parts[0].trimmingCharacters(in: .whitespaces); let val = parts[1]
            context.variables[key] = val
            context.log("🗂️ 设置变量: [\(key)] = \(val)")
        }
        return .always
    }
}

struct HTTPRequestExecutor: RPAActionExecutor {
    func execute(action: RPAAction, context: WorkflowEngine) async -> ConnectionCondition {
        let parts = context.parseVariables(action.parameter).components(separatedBy: "|")
        let urlStr = parts.count > 0 ? parts[0] : ""; let method = parts.count > 1 ? parts[1] : "GET"
        if let url = URL(string: urlStr) {
            var req = URLRequest(url: url); req.httpMethod = method
            if let (data, resp) = try? await URLSession.shared.data(for: req), let response = resp as? HTTPURLResponse {
                if let str = String(data: data, encoding: .utf8) { context.variables["http_response"] = str }
                context.variables["http_status"] = "\(response.statusCode)"
                context.log("🌐 HTTP \(method) 完成: 状态码 \(response.statusCode)")
                return .success
            }
        }
        context.log("❌ HTTP 请求失败或无效 URL"); return .failure
    }
}

struct OCRTextExecutor: RPAActionExecutor {
    func execute(action: RPAAction, context: WorkflowEngine) async -> ConnectionCondition {
        let parsedParam = context.parseVariables(action.parameter)
        let parts = parsedParam.components(separatedBy: "|")
        let targetText = parts.count > 0 ? parts[0] : parsedParam
        let shouldClick = parts.count > 1 ? (parts[1] == "true") : true
        let regionStr = parts.count > 2 ? parts[2] : ""
        var regionRect: CGRect? = nil
        
        if !regionStr.isEmpty {
            let coords = regionStr.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if coords.count == 4 { regionRect = CGRect(x: coords[0], y: coords[1], width: coords[2], height: coords[3]) }
        }
        context.log("📸 OCR 寻找: '\(targetText)'")
        if let point = await context.findTextOnScreen(text: targetText, sampleBase64: action.sampleImageBase64, region: regionRect) {
            let finalPoint = CGPoint(x: point.x + action.offsetX, y: point.y + action.offsetY)
            context.log("🎯 找到落点: (\(Int(finalPoint.x)), \(Int(finalPoint.y)))")
            if shouldClick { await context.simulateMouseOperation(type: "leftClick", at: finalPoint) }
            return .success
        }
        return .failure
    }
}

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
            let startCoords = val1.split(separator: ","); let endCoords = val2.split(separator: ",")
            if startCoords.count == 2, endCoords.count == 2, let sx = Double(startCoords[0].trimmingCharacters(in: .whitespaces)), let sy = Double(startCoords[1].trimmingCharacters(in: .whitespaces)), let ex = Double(endCoords[0].trimmingCharacters(in: .whitespaces)), let ey = Double(endCoords[1].trimmingCharacters(in: .whitespaces)) {
                let startPoint = isRelative ? CGPoint(x: currentLoc.x + sx, y: currentLoc.y + sy) : CGPoint(x: sx, y: sy)
                let endPoint = isRelative ? CGPoint(x: startPoint.x + ex, y: startPoint.y + ey) : CGPoint(x: ex, y: ey)
                await context.simulateDrag(from: startPoint, to: endPoint)
            } else { return .failure }
        } else if ["leftClick", "rightClick", "doubleClick", "move"].contains(type) {
            let coords = val1.split(separator: ",")
            if coords.count == 2, let x = Double(coords[0].trimmingCharacters(in: .whitespaces)), let y = Double(coords[1].trimmingCharacters(in: .whitespaces)) {
                let targetPoint = isRelative ? CGPoint(x: currentLoc.x + x, y: currentLoc.y + y) : CGPoint(x: x, y: y)
                await context.simulateMouseOperation(type: type, at: targetPoint)
            } else { return .failure }
        } else if type.lowercased().contains("scroll") {
            let amount = Int(val1.trimmingCharacters(in: .whitespaces)) ?? 1
            await context.simulateScroll(type: type, amount: amount)
        }
        return .always
    }
}

struct OpenAppExecutor: RPAActionExecutor {
    func execute(action: RPAAction, context: WorkflowEngine) async -> ConnectionCondition {
        let parts = context.parseVariables(action.parameter).components(separatedBy: "|")
        let appName = parts.count > 0 ? (parts[0].isEmpty ? "Safari" : parts[0]) : "Safari"
        let silent = parts.count > 1 ? (parts[1] == "true") : false
        
        let task = Process()
        task.launchPath = "/usr/bin/open"
        // [✨核心优化] -g 参数控制静默唤起
        if silent {
            task.arguments = ["-g", "-a", appName]
        } else {
            task.arguments = ["-a", appName]
        }
        try? task.run()
        
        if !silent {
            let script = "tell application \"\(appName)\" to activate"
            var errorInfo: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&errorInfo)
            context.log("📂 激活并前置应用: \(appName)")
            try? await Task.sleep(for: .seconds(1.5))
        } else {
            context.log("🥷 静默唤起应用 (后台): \(appName)")
            try? await Task.sleep(for: .seconds(0.5)) // 静默启动不需要那么长的强制缓冲
        }
        
        return .always
    }
}

struct OpenURLExecutor: RPAActionExecutor {
    func execute(action: RPAAction, context: WorkflowEngine) async -> ConnectionCondition {
        let parts = context.parseVariables(action.parameter).components(separatedBy: "|")
        let urlStr = parts.count > 0 ? parts[0] : parts.joined()
        let browser = parts.count > 1 ? parts[1] : "InternalBrowser"
        let silent = parts.count > 2 ? (parts[2] == "true") : false
        
        guard let encodedURLString = urlStr.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: encodedURLString) else {
            context.log("❌ 无效的 URL 格式")
            return .failure
        }
        
        if browser == "InternalBrowser" {
            await MainActor.run {
                if !silent { BrowserWindowController.showSharedWindow() }
                // makeActive 决定了 Tab 是否抢焦点
                BrowserViewModel.shared.addNewTab(request: URLRequest(url: url), makeActive: !silent)
            }
            context.log("🌐 [内置浏览器] \(silent ? "🥷静默" : "")打开网址: \(urlStr)")
            try? await Task.sleep(for: .seconds(silent ? 0.5 : 1.5))
            
        } else if browser == "System" {
            // [✨修复] 使用 Process 执行底层命令代替会抛出异常的 NSWorkspace，更加稳定
            let task = Process()
            task.launchPath = "/usr/bin/open"
            if silent {
                task.arguments = ["-g", url.absoluteString] // -g 参数保证后台静默不抢焦点
            } else {
                task.arguments = [url.absoluteString]
            }
            try? task.run()
            
            context.log("🌐 [系统默认浏览器] \(silent ? "🥷静默" : "")打开网址: \(urlStr)")
            try? await Task.sleep(for: .seconds(1.0))
            
        } else {
            let task = Process()
            task.launchPath = "/usr/bin/open"
            if silent {
                task.arguments = ["-g", "-a", browser, url.absoluteString]
            } else {
                task.arguments = ["-a", browser, url.absoluteString]
            }
            do {
                try task.run()
                context.log("🌐 [\(browser)] \(silent ? "🥷静默" : "")打开网址: \(urlStr)")
                try? await Task.sleep(for: .seconds(1.5))
            } catch {
                return .failure
            }
        }
        return .always
    }
}

struct TypeTextExecutor: RPAActionExecutor {
    func execute(action: RPAAction, context: WorkflowEngine) async -> ConnectionCondition {
        await context.simulateKeyboardInput(input: context.parseVariables(action.parameter))
        return .always
    }
}

struct WaitExecutor: RPAActionExecutor {
    func execute(action: RPAAction, context: WorkflowEngine) async -> ConnectionCondition {
        let sec = Double(context.parseVariables(action.parameter)) ?? 1.0; try? await Task.sleep(for: .seconds(sec))
        return .always
    }
}

struct ConditionExecutor: RPAActionExecutor {
    func execute(action: RPAAction, context: WorkflowEngine) async -> ConnectionCondition {
        let parts = context.parseVariables(action.parameter).components(separatedBy: "|")
        if parts.count >= 3 {
            let leftValue = parts[0]; let op = parts[1]; let rightValue = parts[2]
            var isMatched = false
            if op == "==" { isMatched = (leftValue == rightValue) }
            else if op == "contains" { isMatched = leftValue.contains(rightValue) }
            context.log("⚖️ 判断: '\(leftValue)' \(op) '\(rightValue)' -> \(isMatched)")
            return isMatched ? .success : .failure
        }
        return .failure
    }
}

struct ShowNotificationExecutor: RPAActionExecutor {
    func execute(action: RPAAction, context: WorkflowEngine) async -> ConnectionCondition {
        let parts = context.parseVariables(action.parameter).components(separatedBy: "|")
        let style = parts.count > 0 ? parts[0] : "banner"
        let title = parts.count > 1 ? parts[1].replacingOccurrences(of: "\"", with: "\\\"") : "提醒"
        let body = parts.count > 2 ? parts[2].replacingOccurrences(of: "\"", with: "\\\"") : ""
        if style == "dialog" {
            context.log("💬 阻断对话框: \(title)")
            let script = "display dialog \"\(body)\" with title \"\(title)\" buttons {\"确认\"} default button \"确认\""
            var err: NSDictionary?; NSAppleScript(source: script)?.executeAndReturnError(&err)
        } else {
            let script = "display notification \"\(body)\" with title \"\(title)\""
            var err: NSDictionary?; NSAppleScript(source: script)?.executeAndReturnError(&err)
            context.log("🔔 通知横幅: \(title)")
        }
        return .always
    }
}

struct WriteClipboardExecutor: RPAActionExecutor {
    func execute(action: RPAAction, context: WorkflowEngine) async -> ConnectionCondition {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(context.parseVariables(action.parameter), forType: .string)
        return .always
    }
}

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

struct RunShellExecutor: RPAActionExecutor {
    func execute(action: RPAAction, context: WorkflowEngine) async -> ConnectionCondition {
        let task = Process(); task.launchPath = "/bin/bash"; task.arguments = ["-c", context.parseVariables(action.parameter)]
        let pipe = Pipe(); task.standardOutput = pipe; try? task.run(); task.waitUntilExit()
        if let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8), !output.isEmpty {
            context.log("💻 Shell 输出:\n\(output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return .always
    }
}

struct RunAppleScriptExecutor: RPAActionExecutor {
    func execute(action: RPAAction, context: WorkflowEngine) async -> ConnectionCondition {
        var err: NSDictionary?
        if let scriptObj = NSAppleScript(source: context.parseVariables(action.parameter)) {
            scriptObj.executeAndReturnError(&err)
            if let e = err { context.log("❌ AS 错误: \(e)") } else { context.log("✅ AS 执行完成") }
        }
        return .always
    }
}

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

// MARK: - 重构的 Web 智能体 4.0 执行器 (支持多步规划与 Hover)
struct WebAgentExecutor: RPAActionExecutor {
    func execute(action: RPAAction, context: WorkflowEngine) async -> ConnectionCondition {
        let params = WebAgentParams.parse(from: action.parameter)
        // [原逻辑保留] 解析参数
        let parts = action.parameter.split(separator: "|", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
        let taskDesc = parts.count > 0 ? parts[0] : ""
        let browser = parts.count > 1 ? parts[1] : "InternalBrowser"
        let requireConfirm = parts.count > 2 ? (parts[2] == "true") : true
        let manualText = parts.count > 3 ? parts[3] : ""
        let captureMode = parts.count > 4 ? parts[4] : "app"
        
        context.log("🌟 [WebAgent 4.0] 准备接管 [\(browser == "InternalBrowser" ? "内置浏览器" : "Safari")]...")
        context.log("🔍 正在检查并唤醒目标浏览器窗口...")
        await context.activateBrowser(browser)
        
        let maxSteps = 10
        var currentStep = 0
        var isTaskCompleted = false
        var actionHistory: [String] = []
        
        // [原逻辑保留] 最大步数与运行状态断言
        while currentStep < maxSteps && !isTaskCompleted && context.isRunning {
            currentStep += 1
            context.log("🔄 [WebAgent] 第 \(currentStep) 轮感知与决策...")
            
            // 1. 获取 DOM
            let domContext = await context.injectSoMAndGetDOM(browser: browser)
            if domContext.contains("Error") {
                context.log("❌ [WebAgent] 获取网页结构失败: \(domContext)")
                return .failure
            }
            
            // [✨ 感知探针：同步 DOM 数据]
            await MainActor.run {
                AgentMonitorManager.shared.domSummary = domContext
                AgentMonitorManager.shared.isProcessing = true
                AgentMonitorManager.shared.llmThought = "获取视野中..."
                AgentMonitorManager.shared.plannedSteps.removeAll()
            }
            
            try? await Task.sleep(for: .milliseconds(300))
            
            // 2. 截屏
            let targetCaptureApp: String?
            if captureMode == "fullscreen" {
                targetCaptureApp = nil
                context.log("📸 [WebAgent] 当前配置为：全屏截取视野")
            } else {
                targetCaptureApp = browser == "InternalBrowser" ? ProcessInfo.processInfo.processName : browser
                context.log("📸 [WebAgent] 当前配置为：仅截取 [\(targetCaptureApp!)] 程序层")
            }
            
            guard let screenCGImage = try? await ScreenCaptureUtility.captureScreen(forAppName: targetCaptureApp) else {
                context.log("❌ [WebAgent] 截屏失败，请检查屏幕录制权限或窗口是否存活。")
                return .failure
            }
            
            // [✨ 感知探针：同步视觉截图]
            await MainActor.run {
                AgentMonitorManager.shared.currentVision = NSImage(cgImage: screenCGImage, size: .zero)
                AgentMonitorManager.shared.llmThought = "等待大模型多模态推理..."
            }
            
            // 3. 清理屏幕上的红框，防止污染后续真实操作
            await context.cleanupSoM(browser: browser)
            
            let historyStr = actionHistory.isEmpty ? "无" : actionHistory.enumerated().map{ "\($0.offset+1). \($0.element)" }.joined(separator: "\n")

            // [✨ 核心引擎重构] 模板渲染：替换用户 Prompt 模板中的占位符
            let finalPrompt = params.promptTemplate
                .replacingOccurrences(of: "{{TaskDesc}}", with: taskDesc)
                .replacingOccurrences(of: "{{Manual}}", with: manualText.isEmpty ? "无" : manualText)
                .replacingOccurrences(of: "{{History}}", with: historyStr)
                .replacingOccurrences(of: "{{DOM}}", with: domContext)
            
            context.log("🧠 [WebAgent] 大脑运转中 (图文多模态推理)...")
            context.log("🌊 正在思考: ")
            do {
                let nsImage = NSImage(cgImage: screenCGImage, size: .zero)
                let message = LLMMessage(role: .user, text: finalPrompt, images: [nsImage])
                let stream = LLMService.shared.stream(messages: [message])
                
                var aiResponse = ""
                var chunkBuffer = ""
                var lastReportTime = CFAbsoluteTimeGetCurrent()
                
                // [✨ 感知探针：实时同步思维流]
                for try await chunk in stream {
                    guard context.isRunning else { break }
                    aiResponse += chunk
                    await MainActor.run {
                        AgentMonitorManager.shared.llmThought = aiResponse
                    }
                }
                
                // [原逻辑保留] 实时流式输出与紧急停止断言
                for try await chunk in stream {
                    guard context.isRunning else {
                        await MainActor.run { context.log("\n🛑 流程已终止，WebAgent 大脑已掉线。") }
                        break
                    }
                    
                    aiResponse += chunk
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
                
                // [✨4.0 核心升级] 解析 steps 数组
                guard let jsonStr = extractJSON(from: aiResponse),
                      let jsonData = jsonStr.data(using: .utf8),
                      let plan = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                      let steps = plan["steps"] as? [[String: Any]] else {
                    context.log("\n⚠️ [WebAgent] JSON 格式异常(未找到 steps 数组)，重试。")
                    actionHistory.append("上一步模型输出格式错误，请严格输出包含 steps 数组的 JSON。")
                    continue
                }
                
                let thought = plan["thought"] as? String ?? ""
                context.log("\n💡 整体规划: \(thought)")
                
                // 汇总即将执行的批量动作，用于人机确认 (HITL)
                var stepDescriptions: [String] = []
                for (idx, step) in steps.enumerated() {
                    let aType = step["action_type"] as? String ?? "fail"
                    let tId = step["target_id"] as? String ?? ""
                    let val = step["input_value"] as? String ?? ""
                    stepDescriptions.append("  步骤 \(idx + 1): [\(aType)] ID:\(tId) \(val.isEmpty ? "" : "输入:\(val)")")
                }
                
                // [原逻辑保留] 拦截器：Human-in-the-loop 人工确认
                if requireConfirm {
                    let confirmMsg = "Agent 准备执行以下序列:\n" + stepDescriptions.joined(separator: "\n") + "\n\n思考: \(thought)"
                    if !(await context.requestUserConfirmation(title: "Agent 批量请求操作", message: confirmMsg)) {
                        context.log("🛑 用户终止操作。")
                        return .failure
                    }
                }
                
                // [✨ 感知探针：解析并展示动作序列]
                for (idx, step) in steps.enumerated() {
                    let aType = step["action_type"] as? String ?? "fail"
                    let tId = step["target_id"] as? String ?? ""
                    let val = step["input_value"] as? String ?? ""
                    stepDescriptions.append("[\(aType)] Target:\(tId) \(val)")
                }
                await MainActor.run {
                    AgentMonitorManager.shared.plannedSteps = stepDescriptions
                    AgentMonitorManager.shared.isProcessing = false
                }
                
                // [✨4.0 核心升级] 顺序执行解析出的多个步骤
                for step in steps {
                    guard context.isRunning else { break }
                    
                    let actionType = step["action_type"] as? String ?? "fail"
                    let targetId = step["target_id"] as? String ?? ""
                    let inputValue = step["input_value"] as? String ?? ""
                    
                    if actionType == "finish" {
                        context.log("✅ [WebAgent] 自主判断任务完成！")
                        isTaskCompleted = true
                        break
                    } else if actionType == "fail" {
                        context.log("🛑 [WebAgent] 主动请求人工介入。")
                        return .failure
                    }
                    
                    actionHistory.append("[\(actionType)] 目标ID:\(targetId) 输入:\(inputValue)")
                    
                    // ✨ 核心分支：判断 AI 选择的是物理魔法还是 JS 魔法
                    if actionType.hasPrefix("native_") {
                        context.log("🦾 [物理降维打击] 激活原生键鼠: \(actionType) -> [\(targetId)]")
                        
                        let isNativeSuccess = await context.executeNativeAction(browser: browser, action: actionType, targetId: targetId, value: inputValue)
                        
                        // 优雅降级：如果因为某些跨域 iframe 导致算不出物理坐标，回退到 JS 模式
                        if !isNativeSuccess {
                            context.log("⚠️ 物理坐标计算失败，自动降级为无头 JS 注入模式")
                            let fallbackAction = actionType.replacingOccurrences(of: "native_", with: "")
                            await context.injectActionJS(browser: browser, action: fallbackAction, targetId: targetId, value: inputValue)
                        }
                    } else {
                        // 默认执行快速且静默的 JS 注入
                        context.log("⚙️ [JS静默执行]: \(actionType) -> [\(targetId)] \(inputValue.isEmpty ? "" : "写入: \(inputValue)")")
                        await context.injectActionJS(browser: browser, action: actionType, targetId: targetId, value: inputValue)
                    }
                    
                    // 动作间的微小停顿，给予前端重绘时间
                    try? await Task.sleep(for: .milliseconds(800))
                }
                
                // [原逻辑保留] 当前批次执行完毕后，等待页面稳定，进入下一次全屏抓取决策
                await context.waitForPageToStabilize(browser: browser)
                
            } catch {
                context.log("❌ [WebAgent] 推理失败: \(error.localizedDescription)")
                return .failure
            }
        }
        
        return isTaskCompleted ? .success : .failure
    }
    
    // [原逻辑保留] 提取 JSON 字符串
    private func extractJSON(from text: String) -> String? {
        let pattern = "\\{(?:[^{}]|(?:\\{[^{}]*\\}))*\\}"
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) {
            let nsString = text as NSString
            let results = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsString.length))
            if let firstMatch = results.first { return nsString.substring(with: firstMatch.range) }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
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

