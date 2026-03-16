//////////////////////////////////////////////////////////////////
// 文件名：ActionEditors.swift
// 文件说明：这是适用于 macos 14+ 的RPA组件配置编辑器与交互工具集合
// 功能说明：存放所有的组件配置弹窗、参数表单、MiniDesktop 和底层屏幕拾取器。
// 代码要求：保留了所有的极客级小组件和底层原生 UI 元素拾取防死锁逻辑。
//////////////////////////////////////////////////////////////////

import SwiftUI
import AppKit

struct ActionSettingsPopoverView: View {
    @Binding var action: RPAAction
    @Binding var showSettings: Bool
    var body: some View { VStack(alignment: .leading, spacing: 12) { HStack { Text("\(action.displayTitle)").font(.headline); Spacer(); Button("关闭") { showSettings = false } }; Divider(); actionParameterView() }.padding().frame(width: 460) }
    
    @ViewBuilder private func actionParameterView() -> some View {
        switch action.type {
        case .openURL:
            let parts = action.parameter.components(separatedBy: "|")
            let url = parts.count > 0 ? parts[0] : action.parameter
            let browser = parts.count > 1 ? parts[1] : "InternalBrowser"
            let silent = parts.count > 2 ? (parts[2] == "true") : false // [✨新增]
            
            VStack(alignment: .leading, spacing: 10) {
                TextField("网址 (例如: https://bing.com)", text: Binding(get: { url }, set: { action.parameter = "\($0)|\(browser)|\(silent ? "true" : "false")" }))
                    .textFieldStyle(.roundedBorder)
                
                HStack {
                    Text("目标浏览器:").font(.caption)
                    Picker("", selection: Binding(get: { browser }, set: { action.parameter = "\(url)|\($0)|\(silent ? "true" : "false")" })) {
                        Text("🚀 内置开发者浏览器").tag("InternalBrowser")
                        Text("系统默认浏览器").tag("System")
                        Text("Safari").tag("Safari")
                        Text("Google Chrome").tag("Google Chrome")
                    }.labelsHidden().frame(width: 160)
                }
                
                Toggle("🥷 后台静默运行 (不激活浏览器到最前)", isOn: Binding(get: { silent }, set: { action.parameter = "\(url)|\(browser)|\($0 ? "true" : "false")" }))
                    .toggleStyle(.switch).controlSize(.mini).tint(.blue)
            }
        case .openApp:
            let parts = action.parameter.components(separatedBy: "|")
            let appName = parts.count > 0 ? parts[0] : action.parameter
            let silent = parts.count > 1 ? (parts[1] == "true") : false // [✨新增]
            
            VStack(alignment: .leading, spacing: 10) {
                TextField("App 名称 (例如: Safari, Finder)", text: Binding(get: { appName }, set: { action.parameter = "\($0)|\(silent ? "true" : "false")" }))
                    .textFieldStyle(.roundedBorder)
                
                Toggle("🥷 后台静默运行 (不唤醒到前台)", isOn: Binding(get: { silent }, set: { action.parameter = "\(appName)|\($0 ? "true" : "false")" }))
                    .toggleStyle(.switch).controlSize(.mini).tint(.blue)
                Text("开启后会在后台启动程序，不打断您当前的工作。").font(.caption2).foregroundColor(.secondary)
            }
        case .webAgent: WebAgentEditor(action: $action)
        case .uiInteraction: // 原生 UI 自动化表单（支持模式和索引）
            let parts = action.parameter.components(separatedBy: "|")
            let targetApp = parts.count > 0 ? parts[0] : ""
            let targetRole = parts.count > 1 ? parts[1] : ""
            let targetTitle = parts.count > 2 ? parts[2] : ""
            let interactionType = parts.count > 3 ? parts[3] : "click"
            let matchMode = parts.count > 4 ? parts[4] : "exact"
            let targetIndex = parts.count > 5 ? parts[5] : "-1" // -1 代表不限
            
            let updateParam = { (app: String, role: String, title: String, type: String, mode: String, idx: String) in
                action.parameter = "\(app)|\(role)|\(title)|\(type)|\(mode)|\(idx)"
            }
            
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("目标 App:").font(.caption).frame(width: 60, alignment: .leading)
                    TextField("App 名称", text: Binding(get: { targetApp }, set: { updateParam($0, targetRole, targetTitle, interactionType, matchMode, targetIndex) })).textFieldStyle(.roundedBorder)
                    
                    Menu {
                        let runningApps = NSWorkspace.shared.runningApplications
                            .filter { $0.activationPolicy == .regular }
                            .compactMap { $0.localizedName }.sorted()
                        ForEach(runningApps, id: \.self) { appName in
                            Button(appName) { updateParam(appName, targetRole, targetTitle, interactionType, matchMode, targetIndex) }
                        }
                    } label: { Image(systemName: "list.bullet.rectangle.portrait") }.fixedSize().help("从当前运行的程序中选择")
                }
                
                HStack {
                    Text("元素 Role:").font(.caption).frame(width: 60, alignment: .leading)
                    TextField("元素角色(如 AXTabButton)", text: Binding(get: { targetRole }, set: { updateParam(targetApp, $0, targetTitle, interactionType, matchMode, targetIndex) })).textFieldStyle(.roundedBorder)
                }
                
                HStack {
                    Text("元素 Title:").font(.caption).frame(width: 60, alignment: .leading)
                    TextField("元素文本(可为空)", text: Binding(get: { targetTitle }, set: { updateParam(targetApp, targetRole, $0, interactionType, matchMode, targetIndex) })).textFieldStyle(.roundedBorder)
                }
                
                // 匹配规则与索引配置区
                HStack {
                    Text("匹配规则:").font(.caption).frame(width: 60, alignment: .leading)
                    Picker("", selection: Binding(get: { matchMode }, set: { updateParam(targetApp, targetRole, targetTitle, interactionType, $0, targetIndex) })) {
                        Text("精确等于").tag("exact")
                        Text("包含(Contains)").tag("contains")
                        Text("正则(Regex)").tag("regex")
                    }.labelsHidden().frame(width: 120)
                    
                    Spacer()
                    
                    Text("序号(Index):").font(.caption)
                    TextField("-1为不限", text: Binding(get: { targetIndex }, set: { updateParam(targetApp, targetRole, targetTitle, interactionType, matchMode, $0) }))
                        .textFieldStyle(.roundedBorder).frame(width: 60)
                        .help("0代表第1个，1代表第2个，-1代表不限制(命中即返回)")
                }
                
                Picker("执行操作", selection: Binding(get: { interactionType }, set: { updateParam(targetApp, targetRole, targetTitle, $0, matchMode, targetIndex) })) {
                    Text("左键点击 (Click)").tag("click")
                    Text("读取文本存入 {{ui_text}}").tag("read")
                }.pickerStyle(.segmented).padding(.vertical, 4)
                
                Button(action: {
                    // 定义启动拾取器的闭包
                    let startPicking = {
                        UIElementPicker.shared.pickElement { app, role, title in
                            updateParam(app, role, title, interactionType, matchMode, targetIndex)
                        }
                    }
                    
                    // 如果用户已经选择了目标 App，先将其强制激活到最前端
                    if !targetApp.isEmpty,
                       let appToActivate = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == targetApp }) {
                        appToActivate.activate(options: .activateIgnoringOtherApps)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            startPicking()
                        }
                    } else {
                        startPicking()
                    }
                }) {
                    Label("🕵️ 瞄准拾取 UI 元素", systemImage: "viewfinder")
                        .frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).tint(.blue)
            }
        case .setVariable:
            let parts = action.parameter.components(separatedBy: "|")
            let key = parts.count > 0 ? parts[0] : ""
            let val = parts.count > 1 ? parts[1] : ""
            VStack(alignment: .leading, spacing: 8) {
                TextField("变量名 (例: name)", text: Binding(get: { key }, set: { action.parameter = "\($0)|\(val)" })).textFieldStyle(.roundedBorder)
                TextField("变量值", text: Binding(get: { val }, set: { action.parameter = "\(key)|\($0)" })).textFieldStyle(.roundedBorder)
                Text("设置后，后续节点可使用 {{变量名}} 调用。").font(.caption).foregroundColor(.secondary)
            }
        case .httpRequest:
            let parts = action.parameter.components(separatedBy: "|")
            let url = parts.count > 0 ? parts[0] : ""
            let method = parts.count > 1 ? parts[1] : "GET"
            VStack(alignment: .leading, spacing: 8) {
                TextField("API 地址", text: Binding(get: { url }, set: { action.parameter = "\($0)|\(method)" })).textFieldStyle(.roundedBorder)
                Picker("请求方法", selection: Binding(get: { method }, set: { action.parameter = "\(url)|\($0)" })) { Text("GET").tag("GET"); Text("POST").tag("POST") }
                Text("请求结果将自动存入 {{http_response}} 变量。").font(.caption).foregroundColor(.secondary)
            }
        case .ocrText: OCRActionEditor(action: $action)
        case .mouseOperation: MouseActionEditor(parameter: $action.parameter)
        case .condition: ConditionEditor(parameter: $action.parameter)
        case .showNotification: NotificationEditor(parameter: $action.parameter)
        case .runShell, .runAppleScript:
            VStack(alignment: .leading) { TextEditor(text: $action.parameter).font(.system(size: 11, design: .monospaced)).frame(height: 120).padding(4).background(Color.gray.opacity(0.1)).cornerRadius(4); Text("支持变量插值，如 {{clipboard}}").font(.caption2).foregroundColor(.blue) }
        case .typeText:
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    TextField("输入文本", text: $action.parameter)
                        .textFieldStyle(.roundedBorder)
                    Menu {
                        Button("[ENTER] 回车") { action.parameter += "[ENTER]" }
                        Button("[BACKSPACE] 退格") { action.parameter += "[BACKSPACE]" }
                        Divider()
                        Group {
                            Button("全选 (CMD+A)") { action.parameter += "[CMD+A]" }
                            Button("复制 (CMD+C)") { action.parameter += "[CMD+C]" }
                            Button("粘贴 (CMD+V)") { action.parameter += "[CMD+V]" }
                        }
                        Divider()
                        Group {
                            Button("跳至顶端 (CMD+UP)") { action.parameter += "[CMD+UP]" }
                            Button("跳至底端 (CMD+DOWN)") { action.parameter += "[CMD+DOWN]" }
                        }
                        Divider()
                        Button("剪贴板变量") { action.parameter += "{{clipboard}}" }
                    } label: { Image(systemName: "keyboard.badge.ellipsis") }.fixedSize()
                }
                Text("支持组合键如 [CMD+A]、[BACKSPACE] 及变量").font(.system(size: 10)).foregroundColor(.secondary)
            }
        case .wait: HStack { TextField("秒数", text: $action.parameter).textFieldStyle(.roundedBorder); Text("秒") }
        case .callWorkflow:
            VStack(alignment: .leading, spacing: 10) {
                Text("选择要执行的子工作流：").font(.caption)
                
                let allWorkflows = StorageManager.shared.load()
                
                // 【✨核心修复 1】通过当前 action 的 ID 反查它属于哪个工作流，从而拿到“当前工作流 ID”
                let currentWorkflowId = allWorkflows.first(where: { wf in
                    wf.actions.contains(where: { $0.id == action.id })
                })?.id.uuidString ?? ""
                
                // 使用原生的 Picker 绑定
                Picker("", selection: $action.parameter) {
                    Text("请选择...").tag("")
                    
                    ForEach(allWorkflows) { wf in
                        // 【✨核心修复 2】只排除“当前工作流”自己，彻底杜绝死循环，且不会导致选中后变空白
                        if wf.id.uuidString != currentWorkflowId {
                            Text(wf.name).tag(wf.id.uuidString)
                        }
                    }
                }
                .labelsHidden()
                
                Text("执行到此节点时，将挂起当前流程，等待子流程执行完毕后继续。").font(.caption2).foregroundColor(.secondary)
            }
        default: TextField("参数设置", text: $action.parameter).textFieldStyle(.roundedBorder)
        }
    }
}

