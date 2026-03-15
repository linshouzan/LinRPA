//////////////////////////////////////////////////////////////////
// 文件名：ActionExecutors.swift
// 文件说明：RPA动作执行器集合，采用策略模式解耦执行逻辑
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

// MARK: - [✨优化] Web 智能体 3.0 执行器 (支持批处理合并确认与静默运行)
struct WebAgentExecutor: RPAActionExecutor {
    func execute(action: RPAAction, context: WorkflowEngine) async -> ConnectionCondition {
        let parts = action.parameter.split(separator: "|", maxSplits: 6, omittingEmptySubsequences: false).map(String.init)
        let taskDesc = parts.count > 0 ? parts[0] : ""
        let browser = parts.count > 1 ? (parts[1].isEmpty ? "InternalBrowser" : parts[1]) : "InternalBrowser"
        let requireConfirm = parts.count > 2 ? (parts[2] == "true") : true
        let manualText = parts.count > 3 ? parts[3] : ""
        let captureMode = parts.count > 4 ? parts[4] : "app"
        let successKeywords = parts.count > 5 ? parts[5] : ""
        let silentMode = parts.count > 6 ? (parts[6] == "true") : false
        
        context.log("🌟 [WebAgent 3.0] 准备接管 [\(browser == "InternalBrowser" ? "内置浏览器" : "Safari")]...")
        
        if !silentMode || captureMode == "fullscreen" {
            if silentMode && captureMode == "fullscreen" {
                context.log("⚠️ 检测到全屏视觉模式，强制关闭静默运行，正在唤醒窗口...")
            } else {
                context.log("🔍 正在唤醒目标浏览器窗口至最前...")
            }
            await context.activateBrowser(browser)
        } else {
            context.log("🥷 [静默模式] 已开启。Agent 将在后台遮挡状态下感知与操作。")
            if browser == "InternalBrowser" {
                await MainActor.run {
                    if BrowserViewModel.shared.tabs.isEmpty {
                        BrowserWindowController.showSharedWindow()
                        BrowserViewModel.shared.addNewTab()
                    }
                }
            }
        }
        
        let maxSteps = 10
        var currentStep = 0
        var isTaskCompleted = false
        var actionHistory: [String] = []
        
        while currentStep < maxSteps && !isTaskCompleted && context.isRunning {
            currentStep += 1
            context.log("🔄 [WebAgent] 第 \(currentStep) 轮感知与决策...")
            
            let domContext = await context.injectSoMAndGetDOM(browser: browser)
            if domContext.contains("Error") {
                context.log("❌ [WebAgent] 获取网页结构失败: \(domContext)")
                return .failure
            }
            
            try? await Task.sleep(for: .milliseconds(300))
            
            let targetCaptureApp: String? = captureMode == "fullscreen" ? nil : (browser == "InternalBrowser" ? ProcessInfo.processInfo.processName : browser)
            
            guard let screenCGImage = try? await ScreenCaptureUtility.captureScreen(forAppName: targetCaptureApp) else {
                context.log("❌ [WebAgent] 截屏失败，请检查状态。")
                return .failure
            }
            await context.cleanupSoM(browser: browser)
            
            let historyStr = actionHistory.isEmpty ? "无" : actionHistory.enumerated().map{ "\($0.offset+1). \($0.element)" }.joined(separator: "\n")

            let prompt = """
            你是一个顶级 Web RPA 机器人。结合给定的【屏幕截图】和【DOM列表】，决定接下来的动作。
            注意：截图中可交互元素已被打上红色数字方框，请通过图片找到正确元素，并参考DOM列表提取目标ID。
            
            【任务目标】: \(taskDesc)
            【操作手册】: \(manualText.isEmpty ? "无" : manualText)
            【历史操作记录】:
            \(historyStr)
            【当前可见元素 (ID与截图红框对应)】:
            \(domContext)
            
            【可选动作空间】:
            - click: 点击目标ID
            - input: 在目标ID输入文字
            - scroll_down: 页面向下滚动
            - scroll_up: 页面向上滚动
            - finish: 任务已成功完成
            - fail: 任务无法完成，请求人类接管
            
            【指令要求】:
            你可以一次性输出多个动作以加快执行效率（例如：连续输入用户名和密码）。
            请严格输出合法的 JSON 数组（Array）。如果某个动作会导致页面跳转、刷新或弹窗，请务必将其作为数组的最后一个动作！
            """
            
            context.log("🧠 [WebAgent] 大脑运转中...")
            context.log("🌊 正在思考: ")
            do {
                let nsImage = NSImage(cgImage: screenCGImage, size: .zero)
                let message = LLMMessage(role: .user, text: prompt, images: [nsImage])
                let stream = LLMService.shared.stream(messages: [message])
                
                var aiResponse = ""
                var chunkBuffer = ""
                var lastReportTime = CFAbsoluteTimeGetCurrent()
                
                for try await chunk in stream {
                    guard context.isRunning else { break }
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
                if !chunkBuffer.isEmpty { await MainActor.run { context.appendLogChunk(chunkBuffer) } }
                
                guard let jsonStr = extractJSON(from: aiResponse), let jsonData = jsonStr.data(using: .utf8) else {
                    context.log("\n⚠️ [WebAgent] JSON 格式异常，重试。")
                    actionHistory.append("模型输出格式错误，请严格输出 JSON 数组。")
                    continue
                }
                
                var actionPlans: [[String: Any]] = []
                if let array = try? JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]] {
                    actionPlans = array
                } else if let dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                    actionPlans = [dict]
                } else { continue }
                
                // [✨核心优化] 批处理汇总人工确认：只弹一次窗！
                if requireConfirm && !actionPlans.isEmpty {
                    var summaryMsg = "AI 规划了以下 \(actionPlans.count) 个连续动作：\n\n"
                    for (i, plan) in actionPlans.enumerated() {
                        let aType = plan["action_type"] as? String ?? ""
                        let tId = plan["target_id"] as? String ?? ""
                        let iVal = plan["input_value"] as? String ?? ""
                        let thought = plan["thought"] as? String ?? ""
                        summaryMsg += "\(i + 1). [\(aType)] 目标:\(tId) \(iVal.isEmpty ? "" : "输入:'\(iVal)'")\n   ↳ 思考: \(thought)\n"
                    }
                    
                    if !(await context.requestUserConfirmation(title: "Agent 批量动作确认", message: summaryMsg)) {
                        context.log("🛑 用户终止了此批次动作的执行。")
                        return .failure
                    }
                }
                
                context.log("\n💡 收到 \(actionPlans.count) 个动作，开始批处理...")
                var didExecuteAnyAction = false
                var shouldBreakOuterLoop = false
                
                for (index, plan) in actionPlans.enumerated() {
                    guard context.isRunning else { break }
                    
                    let thought = plan["thought"] as? String ?? ""
                    let actionType = plan["action_type"] as? String ?? "fail"
                    let targetId = plan["target_id"] as? String ?? ""
                    let inputValue = plan["input_value"] as? String ?? ""
                    
                    context.log("--- 动作 \(index + 1)/\(actionPlans.count) ---")
                    context.log("🤔 思考: \(thought)")
                    
                    if actionType == "finish" {
                        context.log("✅ [WebAgent] 自主判断任务完成！")
                        isTaskCompleted = true
                        shouldBreakOuterLoop = true
                        break
                    } else if actionType == "fail" {
                        context.log("🛑 [WebAgent] 主动请求人工介入。")
                        return .failure
                    }
                    
                    context.log("⚙️ 执行: \(actionType) -> [\(targetId)]")
                    actionHistory.append("[\(actionType)] 目标ID:\(targetId) 输入:\(inputValue)")
                    
                    await context.injectActionJS(browser: browser, action: actionType, targetId: targetId, value: inputValue)
                    didExecuteAnyAction = true
                    
                    try? await Task.sleep(for: .milliseconds(300))
                }
                
                if shouldBreakOuterLoop { break }
                
                if didExecuteAnyAction {
                    context.log("⏳ 批处理执行完毕，等待页面渲染响应...")
                    try? await Task.sleep(for: .seconds(1.5))
                    await context.waitForPageToStabilize(browser: browser)
                    
                    if !successKeywords.isEmpty {
                        let keywords = successKeywords.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        if !keywords.isEmpty {
                            let visibleText = await context.getPageText(browser: browser)
                            for kw in keywords {
                                if visibleText.contains(kw) {
                                    context.log("✅ [WebAgent] 断言命中 [\(kw)]，提前结束任务。")
                                    isTaskCompleted = true
                                    shouldBreakOuterLoop = true
                                    break
                                }
                            }
                        }
                    }
                }
                
                if shouldBreakOuterLoop { break }
                
            } catch {
                context.log("❌ [WebAgent] 推理失败: \(error.localizedDescription)")
                return .failure
            }
        }
        
        return isTaskCompleted ? .success : .failure
    }
    
    private func extractJSON(from text: String) -> String? {
        let pattern = "(?s)(\\{.*\\}|\\[.*\\])"
        if let regex = try? NSRegularExpression(pattern: pattern, options: []),
           let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: text.utf16.count)) {
            return (text as NSString).substring(with: match.range)
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

