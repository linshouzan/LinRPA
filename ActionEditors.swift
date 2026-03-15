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
            
            VStack(alignment: .leading, spacing: 10) {
                TextField("网址 (例如: https://bing.com)", text: Binding(get: { url }, set: { action.parameter = "\($0)|\(browser)" }))
                    .textFieldStyle(.roundedBorder)
                
                HStack {
                    Text("目标浏览器:").font(.caption)
                    Picker("", selection: Binding(get: { browser }, set: { action.parameter = "\(url)|\($0)" })) {
                        Text("🚀 内置开发者浏览器").tag("InternalBrowser")
                        Text("系统默认浏览器").tag("System")
                        Text("Safari").tag("Safari")
                        Text("Google Chrome").tag("Google Chrome")
                    }.labelsHidden().frame(width: 160)
                }
                Text("如果选择内置浏览器，将自动新建标签页。").font(.caption2).foregroundColor(.secondary)
            }
        case .webAgent: WebAgentEditor(action: $action)
        case .uiInteraction: // [✨修改] 原生 UI 自动化表单（支持模式和索引）
            let parts = action.parameter.components(separatedBy: "|")
            let targetApp = parts.count > 0 ? parts[0] : ""
            let targetRole = parts.count > 1 ? parts[1] : ""
            let targetTitle = parts.count > 2 ? parts[2] : ""
            let interactionType = parts.count > 3 ? parts[3] : "click"
            // [✨新增参数]
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
                
                // [✨核心新增] 匹配规则与索引配置区
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
                    
                    // [✨新增] 如果用户已经选择了目标 App，先将其强制激活到最前端
                    if !targetApp.isEmpty,
                       let appToActivate = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == targetApp }) {
                        
                        // 强制激活目标应用（忽略其他挡在前面的应用）
                        appToActivate.activate(options: .activateIgnoringOtherApps)
                        
                        // 延迟 0.3 秒，等待系统的窗口切换动画完成后，再呼出拾取器透明遮罩
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            startPicking()
                        }
                    } else {
                        // 如果没有选择 App，直接呼出拾取器
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
                        // 基础功能
                        Button("[ENTER] 回车") { action.parameter += "[ENTER]" }
                        Button("[BACKSPACE] 退格") { action.parameter += "[BACKSPACE]" }
                        
                        Divider()
                        
                        // 组合快捷键
                        Group {
                            Button("全选 (CMD+A)") { action.parameter += "[CMD+A]" }
                            Button("复制 (CMD+C)") { action.parameter += "[CMD+C]" }
                            Button("粘贴 (CMD+V)") { action.parameter += "[CMD+V]" }
                        }
                        
                        Divider()
                        
                        // 导航快捷键
                        Group {
                            Button("跳至顶端 (CMD+UP)") { action.parameter += "[CMD+UP]" }
                            Button("跳至底端 (CMD+DOWN)") { action.parameter += "[CMD+DOWN]" }
                        }
                        
                        Divider()
                        
                        Button("剪贴板变量") { action.parameter += "{{clipboard}}" }
                    } label: {
                        Image(systemName: "keyboard.badge.ellipsis")
                    }
                    .fixedSize()
                }
                Text("支持组合键如 [CMD+A]、[BACKSPACE] 及变量")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        case .wait: HStack { TextField("秒数", text: $action.parameter).textFieldStyle(.roundedBorder); Text("秒") }
        default: TextField("参数设置", text: $action.parameter).textFieldStyle(.roundedBorder)
        }
    }
}

// MARK: - [✨新增] Web 智能体极客编辑器
struct WebAgentEditor: View {
    @Binding var action: RPAAction
    