// MARK: - [✨精简版] Web 智能体节点编辑器
struct WebAgentEditor: View {
    @Binding var action: RPAAction
    
    private var paramsBinding: Binding<WebAgentParams> {
        Binding(
            get: { WebAgentParams.parse(from: action.parameter) },
            set: { action.parameter = $0.encode() }
        )
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            
            // 1. 任务目标
            VStack(alignment: .leading, spacing: 4) {
                Label("🎯 智能体任务目标", systemImage: "flag.checkered").font(.subheadline).bold()
                TextEditor(text: paramsBinding.taskDesc)
                    .font(.system(size: 12))
                    .frame(height: 45)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3)))
            }
            
            // 2. [✨重构] 成功视觉断言 (支持 AI 与 OCR 双引擎)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("✅ 成功视觉断言", systemImage: "checkmark.seal").font(.subheadline).bold()
                    Spacer()
                    Picker("", selection: paramsBinding.assertionType) {
                        Text("🤖 AI 裁判").tag("ai")
                        Text("🔍 OCR 识字").tag("ocr")
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                }
                
                if paramsBinding.assertionType.wrappedValue == "ocr" {
                    TextField("请输入需出现在屏幕上的目标文字...", text: paramsBinding.successAssertion)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                    Text("极速本地验证，将在指定的【视觉范围】内寻找该文字。").font(.caption2).foregroundColor(.green)
                } else {
                    TextEditor(text: paramsBinding.successAssertion)
                        .font(.system(size: 11))
                        .frame(height: 35)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3)))
                    Text("输入自然语言让大模型判断，如：'屏幕上出现了提交成功字样'。").font(.caption2).foregroundColor(.secondary)
                }
            }
            
            // 3. 操作手册
            VStack(alignment: .leading, spacing: 4) {
                Label("📚 注入操作手册 (可选 RAG)", systemImage: "book.pages").font(.subheadline).bold()
                TextEditor(text: paramsBinding.manualText)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(height: 50)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3)))
            }
            
            Divider()
            
            // 4. 底层控制
            VStack(alignment: .leading, spacing: 8) {
                Label("⚙️ 底层交互控制", systemImage: "cpu").font(.subheadline).bold()
                
                HStack {
                    Picker("目标浏览器:", selection: paramsBinding.browser) {
                        Text("内置开发者浏览器").tag("InternalBrowser")
                        Text("Safari (AppleScript)").tag("Safari")
                    }.frame(width: 200)

                    Picker("视觉范围:", selection: paramsBinding.captureMode) {
                        Text("仅目标程序").tag("app")
                        Text("全屏截取").tag("fullscreen")
                    }.frame(width: 170)
                }

                Toggle("🛡️ 开启 Human-in-the-loop (人工确认关键动作)", isOn: paramsBinding.requireConfirm)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(.purple)
            }
        }
    }
}

// -----------------------------------------------------------------------------------
// 💡极客级辅助视图代码 (MiniDesktop, OCRMiniDesktop, 连接线绘制, 截屏工具等)
// -----------------------------------------------------------------------------------

struct MouseMiniDesktop: View {
    @Binding var point1Str: String; @Binding var point2Str: String; var isDrag: Bool; var isRelative: Bool
    let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
    @State private var dragStartP1: CGPoint? = nil; @State private var dragStartP2: CGPoint? = nil
    func getPoint(_ str: String, defaultPt: CGPoint) -> CGPoint { let parts = str.split(separator: ","); if parts.count == 2, let x = Double(parts[0].trimmingCharacters(in: .whitespaces)), let y = Double(parts[1].trimmingCharacters(in: .whitespaces)) { return CGPoint(x: x, y: y) }; return defaultPt }
    var body: some View { GeometryReader { geo in let scaleX = geo.size.width / screen.width; let scaleY = geo.size.height / screen.height; ZStack(alignment: .topLeading) { RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.8)); RoundedRectangle(cornerRadius: 6).stroke(Color.gray, lineWidth: 2); let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2); if isRelative { Path { p in p.move(to: CGPoint(x: center.x, y: 0)); p.addLine(to: CGPoint(x: center.x, y: geo.size.height)); p.move(to: CGPoint(x: 0, y: center.y)); p.addLine(to: CGPoint(x: geo.size.width, y: center.y)) }.stroke(Color.white.opacity(0.2), lineWidth: 1) }; let p1 = getPoint(point1Str, defaultPt: isRelative ? .zero : CGPoint(x: screen.width/2, y: screen.height/2)); let vP1 = isRelative ? CGPoint(x: center.x + p1.x * scaleX, y: center.y + p1.y * scaleY) : CGPoint(x: p1.x * scaleX, y: p1.y * scaleY); if isDrag { let p2 = getPoint(point2Str, defaultPt: isRelative ? .zero : CGPoint(x: screen.width/2 + 50, y: screen.height/2 + 50)); let vP2 = isRelative ? CGPoint(x: vP1.x + p2.x * scaleX, y: vP1.y + p2.y * scaleY) : CGPoint(x: p2.x * scaleX, y: p2.y * scaleY); Path { p in p.move(to: vP1); p.addLine(to: vP2) }.stroke(Color.blue, style: StrokeStyle(lineWidth: 2, dash: [4, 4])); Circle().fill(Color.red).frame(width: 14, height: 14).position(vP2).overlay(Text("终").font(.system(size: 9)).position(vP2).foregroundColor(.white)).gesture(DragGesture().onChanged { val in if dragStartP2 == nil { dragStartP2 = p2 }; if let start = dragStartP2 { point2Str = "\(Int(start.x + val.translation.width / scaleX)), \(Int(start.y + val.translation.height / scaleY))" } }.onEnded { _ in dragStartP2 = nil }) }; Circle().fill(Color.green).frame(width: 14, height: 14).position(vP1).overlay(Text(isDrag ? "起" : "点").font(.system(size: 9)).position(vP1).foregroundColor(.white)).gesture(DragGesture().onChanged { val in if dragStartP1 == nil { dragStartP1 = p1 }; if let start = dragStartP1 { point1Str = "\(Int(start.x + val.translation.width / scaleX)), \(Int(start.y + val.translation.height / scaleY))" } }.onEnded { _ in dragStartP1 = nil }) } }.frame(height: 120) }
}