    var body: some View {
        // [✨修改] maxSplits 改为 4，以支持第 5 个参数 (截屏模式)
        let parts = action.parameter.split(separator: "|", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
        let taskDesc = parts.count > 0 ? parts[0] : ""
        let browser = parts.count > 1 ? parts[1] : "Safari"
        let requireConfirm = parts.count > 2 ? (parts[2] == "true") : true
        let manualText = parts.count > 3 ? parts[3] : ""
        let captureMode = parts.count > 4 ? parts[4] : "app" // 默认只截取 App
        
        let updateParam = { (task: String, brs: String, conf: Bool, man: String, mode: String) in
            action.parameter = "\(task)|\(brs)|\(conf ? "true" : "false")|\(man)|\(mode)"
        }
        
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Label("🎯 智能体任务目标", systemImage: "flag.checkered").font(.subheadline).bold()
                TextEditor(text: Binding(get: { taskDesc }, set: { updateParam($0, browser, requireConfirm, manualText, captureMode) }))
                    .font(.system(size: 12))
                    .frame(height: 60)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3)))
                Text("例如: 帮我填写表单并提交，姓名为张三，请假天数3天。").font(.caption2).foregroundColor(.secondary)
            }
            
            Divider()
            
            VStack(alignment: .leading, spacing: 6) {
                Label("📚 注入操作手册 (可选 RAG)", systemImage: "book.pages").font(.subheadline).bold()
                TextEditor(text: Binding(get: { manualText }, set: { updateParam(taskDesc, browser, requireConfirm, $0, captureMode) }))
                    .font(.system(size: 11, design: .monospaced))
                    .frame(height: 100)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3)))
                Text("粘贴此系统的操作要求或注意事项，Agent 遇到卡点时会自动查阅。").font(.caption2).foregroundColor(.secondary)
            }
            
            Divider()
            
            VStack(alignment: .leading, spacing: 10) {
                Label("⚙️ 底层交互控制", systemImage: "cpu").font(.subheadline).bold()
                
                Picker("目标浏览器:", selection: Binding(get: { browser }, set: { updateParam(taskDesc, $0, requireConfirm, manualText, captureMode) })) {
                    Text("🚀 内置开发者浏览器 (极速原生)").tag("InternalBrowser")
                    Text("Safari (AppleScript Bridge)").tag("Safari")
                }.frame(width: 250)

                // [✨新增] 截屏范围配置项
                Picker("视觉范围:", selection: Binding(get: { captureMode }, set: { updateParam(taskDesc, browser, requireConfirm, manualText, $0) })) {
                    Text("仅截取目标程序 (专注无干扰)").tag("app")
                    Text("全屏截取 (视野大，但容易误判)").tag("fullscreen")
                }.frame(width: 280)

                Toggle("🛡️ 开启 Human-in-the-loop (执行关键动作前人工确认)", isOn: Binding(get: { requireConfirm }, set: { updateParam(taskDesc, browser, $0, manualText, captureMode) }))
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
        let parts = action.parameter.components(separatedBy: "|"); let targetText = parts.count > 0 ? parts[0] : action.parameter; let shouldClick = parts.count > 1 ? (parts[1] == "true") : true; let regionStr = parts.count > 2 ? parts[2] : ""
        let updateParam = { (t: String, c: Bool, r: String) in action.parameter = "\(t)|\(c ? "true" : "false")|\(r)" }
        VStack(alignment: .leading, spacing: 12) { TextField("要识别的文字内容", text: Binding(get: { targetText }, set: { updateParam($0, shouldClick, regionStr) })).textFieldStyle(.roundedBorder); Toggle("识别成功后伴随鼠标点击", isOn: Binding(get: { shouldClick }, set: { updateParam(targetText, $0, regionStr) })); Divider(); HStack { TextField("区域限制 (X,Y,宽,高)", text: Binding(get: { regionStr }, set: { updateParam(targetText, shouldClick, $0) })).textFieldStyle(.roundedBorder); Button(action: { isPickingRegion = true; ScreenRegionPicker.shared.pickRegion { rect in if let r = rect { updateParam(targetText, shouldClick, "\(Int(r.minX)), \(Int(r.minY)), \(Int(r.width)), \(Int(r.height))") }; isPickingRegion = false } }) { Image(systemName: "viewfinder") }.buttonStyle(.bordered) }; OCRMiniDesktop(regionStr: Binding(get: { regionStr }, set: { updateParam(targetText, shouldClick, $0) }), offsetX: $action.offsetX, offsetY: $action.offsetY) }
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

// MARK: - [✨坚如磐石版] 原生 UI 元素拾取器 (防死锁 + 安全析构)

class UIElementPickerOverlayView: NSView {
    var highlightRect: NSRect = .zero { didSet { needsDisplay = true } }
    
    // 缓存数据，保证主线程点击时绝对安全，避免 IPC 阻塞
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
        
        // 1. 如果没获取到元素，安全释放锁
        guard error == .success, let axElement = element else {
            DispatchQueue.main.async { [weak self] in
                self?.highlightRect = .zero
                self?.cachedAppName = ""
                self?.isFetching = false
            }
            return
        }
        
        // 2. 防呆：绝对禁止拾取 RPA 自身的 UI，防止死循环
        var pid: pid_t = 0
        if AXUIElementGetPid(axElement, &pid) == .success, pid == ProcessInfo.processInfo.processIdentifier {
            DispatchQueue.main.async { [weak self] in
                self?.highlightRect = .zero
                self?.cachedAppName = ""
                self?.isFetching = false
            }
            return
        }
        
        // 3. 获取属性
        var role = ""
        var title = ""
        let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? ""
        
        var attrVal: CFTypeRef? = nil
        if AXUIElementCopyAttributeValue(axElement, kAXRoleAttribute as CFString, &attrVal) == .success {
            role = attrVal as? String ?? ""
        }
        if AXUIElementCopyAttributeValue(axElement, kAXTitleAttribute as CFString, &attrVal) == .success {
            title = attrVal as? String ?? ""
        }
        
        var position = CGPoint.zero
        // 严格检验内存 DNA，防范 32 字节 CGRect 塞入 16 字节 CGPoint 导致的栈溢出
        if AXUIElementCopyAttributeValue(axElement, kAXPositionAttribute as CFString, &attrVal) == .success,
           let val = attrVal, CFGetTypeID(val) == AXValueGetTypeID() {
            let axVal = val as! AXValue
            if AXValueGetType(axVal) == .cgPoint { AXValueGetValue(axVal, .cgPoint, &position) }
        }
        
        var size = CGSize.zero
        if AXUIElementCopyAttributeValue(axElement, kAXSizeAttribute as CFString, &attrVal) == .success,
           let val = attrVal, CFGetTypeID(val) == AXValueGetTypeID() {
            let axVal = val as! AXValue
            if AXValueGetType(axVal) == .cgSize { AXValueGetValue(axVal, .cgSize, &size) }
        }
        
        // 4. 切回主线程渲染，并释放 Fetching 锁
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if size.width > 0 && size.height > 0 {
                self.cachedAppName = appName
                self.cachedRole = role
                self.cachedTitle = title
                if let screen = NSScreen.main {
                    let y = screen.frame.height - position.y - size.height
                    self.highlightRect = NSRect(x: position.x, y: y, width: size.width, height: size.height)
                }
            } else {
                self.highlightRect = .zero
                self.cachedAppName = ""
            }
            self.isFetching = false
        }
    }
    
    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.set(); bounds.fill()
        if highlightRect != .zero {
            NSColor.systemRed.withAlphaComponent(0.4).setStroke()
            NSColor.systemRed.withAlphaComponent(0.1).setFill()
            let path = NSBezierPath(rect: highlightRect)
            path.lineWidth = 3.0
            path.stroke()
            path.fill()
        }
    }
}