struct OCRMiniDesktop: View {
    @Binding var regionStr: String; @Binding var offsetX: Double; @Binding var offsetY: Double
    let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
    @State private var dragStartRegion: CGRect? = nil; @State private var dragStartOffset: CGPoint? = nil
    var currentRegion: CGRect { let parts = regionStr.split(separator: ","); if parts.count == 4, let x = Double(parts[0].trimmingCharacters(in: .whitespaces)), let y = Double(parts[1].trimmingCharacters(in: .whitespaces)), let w = Double(parts[2].trimmingCharacters(in: .whitespaces)), let h = Double(parts[3].trimmingCharacters(in: .whitespaces)) { return CGRect(x: x, y: y, width: w, height: h) }; return CGRect(x: 0, y: 0, width: screen.width, height: screen.height) }
    var body: some View { GeometryReader { geo in let scaleX = geo.size.width / screen.width; let scaleY = geo.size.height / screen.height; ZStack(alignment: .topLeading) { RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.8)); RoundedRectangle(cornerRadius: 6).stroke(Color.gray, lineWidth: 2); let r = currentRegion; let viewRect = CGRect(x: r.minX * scaleX, y: r.minY * scaleY, width: r.width * scaleX, height: r.height * scaleY); Rectangle().fill(Color.blue.opacity(0.3)).border(Color.blue, width: 1).frame(width: max(viewRect.width, 10), height: max(viewRect.height, 10)).offset(x: viewRect.minX, y: viewRect.minY).gesture(DragGesture().onChanged { val in if dragStartRegion == nil { dragStartRegion = r }; if let start = dragStartRegion { let newX = max(0, min(screen.width - start.width, start.minX + val.translation.width / scaleX)); let newY = max(0, min(screen.height - start.height, start.minY + val.translation.height / scaleY)); regionStr = "\(Int(newX)), \(Int(newY)), \(Int(start.width)), \(Int(start.height))" } }.onEnded { _ in dragStartRegion = nil }); let center = CGPoint(x: viewRect.midX, y: viewRect.midY); let offsetViewX = offsetX * scaleX; let offsetViewY = offsetY * scaleY; let target = CGPoint(x: center.x + offsetViewX, y: center.y + offsetViewY); Path { p in p.move(to: center); p.addLine(to: target) }.stroke(Color.red, style: StrokeStyle(lineWidth: 1, dash: [2,2])); Circle().fill(Color.green).frame(width: 6, height: 6).position(center); Circle().fill(Color.red).frame(width: 14, height: 14).position(target).overlay(Text("点").font(.system(size: 9)).position(target).foregroundColor(.white)).gesture(DragGesture().onChanged { val in if dragStartOffset == nil { dragStartOffset = CGPoint(x: offsetX, y: offsetY) }; if let start = dragStartOffset { offsetX = start.x + val.translation.width / scaleX; offsetY = start.y + val.translation.height / scaleY } }.onEnded { _ in dragStartOffset = nil }) } }.frame(height: 120) }
}

struct MouseActionEditor: View {
    @Binding var parameter: String
    var body: some View {
        let parts = parameter.components(separatedBy: "|"); let mouseType = parts.count > 1 ? parts[0] : "leftClick"; let mouseVal1 = parts.count > 1 ? parts[1] : (parameter.contains(",") ? parameter : "0, 0"); let mouseVal2 = parts.count > 2 ? parts[2] : "0, 0"; let isRelative = parts.count > 3 ? (parts[3] == "true") : false
        let mainTab = mouseType.lowercased().contains("scroll") ? "scroll" : mouseType
        let updateParam = { (type: String, v1: String, v2: String, rel: Bool) in parameter = "\(type)|\(v1)|\(v2)|\(rel ? "true" : "false")" }
        VStack(alignment: .leading, spacing: 8) { HStack { Picker("", selection: Binding(get: { mainTab }, set: { let newType = $0 == "scroll" ? "scrollDown" : $0; updateParam(newType, mouseVal1, mouseVal2, isRelative) })) { Text("移动").tag("move"); Text("点击").tag("leftClick"); Text("右键").tag("rightClick"); Text("双击").tag("doubleClick"); Text("拖拽").tag("drag"); Text("滚轮").tag("scroll") }.pickerStyle(.segmented) }; if mainTab != "scroll" { Toggle("相对当前光标", isOn: Binding(get: { isRelative }, set: { updateParam(mouseType, mouseVal1, mouseVal2, $0) })).toggleStyle(.switch).controlSize(.mini); MouseMiniDesktop(point1Str: Binding(get: { mouseVal1 }, set: { updateParam(mouseType, $0, mouseVal2, isRelative) }), point2Str: Binding(get: { mouseVal2 }, set: { updateParam(mouseType, mouseVal1, $0, isRelative) }), isDrag: mainTab == "drag", isRelative: isRelative) } else { HStack { Picker("", selection: Binding(get: { mouseType }, set: { updateParam($0, mouseVal1, mouseVal2, isRelative) })) { Text("向上").tag("scrollUp"); Text("向下").tag("scrollDown") }.frame(width: 140); TextField("行数", text: Binding(get: { mouseVal1 }, set: { updateParam(mouseType, $0, mouseVal2, isRelative) })).textFieldStyle(.roundedBorder) } } }
    }
}