class UIElementPicker {
    static let shared = UIElementPicker()
    private var window: NSWindow?
    private var overlayView: UIElementPickerOverlayView?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    
    private var isPicking = false
    fileprivate var isCleaningUp = false
    private var pickCompletion: ((String, String, String) -> Void)?
    
    @MainActor func pickElement(completion: @escaping (String, String, String) -> Void) {
        guard !isPicking else { return }
        isPicking = true
        isCleaningUp = false
        pickCompletion = completion
        
        NSApp.windows.first(where: { $0.className.contains("AppKitWindow") })?.miniaturize(nil)
        
        let totalRect = NSScreen.screens.reduce(CGRect.zero) { $0.union($1.frame) }
        let win = NSWindow(contentRect: totalRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        win.level = .screenSaver
        win.backgroundColor = .clear
        win.isOpaque = false
        win.hasShadow = false
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        
        // [✨修复 1：关闭窗口自动释放陷阱] 防止调用 close() 和 window=nil 造成的双重释放 (Double Free) 崩溃！
        win.isReleasedWhenClosed = false
        
        let overlay = UIElementPickerOverlayView()
        win.contentView = overlay
        win.makeKeyAndOrderFront(nil)
        
        self.window = win
        self.overlayView = overlay
        
        // [✨修复 2：补全鼠标拦截闭环] 必须同时拦截 Down 和 Up 事件！
        let eventMask = (1 << CGEventType.leftMouseDown.rawValue) |
                        (1 << CGEventType.leftMouseUp.rawValue) |
                        (1 << CGEventType.mouseMoved.rawValue) |
                        (1 << CGEventType.keyDown.rawValue)
        
        let callback: CGEventTapCallBack = { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
            guard let ref = refcon else { return Unmanaged.passUnretained(event) }
            let picker = Unmanaged<UIElementPicker>.fromOpaque(ref).takeUnretainedValue()
            
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if !picker.isCleaningUp, let tap = picker.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }
            
            if picker.isCleaningUp { return Unmanaged.passUnretained(event) }
            
            if type == .mouseMoved {
                let loc = event.location
                DispatchQueue.main.async { picker.overlayView?.updateHighlight(at: loc) }
                return Unmanaged.passUnretained(event)
                
            } else if type == .leftMouseDown {
                // 拦截按下，并触发拾取
                DispatchQueue.main.async { picker.handleMouseDown() }
                return nil
                
            } else if type == .leftMouseUp {
                // [✨修复 2] 拦截抬起，阻止半截事件流入系统导致崩溃
                return nil
                
            } else if type == .keyDown {
                if event.getIntegerValueField(.keyboardEventKeycode) == 53 { // ESC 退出
                    DispatchQueue.main.async { picker.cancelPicking() }
                    return nil
                }
            }
            return Unmanaged.passUnretained(event)
        }
        
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        
        if let tap = eventTap {
            runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        } else {
            cancelPicking()
        }
    }
    
    func handleMouseDown() {
        guard !isCleaningUp else { return }
        isCleaningUp = true
        
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        
        let appName = overlayView?.cachedAppName ?? ""
        let role = overlayView?.cachedRole ?? ""
        let title = overlayView?.cachedTitle ?? ""
        
        if appName.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.performCleanup() }
            return
        }
        
        self.pickCompletion?(appName, role, title)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.performCleanup()
        }
    }
    
    func cancelPicking() {
        guard !isCleaningUp else { return }
        isCleaningUp = true
        
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.performCleanup()
        }
    }
    
    private func performCleanup() {
        if let tap = eventTap {
            // [✨修复 3：完美底层剥离] 必须先从 RunLoop 移除，再废弃端口
            if let runLoop = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoop, .commonModes)
            }
            CFMachPortInvalidate(tap)
            eventTap = nil
        }
        runLoopSource = nil
        
        window?.close()
        window = nil
        overlayView = nil
        isPicking = false
        isCleaningUp = false
        pickCompletion = nil
        
        NSApp.windows.first(where: { $0.className.contains("AppKitWindow") })?.deminiaturize(nil)
    }
}