struct OCRActionEditor: View {
    @Binding var action: RPAAction
    @State private var isPickingRegion = false
    var body: some View {
        let parts = action.parameter.components(separatedBy: "|")
        let targetText = parts.count > 0 ? parts[0] : action.parameter
        let shouldClick = parts.count > 1 ? (parts[1] == "true") : true
        let regionStr = parts.count > 2 ? parts[2] : ""
        // [✨新增] 提取第4个参数：目标 App
        let targetApp = parts.count > 3 ? parts[3] : ""
        
        let updateParam = { (t: String, c: Bool, r: String, app: String) in
            action.parameter = "\(t)|\(c ? "true" : "false")|\(r)|\(app)"
        }
        
        VStack(alignment: .leading, spacing: 12) {
            TextField("要识别的文字内容", text: Binding(get: { targetText }, set: { updateParam($0, shouldClick, regionStr, targetApp) }))
                .textFieldStyle(.roundedBorder)
            
            // [✨新增] 限定目标 App 的快捷选择框
            HStack {
                Text("限定 App:").font(.caption).frame(width: 60, alignment: .leading)
                TextField("App名称 (留空为全屏识别)", text: Binding(get: { targetApp }, set: { updateParam(targetText, shouldClick, regionStr, $0) }))
                    .textFieldStyle(.roundedBorder)
                
                Menu {
                    let runningApps = NSWorkspace.shared.runningApplications
                        .filter { $0.activationPolicy == .regular }
                        .compactMap { $0.localizedName }.sorted()
                    ForEach(runningApps, id: \.self) { appName in
                        Button(appName) { updateParam(targetText, shouldClick, regionStr, appName) }
                    }
                } label: { Image(systemName: "list.bullet.rectangle.portrait") }
                .fixedSize()
                .help("从当前运行的程序中选择，选择后只识别该程序的窗口画面。")
            }
            
            Toggle("识别成功后伴随鼠标点击", isOn: Binding(get: { shouldClick }, set: { updateParam(targetText, $0, regionStr, targetApp) }))
            
            Divider()
            
            HStack {
                TextField("区域限制 (X,Y,宽,高)", text: Binding(get: { regionStr }, set: { updateParam(targetText, shouldClick, $0, targetApp) }))
                    .textFieldStyle(.roundedBorder)
                Button(action: {
                    isPickingRegion = true
                    ScreenRegionPicker.shared.pickRegion { rect in
                        if let r = rect { updateParam(targetText, shouldClick, "\(Int(r.minX)), \(Int(r.minY)), \(Int(r.width)), \(Int(r.height))", targetApp) }
                        isPickingRegion = false
                    }
                }) { Image(systemName: "viewfinder") }.buttonStyle(.bordered)
            }
            
            OCRMiniDesktop(regionStr: Binding(get: { regionStr }, set: { updateParam(targetText, shouldClick, $0, targetApp) }), offsetX: $action.offsetX, offsetY: $action.offsetY)
        }
    }
}

struct NotificationEditor: View { @Binding var parameter: String; var body: some View { let parts = parameter.components(separatedBy: "|"); let style = parts.count > 0 ? parts[0] : "banner"; let title = parts.count > 1 ? parts[1] : ""; let bodyText = parts.count > 2 ? parts[2] : ""; VStack(alignment: .leading, spacing: 10) { Picker("提醒", selection: Binding(get: { style }, set: { parameter = "\($0)|\(title)|\(bodyText)" })) { Text("横幅").tag("banner"); Text("对话框").tag("dialog") }.pickerStyle(.segmented); TextField("标题", text: Binding(get: { title }, set: { parameter = "\(style)|\($0)|\(bodyText)" })).textFieldStyle(.roundedBorder); TextField("正文 (支持 {{var}})", text: Binding(get: { bodyText }, set: { parameter = "\(style)|\(title)|\($0)" })).textFieldStyle(.roundedBorder) } } }
struct ConditionEditor: View { @Binding var parameter: String; var body: some View { let parts = parameter.components(separatedBy: "|"); let leftValue = parts.count > 0 ? parts[0] : "{{clipboard}}"; let op = parts.count > 1 ? parts[1] : "contains"; let rightValue = parts.count > 2 ? parts[2] : ""; HStack { TextField("左值", text: Binding(get: { leftValue }, set: { parameter = "\($0)|\(op)|\(rightValue)" })).textFieldStyle(.roundedBorder); Picker("", selection: Binding(get: { op }, set: { parameter = "\(leftValue)|\($0)|\(rightValue)" })) { Text("包含").tag("contains"); Text("等于").tag("==") }.frame(width: 80); TextField("对比值", text: Binding(get: { rightValue }, set: { parameter = "\(leftValue)|\(op)|\($0)" })).textFieldStyle(.roundedBorder) } } }

class RegionPickerView: NSView {
    var startPointCG: CGPoint?; var currentPointCG: CGPoint?; var startPointView: CGPoint?; var currentPointView: CGPoint?; var completion: ((CGRect) -> Void)?
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func mouseDown(with event: NSEvent) { startPointView = event.locationInWindow; startPointCG = CGEvent(source: nil)?.location; currentPointView = startPointView; currentPointCG = startPointCG }
    override func mouseDragged(with event: NSEvent) { currentPointView = event.locationInWindow; currentPointCG = CGEvent(source: nil)?.location; needsDisplay = true }
    override func mouseUp(with event: NSEvent) { currentPointView = event.locationInWindow; currentPointCG = CGEvent(source: nil)?.location; needsDisplay = true; guard let scg = startPointCG, let ccg = currentPointCG else { completion?(.zero); return }; let w = abs(ccg.x - scg.x); let h = abs(ccg.y - scg.y); if w > 5 && h > 5 { completion?(CGRect(x: min(scg.x, ccg.x), y: min(scg.y, ccg.y), width: w, height: h)) } else { completion?(.zero) } }
    override func draw(_ dirtyRect: NSRect) { NSColor(white: 0, alpha: 0.4).set(); bounds.fill(); if let start = startPointView, let current = currentPointView { let rect = NSRect(x: min(start.x, current.x), y: min(start.y, current.y), width: abs(current.x - start.x), height: abs(current.y - start.y)); NSColor.clear.set(); rect.fill(using: .copy); NSColor.systemRed.setStroke(); let path = NSBezierPath(rect: rect); path.lineWidth = 2.0; path.stroke() } }
}
class ScreenRegionPicker {
    static let shared = ScreenRegionPicker(); private var window: NSWindow?; private var eventMonitor: Any?
    @MainActor func pickRegion(completion: @escaping (CGRect?) -> Void) {
        if window != nil { return }; NSApp.windows.first(where: { $0.className.contains("AppKitWindow") })?.miniaturize(nil); var totalRect = CGRect.zero; for screen in NSScreen.screens { totalRect = totalRect.union(screen.frame) }; let win = NSWindow(contentRect: totalRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false); win.level = .screenSaver; win.backgroundColor = .clear; win.isOpaque = false; win.hasShadow = false; win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; let view = RegionPickerView(); let cleanup = { [weak self] (rect: CGRect?) in self?.window?.close(); self?.window = nil; if let monitor = self?.eventMonitor { NSEvent.removeMonitor(monitor); self?.eventMonitor = nil }; completion(rect); NSApp.windows.first(where: { $0.className.contains("AppKitWindow") })?.deminiaturize(nil) }; view.completion = { rect in cleanup(rect == .zero ? nil : rect) }; win.contentView = view; win.makeKeyAndOrderFront(nil); self.window = win; self.eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in if event.keyCode == 53 { cleanup(nil); return nil }; return event }
    }
}

// MARK: - 原生 UI 元素拾取器
class UIElementPickerOverlayView: NSView {
    var highlightRect: NSRect = .zero { didSet { needsDisplay = true } }
    var cachedAppName = ""
    var cachedRole = ""
    var cachedTitle = ""
    private let axQueue = DispatchQueue(label: "com.rpa.axqueue", qos: .userInteractive)
    private var isFetching = false
    
    func updateHighlight(at point: CGPoint) {
        guard !isFetching else { return }
        isFetching = true
        axQueue.async { [weak self] in
            guard let self = self else { return }
            self.fetchElement(at: point)
        }
    }
    
    private func fetchElement(at point: CGPoint) {
        let systemWide = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &element)
        guard error == .success, let axElement = element else {
            DispatchQueue.main.async { [weak self] in self?.highlightRect = .zero; self?.cachedAppName = ""; self?.isFetching = false }
            return
        }
        
        var pid: pid_t = 0
        if AXUIElementGetPid(axElement, &pid) == .success, pid == ProcessInfo.processInfo.processIdentifier {
            DispatchQueue.main.async { [weak self] in self?.highlightRect = .zero; self?.cachedAppName = ""; self?.isFetching = false }
            return
        }
        
        var role = ""; var title = ""; let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? ""
        var attrVal: CFTypeRef? = nil
        if AXUIElementCopyAttributeValue(axElement, kAXRoleAttribute as CFString, &attrVal) == .success { role = attrVal as? String ?? "" }
        if AXUIElementCopyAttributeValue(axElement, kAXTitleAttribute as CFString, &attrVal) == .success { title = attrVal as? String ?? "" }
        
        var position = CGPoint.zero; var size = CGSize.zero
        if AXUIElementCopyAttributeValue(axElement, kAXPositionAttribute as CFString, &attrVal) == .success, let val = attrVal, CFGetTypeID(val) == AXValueGetTypeID() {
            let axVal = val as! AXValue; if AXValueGetType(axVal) == .cgPoint { AXValueGetValue(axVal, .cgPoint, &position) }
        }
        if AXUIElementCopyAttributeValue(axElement, kAXSizeAttribute as CFString, &attrVal) == .success, let val = attrVal, CFGetTypeID(val) == AXValueGetTypeID() {
            let axVal = val as! AXValue; if AXValueGetType(axVal) == .cgSize { AXValueGetValue(axVal, .cgSize, &size) }
        }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if size.width > 0 && size.height > 0 {
                self.cachedAppName = appName; self.cachedRole = role; self.cachedTitle = title
                if let screen = NSScreen.main { self.highlightRect = NSRect(x: position.x, y: screen.frame.height - position.y - size.height, width: size.width, height: size.height) }
            } else { self.highlightRect = .zero; self.cachedAppName = "" }
            self.isFetching = false
        }
    }
    
    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.set(); bounds.fill()
        if highlightRect != .zero { NSColor.systemRed.withAlphaComponent(0.4).setStroke(); NSColor.systemRed.withAlphaComponent(0.1).setFill(); let path = NSBezierPath(rect: highlightRect); path.lineWidth = 3.0; path.stroke(); path.fill() }
    }
}

class UIElementPicker {
    static let shared = UIElementPicker()
    private var window: NSWindow?; private var overlayView: UIElementPickerOverlayView?
    private var eventTap: CFMachPort?; private var runLoopSource: CFRunLoopSource?
    private var isPicking = false; fileprivate var isCleaningUp = false
    private var pickCompletion: ((String, String, String) -> Void)?
    
    @MainActor func pickElement(completion: @escaping (String, String, String) -> Void) {
        guard !isPicking else { return }
        isPicking = true; isCleaningUp = false; pickCompletion = completion
        NSApp.windows.first(where: { $0.className.contains("AppKitWindow") })?.miniaturize(nil)
        
        let totalRect = NSScreen.screens.reduce(CGRect.zero) { $0.union($1.frame) }
        let win = NSWindow(contentRect: totalRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        win.level = .screenSaver; win.backgroundColor = .clear; win.isOpaque = false; win.hasShadow = false; win.ignoresMouseEvents = true; win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; win.isReleasedWhenClosed = false
        
        let overlay = UIElementPickerOverlayView(); win.contentView = overlay; win.makeKeyAndOrderFront(nil)
        self.window = win; self.overlayView = overlay
        
        let eventMask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseUp.rawValue) | (1 << CGEventType.mouseMoved.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
            guard let ref = refcon else { return Unmanaged.passUnretained(event) }
            let picker = Unmanaged<UIElementPicker>.fromOpaque(ref).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { if !picker.isCleaningUp, let tap = picker.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }; return Unmanaged.passUnretained(event) }
            if picker.isCleaningUp { return Unmanaged.passUnretained(event) }
            if type == .mouseMoved { DispatchQueue.main.async { picker.overlayView?.updateHighlight(at: event.location) }; return Unmanaged.passUnretained(event) }
            else if type == .leftMouseDown { DispatchQueue.main.async { picker.handleMouseDown() }; return nil }
            else if type == .leftMouseUp { return nil }
            else if type == .keyDown { if event.getIntegerValueField(.keyboardEventKeycode) == 53 { DispatchQueue.main.async { picker.cancelPicking() }; return nil } }
            return Unmanaged.passUnretained(event)
        }
        
        eventTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: CGEventMask(eventMask), callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque())
        if let tap = eventTap { runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0); CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes); CGEvent.tapEnable(tap: tap, enable: true) } else { cancelPicking() }
    }
    
    func handleMouseDown() {
        guard !isCleaningUp else { return }
        isCleaningUp = true; if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        let appName = overlayView?.cachedAppName ?? ""; let role = overlayView?.cachedRole ?? ""; let title = overlayView?.cachedTitle ?? ""
        if appName.isEmpty { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.performCleanup() }; return }
        self.pickCompletion?(appName, role, title); DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.performCleanup() }
    }
    
    func cancelPicking() {
        guard !isCleaningUp else { return }
        isCleaningUp = true; if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.performCleanup() }
    }
    
    private func performCleanup() {
        if let tap = eventTap { if let runLoop = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoop, .commonModes) }; CFMachPortInvalidate(tap); eventTap = nil }
        runLoopSource = nil; window?.close(); window = nil; overlayView = nil; isPicking = false; isCleaningUp = false; pickCompletion = nil
        NSApp.windows.first(where: { $0.className.contains("AppKitWindow") })?.deminiaturize(nil)
    }
}
