//////////////////////////////////////////////////////////////////
// 文件名：ActionEditors.swift
// 文件说明：这是适用于 macos 14+ 的RPA组件配置编辑器与交互工具集合
// 功能说明：存放所有的组件配置弹窗、参数表单、MiniDesktop 和底层屏幕拾取器。
// 代码要求：没有要求修改不用输出代码，请保证代码的逻辑和完整性，保留代码中的所有注释内容
//////////////////////////////////////////////////////////////////

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - 主配置弹窗入口
/// 负责根据 Action 的类型分发渲染对应的独立编辑器视图
struct ActionSettingsPopoverView: View {
    @Binding var action: RPAAction
    @Binding var showSettings: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(action.displayTitle)").font(.headline)
                Spacer()
                Button("关闭") { showSettings = false }
            }
            Divider()
            actionParameterView()
        }
        .padding()
        .frame(width: 460)
    }
    
    @ViewBuilder private func actionParameterView() -> some View {
        switch action.type {
        case .openURL:          OpenURLEditor(action: $action)
        case .openApp:          OpenAppEditor(action: $action)
        case .webAgent:         WebAgentEditor(action: $action)
        case .uiInteraction:    UIInteractionEditor(parameter: $action.parameter)
        case .setVariable:      SetVariableEditor(action: $action)
        case .httpRequest:      HTTPRequestEditor(action: $action)
        case .ocrText:          OCRActionEditor(action: $action)
        case .mouseOperation:   MouseActionEditor(parameter: $action.parameter)
        case .condition:        ConditionEditor(parameter: $action.parameter)
        case .showNotification: NotificationEditor(parameter: $action.parameter)
        case .runShell, .runAppleScript: RunScriptEditor(action: $action)
        case .typeText:         TypeTextEditor(action: $action)
        case .wait:             WaitEditor(action: $action)
        case .callWorkflow:     CallWorkflowEditor(action: $action)
        default:
            TextField("参数设置", text: $action.parameter).textFieldStyle(.roundedBorder)
        }
    }
}

// MARK: - [系统与应用] 打开网址编辑器
/// 提供网址输入、浏览器选择、静默模式与无痕模式配置
struct OpenURLEditor: View {
    @Binding var action: RPAAction
    
    var body: some View {
        let parts = action.parameter.components(separatedBy: "|")
        let url = parts.count > 0 ? parts[0] : action.parameter
        let browser = parts.count > 1 ? parts[1] : "InternalBrowser"
        let silent = parts.count > 2 ? (parts[2] == "true") : false
        let incognito = parts.count > 3 ? (parts[3] == "true") : false // [✨新增] 无痕模式
        
        VStack(alignment: .leading, spacing: 10) {
            TextField("网址 (例如: bing.com，支持 {{变量}})", text: Binding(
                get: { url },
                set: { action.parameter = "\($0)|\(browser)|\(silent ? "true" : "false")|\(incognito ? "true" : "false")" }
            ))
            .textFieldStyle(.roundedBorder)
            
            HStack {
                Text("目标浏览器:").font(.caption)
                Picker("", selection: Binding(
                    get: { browser },
                    set: { action.parameter = "\(url)|\($0)|\(silent ? "true" : "false")|\(incognito ? "true" : "false")" }
                )) {
                    Text("🚀 内置开发者浏览器").tag("InternalBrowser")
                    Text("系统默认浏览器").tag("System")
                    Text("Safari").tag("Safari")
                    Text("Google Chrome").tag("Google Chrome")
                    Text("Microsoft Edge").tag("Microsoft Edge")
                }.labelsHidden().frame(width: 160)
            }
            
            HStack(spacing: 16) {
                Toggle("🥷 后台静默 (不抢夺焦点)", isOn: Binding(
                    get: { silent },
                    set: { action.parameter = "\(url)|\(browser)|\($0 ? "true" : "false")|\(incognito ? "true" : "false")" }
                ))
                .toggleStyle(.switch).controlSize(.mini).tint(.blue)
                
                // [✨智能交互] 仅当选中 Chromium 系浏览器时，开放无痕模式
                if browser.contains("Chrome") || browser.contains("Edge") {
                    Toggle("🕶️ 无痕模式", isOn: Binding(
                        get: { incognito },
                        set: { action.parameter = "\(url)|\(browser)|\(silent ? "true" : "false")|\($0 ? "true" : "false")" }
                    ))
                    .toggleStyle(.switch).controlSize(.mini).tint(.purple)
                }
            }
        }
    }
}

// MARK: - [系统与应用] 打开应用程序编辑器
/// 提供本地应用选取、进程选取、多开与后台静默控制
struct OpenAppEditor: View {
    @Binding var action: RPAAction
    
    var body: some View {
        let parts = action.parameter.components(separatedBy: "|")
        let appTarget = parts.count > 0 ? parts[0] : action.parameter
        let silent = parts.count > 1 ? (parts[1] == "true") : false
        let newInstance = parts.count > 2 ? (parts[2] == "true") : false // [✨新增] 多开能力
        
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("App名称/路径/包名(如 com.tencent.xinWeChat)", text: Binding(
                    get: { appTarget },
                    set: { action.parameter = "\($0)|\(silent ? "true" : "false")|\(newInstance ? "true" : "false")" }
                ))
                .textFieldStyle(.roundedBorder)
                
                Menu {
                    Button(action: {
                        let panel = NSOpenPanel()
                        panel.allowsMultipleSelection = false
                        panel.canChooseDirectories = false
                        panel.canChooseFiles = true
                        if #available(macOS 11.0, *) { panel.allowedContentTypes = [.application] }
                        panel.directoryURL = URL(fileURLWithPath: "/Applications")
                        
                        if panel.runModal() == .OK, let url = panel.url {
                            // [✨核心优化] 优先使用底层 Bundle ID，退化使用绝对路径
                            let target = Bundle(url: url)?.bundleIdentifier ?? url.path
                            action.parameter = "\(target)|\(silent ? "true" : "false")|\(newInstance ? "true" : "false")"
                            action.customName = "打开 \(url.deletingPathExtension().lastPathComponent)"
                        }
                    }) { Label("浏览本地应用程序...", systemImage: "folder.badge.magnifyingglass") }
                    
                    Divider()
                    
                    let runningApps = NSWorkspace.shared.runningApplications
                        .filter { $0.activationPolicy == .regular }
                        .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
                    
                    ForEach(runningApps, id: \.processIdentifier) { app in
                        if let name = app.localizedName, let bundleId = app.bundleIdentifier {
                            Button("\(name)") {
                                action.parameter = "\(bundleId)|\(silent ? "true" : "false")|\(newInstance ? "true" : "false")"
                                action.customName = "打开 \(name)"
                            }
                        }
                    }
                } label: { Image(systemName: "app.dashed") }.fixedSize()
                .help("从运行中或本地库中选择 App")
            }
            
            HStack(spacing: 16) {
                Toggle("🥷 后台静默启动", isOn: Binding(get: { silent }, set: { action.parameter = "\(appTarget)|\($0 ? "true" : "false")|\(newInstance ? "true" : "false")" }))
                    .toggleStyle(.switch).controlSize(.mini).tint(.blue)
                
                Toggle("👯‍♂️ 强制多开新实例", isOn: Binding(get: { newInstance }, set: { action.parameter = "\(appTarget)|\(silent ? "true" : "false")|\($0 ? "true" : "false")" }))
                    .toggleStyle(.switch).controlSize(.mini).tint(.purple)
            }
            
            Text("💡 推荐通过右侧图标选取。底层将提取 BundleID(包名) 彻底解决中英文名称识别失败的问题。").font(.caption2).foregroundColor(.secondary)
        }
    }
}

// MARK: - [逻辑与数据] 变量设置编辑器
/// 提供键值对的声明绑定
struct SetVariableEditor: View {
    @Binding var action: RPAAction
    
    var body: some View {
        let parts = action.parameter.components(separatedBy: "|")
        let key = parts.count > 0 ? parts[0] : ""
        let val = parts.count > 1 ? parts[1] : ""
        VStack(alignment: .leading, spacing: 8) {
            TextField("变量名 (例: name)", text: Binding(get: { key }, set: { action.parameter = "\($0)|\(val)" })).textFieldStyle(.roundedBorder)
            TextField("变量值", text: Binding(get: { val }, set: { action.parameter = "\(key)|\($0)" })).textFieldStyle(.roundedBorder)
            Text("设置后，后续节点可使用 {{变量名}} 调用。").font(.caption).foregroundColor(.secondary)
        }
    }
}

// MARK: - [逻辑与数据] HTTP 请求编辑器
/// 轻量级 API 调用配置
struct HTTPRequestEditor: View {
    @Binding var action: RPAAction
    
    var body: some View {
        let parts = action.parameter.components(separatedBy: "|")
        let url = parts.count > 0 ? parts[0] : ""
        let method = parts.count > 1 ? parts[1] : "GET"
        VStack(alignment: .leading, spacing: 8) {
            TextField("API 地址", text: Binding(get: { url }, set: { action.parameter = "\($0)|\(method)" })).textFieldStyle(.roundedBorder)
            Picker("请求方法", selection: Binding(get: { method }, set: { action.parameter = "\(url)|\($0)" })) {
                Text("GET").tag("GET")
                Text("POST").tag("POST")
            }
            Text("请求结果将自动存入 {{http_response}} 变量。").font(.caption).foregroundColor(.secondary)
        }
    }
}

// MARK: - [鼠标与键盘] 键盘输入编辑器
/// 支持速度调节与特殊宏指令写入
struct TypeTextEditor: View {
    @Binding var action: RPAAction
    
    var body: some View {
        let parts = action.parameter.components(separatedBy: "|")
        let textValue = parts.count > 0 ? parts[0] : action.parameter
        // [✨新增] 解析键盘敲击速度
        let speedMode = parts.count > 1 ? parts[1] : "normal"
        
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                // 使用垂直轴向的文本框，支持输入多行脚本和组合宏
                TextField("输入文本 (例如: Hello[ENTER])", text: Binding(
                    get: { textValue },
                    set: { action.parameter = "\($0)|\(speedMode)" }
                ), axis: .vertical)
                .lineLimit(3...6)
                .textFieldStyle(.roundedBorder)
                
                Menu {
                    Section("功能键") {
                        Button("[ENTER] 回车") { action.parameter = "\(textValue)[ENTER]|\(speedMode)" }
                        Button("[TAB] 缩进") { action.parameter = "\(textValue)[TAB]|\(speedMode)" }
                        Button("[ESC] 取消") { action.parameter = "\(textValue)[ESC]|\(speedMode)" }
                    }
                    Section("编辑操作") {
                        Button("全选 (CMD+A)") { action.parameter = "\(textValue)[CMD+A]|\(speedMode)" }
                        Button("复制 (CMD+C)") { action.parameter = "\(textValue)[CMD+C]|\(speedMode)" }
                        Button("粘贴 (CMD+V)") { action.parameter = "\(textValue)[CMD+V]|\(speedMode)" }
                    }
                    Section("全局变量") {
                        Button("剪贴板内容") { action.parameter = "\(textValue){{clipboard}}|\(speedMode)" }
                    }
                } label: { Image(systemName: "keyboard.badge.ellipsis") }.fixedSize()
            }
            
            HStack {
                Text("打字速度:").font(.caption).foregroundColor(.secondary)
                Picker("", selection: Binding(
                    get: { speedMode },
                    set: { action.parameter = "\(textValue)|\($0)" }
                )) {
                    Text("⚡️ 极速 (免延时)").tag("fast")
                    Text("🚶 普通 (标准机打)").tag("normal")
                    Text("🙋‍♂️ 拟人 (思考停顿)").tag("human")
                }.labelsHidden().pickerStyle(.segmented).frame(width: 250)
            }
        }
    }
}

// MARK: - [逻辑与数据] 延时编辑器
/// 配置动作强行阻塞时间
struct WaitEditor: View {
    @Binding var action: RPAAction
    
    var body: some View {
        HStack {
            TextField("秒数", text: $action.parameter).textFieldStyle(.roundedBorder)
            Text("秒")
        }
    }
}

// MARK: - [逻辑与数据] 脚本执行编辑器
/// 供 Shell 和 AppleScript 通用的多行文本域
struct RunScriptEditor: View {
    @Binding var action: RPAAction
    
    var body: some View {
        VStack(alignment: .leading) {
            TextEditor(text: $action.parameter)
                .font(.system(size: 11, design: .monospaced))
                .frame(height: 120)
                .padding(4)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(4)
            Text("支持变量插值，如 {{clipboard}}").font(.caption2).foregroundColor(.blue)
        }
    }
}

// MARK: - [逻辑与数据] 子工作流调用编辑器
/// 提供从系统中读取可用工作流并防止死循环的调用机制
struct CallWorkflowEditor: View {
    @Binding var action: RPAAction
    
    var body: some View {
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
    }
}

// MARK: - [逻辑与数据] Web 智能体节点编辑器
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

// MARK: - ✨原生UI元素交互 独立编辑器
struct UIInteractionEditor: View {
    @Binding var parameter: String
    @State private var isPicking = false
    
    // 参数格式: appName|role|title|actionType|extraValue|timeout|matchMode|targetIndex|ignoreError
    private var parts: [String] { parameter.components(separatedBy: "|") }
    
    private var appName: String { parts.count > 0 ? parts[0] : "" }
    private var role: String { parts.count > 1 ? parts[1] : "" }
    private var title: String { parts.count > 2 ? parts[2] : "" }
    private var actionType: String { parts.count > 3 ? (parts[3].isEmpty ? "click" : parts[3]) : "click" }
    private var extraValue: String { parts.count > 4 ? parts[4] : "" }
    private var timeout: String { parts.count > 5 ? (parts[5].isEmpty ? "5" : parts[5]) : "5" }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox("目标元素标识") {
                VStack(spacing: 8) {
                    HStack {
                        Button(action: {
                            isPicking = true
                            UIElementPicker.shared.startPicking { pickedApp, pickedRole, pickedTitle in
                                isPicking = false
                                if !pickedApp.isEmpty {
                                    updateBinding(index: 0, defaultVal: appName).wrappedValue = pickedApp
                                    updateBinding(index: 1, defaultVal: role).wrappedValue = pickedRole
                                    updateBinding(index: 2, defaultVal: title).wrappedValue = pickedTitle
                                }
                            }
                        }) {
                            Label(isPicking ? "正在拾取 (按 ESC 取消)..." : "🎯 拾取屏幕元素", systemImage: "scope")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(isPicking ? .orange : .blue)
                        Spacer()
                    }
                    Divider().padding(.vertical, 2)
                    
                    HStack {
                        Text("所属应用:").frame(width: 60, alignment: .trailing).foregroundColor(.secondary)
                        TextField("如: Safari", text: updateBinding(index: 0, defaultVal: appName))
                        
                        Menu {
                            let runningApps = NSWorkspace.shared.runningApplications
                                .filter { $0.activationPolicy == .regular }
                                .compactMap { $0.localizedName }.sorted()
                            ForEach(runningApps, id: \.self) { app in
                                Button(app) { updateBinding(index: 0, defaultVal: appName).wrappedValue = app }
                            }
                        } label: { Image(systemName: "app.dashed") }.fixedSize()
                    }
                    
                    HStack {
                        Text("元素角色:").frame(width: 60, alignment: .trailing).foregroundColor(.secondary)
                        TextField("如: AXButton", text: updateBinding(index: 1, defaultVal: role))
                    }
                    HStack {
                        Text("元素标题:").frame(width: 60, alignment: .trailing).foregroundColor(.secondary)
                        TextField("支持 {{变量}}", text: updateBinding(index: 2, defaultVal: title))
                    }
                    
                    // [✨新增] 高级匹配选项
                    HStack(spacing: 16) {
                        HStack {
                            Text("标题匹配:").font(.caption).foregroundColor(.secondary)
                            Picker("", selection: updateBinding(index: 6, defaultVal: "exact")) {
                                Text("精确一致").tag("exact")
                                Text("模糊包含").tag("contains")
                            }.labelsHidden().frame(width: 90)
                        }
                        
                        HStack {
                            Text("命中序号:").font(.caption).foregroundColor(.secondary)
                            Stepper(value: Binding<Int>(
                                get: { Int(updateBinding(index: 7, defaultVal: "0").wrappedValue) ?? 0 },
                                set: { newVal in updateBinding(index: 7, defaultVal: "0").wrappedValue = "\(newVal)" }
                            ), in: 0...50) {
                                Text("\(Int(updateBinding(index: 7, defaultVal: "0").wrappedValue) ?? 0)")
                                    .frame(minWidth: 20)
                            }
                        }.help("当页面上有多个同名元素时，指定操作第几个 (从 0 开始)")
                    }
                }
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
            }
            
            HStack {
                Text("操作类型:").font(.caption)
                Picker("", selection: updateBinding(index: 3, defaultVal: actionType)) {
                    Text("🖱️ 点击元素").tag("click")
                    Text("✍️ 写入文本").tag("write")
                    Text("📖 读取文本并保存").tag("read")
                }.labelsHidden().frame(width: 150)
            }
            
            if actionType == "write" {
                TextField("要写入的文本 (支持 {{变量}})", text: updateBinding(index: 4, defaultVal: extraValue))
                    .textFieldStyle(.roundedBorder)
            } else if actionType == "read" {
                TextField("保存至变量名 (如: extractedText)", text: updateBinding(index: 4, defaultVal: extraValue))
                    .textFieldStyle(.roundedBorder)
            }
            
            HStack(spacing: 16) {
                HStack {
                    Text("⏳ 探测超时:").font(.caption)
                    Stepper("\(timeout)s", value: Binding<Int>(
                        get: { Int(timeout) ?? 5 },
                        set: { newVal in updateBinding(index: 5, defaultVal: "5").wrappedValue = "\(newVal)" }
                    ), in: 1...30)
                    .font(.caption)
                }
                
                // [✨新增] 忽略错误继续执行 (软失败)
                Toggle("忽略错误并继续", isOn: Binding<Bool>(
                    get: { updateBinding(index: 8, defaultVal: "false").wrappedValue == "true" },
                    set: { newVal in updateBinding(index: 8, defaultVal: "false").wrappedValue = newVal ? "true" : "false" }
                )).toggleStyle(.switch).controlSize(.mini).tint(.orange)
            }
        }
    }
    
    private func updateBinding(index: Int, defaultVal: String) -> Binding<String> {
        Binding(
            get: { parts.count > index ? parts[index] : defaultVal },
            set: { newVal in
                var newParts = parts
                while newParts.count <= 8 { newParts.append("") }
                // 兼容旧数据的默认值填充
                if newParts[3].isEmpty { newParts[3] = "click" }
                if newParts[5].isEmpty { newParts[5] = "5" }
                if newParts[6].isEmpty { newParts[6] = "exact" }
                if newParts[7].isEmpty { newParts[7] = "0" }
                if newParts[8].isEmpty { newParts[8] = "false" }
                newParts[index] = newVal
                parameter = newParts.joined(separator: "|")
            }
        )
    }
}

// -----------------------------------------------------------------------------------
// 💡极客级辅助视图代码 (MiniDesktop, OCRMiniDesktop, 连接线绘制, 截屏工具等)
// -----------------------------------------------------------------------------------

// MARK: - 迷你桌面渲染器 (鼠标动作)
/// 可视化指示鼠标将要在屏幕上执行的坐标动作
struct MouseMiniDesktop: View {
    @Binding var point1Str: String
    @Binding var point2Str: String
    var isDrag: Bool
    var isRelative: Bool
    
    let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
    @State private var dragStartP1: CGPoint? = nil
    @State private var dragStartP2: CGPoint? = nil
    
    func getPoint(_ str: String, defaultPt: CGPoint) -> CGPoint {
        let parts = str.split(separator: ",")
        if parts.count == 2,
           let x = Double(parts[0].trimmingCharacters(in: .whitespaces)),
           let y = Double(parts[1].trimmingCharacters(in: .whitespaces)) {
            return CGPoint(x: x, y: y)
        }
        return defaultPt
    }
    
    var body: some View {
        GeometryReader { geo in
            let scaleX = geo.size.width / screen.width
            let scaleY = geo.size.height / screen.height
            
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.8))
                RoundedRectangle(cornerRadius: 6).stroke(Color.gray, lineWidth: 2)
                
                let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                
                if isRelative {
                    Path { p in
                        p.move(to: CGPoint(x: center.x, y: 0))
                        p.addLine(to: CGPoint(x: center.x, y: geo.size.height))
                        p.move(to: CGPoint(x: 0, y: center.y))
                        p.addLine(to: CGPoint(x: geo.size.width, y: center.y))
                    }.stroke(Color.white.opacity(0.2), lineWidth: 1)
                }
                
                let p1 = getPoint(point1Str, defaultPt: isRelative ? .zero : CGPoint(x: screen.width/2, y: screen.height/2))
                let vP1 = isRelative ? CGPoint(x: center.x + p1.x * scaleX, y: center.y + p1.y * scaleY) : CGPoint(x: p1.x * scaleX, y: p1.y * scaleY)
                
                if isDrag {
                    let p2 = getPoint(point2Str, defaultPt: isRelative ? .zero : CGPoint(x: screen.width/2 + 50, y: screen.height/2 + 50))
                    let vP2 = isRelative ? CGPoint(x: vP1.x + p2.x * scaleX, y: vP1.y + p2.y * scaleY) : CGPoint(x: p2.x * scaleX, y: p2.y * scaleY)
                    
                    Path { p in
                        p.move(to: vP1)
                        p.addLine(to: vP2)
                    }.stroke(Color.blue, style: StrokeStyle(lineWidth: 2, dash: [4, 4]))
                    
                    Circle()
                        .fill(Color.red)
                        .frame(width: 14, height: 14)
                        .position(vP2)
                        .overlay(Text("终").font(.system(size: 9)).position(vP2).foregroundColor(.white))
                        .gesture(
                            DragGesture()
                                .onChanged { val in
                                    if dragStartP2 == nil { dragStartP2 = p2 }
                                    if let start = dragStartP2 {
                                        point2Str = "\(Int(start.x + val.translation.width / scaleX)), \(Int(start.y + val.translation.height / scaleY))"
                                    }
                                }
                                .onEnded { _ in dragStartP2 = nil }
                        )
                }
                
                Circle()
                    .fill(Color.green)
                    .frame(width: 14, height: 14)
                    .position(vP1)
                    .overlay(Text(isDrag ? "起" : "点").font(.system(size: 9)).position(vP1).foregroundColor(.white))
                    .gesture(
                        DragGesture()
                            .onChanged { val in
                                if dragStartP1 == nil { dragStartP1 = p1 }
                                if let start = dragStartP1 {
                                    point1Str = "\(Int(start.x + val.translation.width / scaleX)), \(Int(start.y + val.translation.height / scaleY))"
                                }
                            }
                            .onEnded { _ in dragStartP1 = nil }
                    )
            }
        }.frame(height: 120)
    }
}

// MARK: - OCR区域截取迷你桌面
/// 用于展示和微调视觉搜索区域的缩略图组件
struct OCRMiniDesktop: View {
    @Binding var regionStr: String
    @Binding var offsetX: Double
    @Binding var offsetY: Double
    
    let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
    @State private var dragStartRegion: CGRect? = nil
    @State private var dragStartOffset: CGPoint? = nil
    
    var currentRegion: CGRect {
        let parts = regionStr.split(separator: ",")
        if parts.count == 4,
           let x = Double(parts[0].trimmingCharacters(in: .whitespaces)),
           let y = Double(parts[1].trimmingCharacters(in: .whitespaces)),
           let w = Double(parts[2].trimmingCharacters(in: .whitespaces)),
           let h = Double(parts[3].trimmingCharacters(in: .whitespaces)) {
            return CGRect(x: x, y: y, width: w, height: h)
        }
        return CGRect(x: 0, y: 0, width: screen.width, height: screen.height)
    }
    
    var body: some View {
        GeometryReader { geo in
            let scaleX = geo.size.width / screen.width
            let scaleY = geo.size.height / screen.height
            
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.8))
                RoundedRectangle(cornerRadius: 6).stroke(Color.gray, lineWidth: 2)
                
                let r = currentRegion
                let viewRect = CGRect(x: r.minX * scaleX, y: r.minY * scaleY, width: r.width * scaleX, height: r.height * scaleY)
                
                Rectangle()
                    .fill(Color.blue.opacity(0.3))
                    .border(Color.blue, width: 1)
                    .frame(width: max(viewRect.width, 10), height: max(viewRect.height, 10))
                    .offset(x: viewRect.minX, y: viewRect.minY)
                    .gesture(
                        DragGesture()
                            .onChanged { val in
                                if dragStartRegion == nil { dragStartRegion = r }
                                if let start = dragStartRegion {
                                    let newX = max(0, min(screen.width - start.width, start.minX + val.translation.width / scaleX))
                                    let newY = max(0, min(screen.height - start.height, start.minY + val.translation.height / scaleY))
                                    regionStr = "\(Int(newX)), \(Int(newY)), \(Int(start.width)), \(Int(start.height))"
                                }
                            }
                            .onEnded { _ in dragStartRegion = nil }
                    )
                
                let center = CGPoint(x: viewRect.midX, y: viewRect.midY)
                let offsetViewX = offsetX * scaleX
                let offsetViewY = offsetY * scaleY
                let target = CGPoint(x: center.x + offsetViewX, y: center.y + offsetViewY)
                
                Path { p in
                    p.move(to: center)
                    p.addLine(to: target)
                }.stroke(Color.red, style: StrokeStyle(lineWidth: 1, dash: [2,2]))
                
                Circle().fill(Color.green).frame(width: 6, height: 6).position(center)
                
                Circle()
                    .fill(Color.red)
                    .frame(width: 14, height: 14)
                    .position(target)
                    .overlay(Text("点").font(.system(size: 9)).position(target).foregroundColor(.white))
                    .gesture(
                        DragGesture()
                            .onChanged { val in
                                if dragStartOffset == nil { dragStartOffset = CGPoint(x: offsetX, y: offsetY) }
                                if let start = dragStartOffset {
                                    offsetX = start.x + val.translation.width / scaleX
                                    offsetY = start.y + val.translation.height / scaleY
                                }
                            }
                            .onEnded { _ in dragStartOffset = nil }
                    )
            }
        }.frame(height: 120)
    }
}

// MARK: - [✨重构] 鼠标操作编辑器（融合直观的屏幕拾取器）
struct MouseActionEditor: View {
    @Binding var parameter: String
    @State private var isPicking = false
    
    var body: some View {
        let parts = parameter.components(separatedBy: "|")
        let mouseType = parts.count > 0 ? parts[0] : "leftClick"
        // 兼容旧数据的异常
        let mouseVal1 = parts.count > 1 ? parts[1] : (parameter.contains(",") ? parameter : "0, 0")
        let mouseVal2 = parts.count > 2 ? parts[2] : "0, 0"
        let isRelative = parts.count > 3 ? (parts[3] == "true") : false
        
        let mainTab = mouseType.lowercased().contains("scroll") ? "scroll" : mouseType
        
        let updateParam = { (type: String, v1: String, v2: String, rel: Bool) in
            parameter = "\(type)|\(v1)|\(v2)|\(rel ? "true" : "false")"
        }
        
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: Binding(
                get: { mainTab },
                set: {
                    let newType = $0 == "scroll" ? "scrollDown" : $0
                    updateParam(newType, mouseVal1, mouseVal2, isRelative)
                }
            )) {
                Text("移动").tag("move")
                Text("点击").tag("leftClick")
                Text("右键").tag("rightClick")
                Text("双击").tag("doubleClick")
                Text("拖拽").tag("drag")
                Text("滚轮").tag("scroll")
            }
            .pickerStyle(.segmented)
            
            if mainTab != "scroll" {
                HStack {
                    Toggle("相对当前光标位置偏移", isOn: Binding(
                        get: { isRelative },
                        set: { updateParam(mouseType, mouseVal1, mouseVal2, $0) }
                    )).toggleStyle(.switch).controlSize(.mini)
                    
                    Spacer()
                    
                    // [✨新增] 一键实景拾取能力
                    Button(action: {
                        isPicking = true
                        ScreenPointPicker.shared.pickPoint { point in
                            isPicking = false
                            if let pt = point {
                                // 自动帮用户填入准确的坐标
                                updateParam(mouseType, "\(Int(pt.x)), \(Int(pt.y))", mouseVal2, isRelative)
                            }
                        }
                    }) {
                        Label(isPicking ? "正在拾取..." : "🎯 屏幕实景拾取", systemImage: "scope")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(isPicking ? .orange : .blue)
                    .controlSize(.small)
                }
                
                // 原有 MiniDesktop 依旧保留，作为微调和可视化反馈
                MouseMiniDesktop(
                    point1Str: Binding(get: { mouseVal1 }, set: { updateParam(mouseType, $0, mouseVal2, isRelative) }),
                    point2Str: Binding(get: { mouseVal2 }, set: { updateParam(mouseType, mouseVal1, $0, isRelative) }),
                    isDrag: mainTab == "drag",
                    isRelative: isRelative
                )
            } else {
                HStack {
                    Picker("方向", selection: Binding(get: { mouseType }, set: { updateParam($0, mouseVal1, mouseVal2, isRelative) })) {
                        Text("向下滚动").tag("scrollDown")
                        Text("向上滚动").tag("scrollUp")
                    }.frame(width: 150)
                    
                    TextField("滚动行数 (如: 5)", text: Binding(get: { mouseVal1 }, set: { updateParam(mouseType, $0, mouseVal2, isRelative) }))
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
    }
}

// MARK: - [AI与视觉] OCR文本识别交互编辑器
struct OCRActionEditor: View {
    @Binding var action: RPAAction
    @State private var isPickingRegion = false
    
    var body: some View {
        // [✨解析扩充到 14 个参数]
        let parts = action.parameter.components(separatedBy: "|")
        let targetText = parts.count > 0 ? parts[0] : action.parameter
        let legacyShouldClick = parts.count > 1 ? (parts[1] == "true") : true
        let regionStr = parts.count > 2 ? parts[2] : ""
        let targetApp = parts.count > 3 ? parts[3] : ""
        
        let actionType = parts.count > 4 ? parts[4] : (legacyShouldClick ? "leftClick" : "none")
        let matchMode = parts.count > 5 ? parts[5] : "contains"
        let timeout = parts.count > 6 ? parts[6] : "5.0"
        let targetIndex = parts.count > 7 ? parts[7] : "-1"
        let variableName = parts.count > 8 ? parts[8] : "ocr_result"
        let autoScroll = parts.count > 9 ? (parts[9] == "true") : false
        let fuzzyTolerance = parts.count > 10 ? parts[10] : "1"
        let enhanceContrast = parts.count > 11 ? (parts[11] == "true") : false
        
        // [✨新增] 滚屏高级配置
        let scrollDirection = parts.count > 12 ? parts[12] : "down"
        let scrollAmount = parts.count > 13 ? parts[13] : "5"
        
        let updateParam = { (t: String, aType: String, r: String, app: String, mode: String, tm: String, idx: String, varName: String, scroll: Bool, fuzzy: String, enhance: Bool, sDir: String, sAmt: String) in
            let c = (aType != "none" && aType != "waitVanish" && aType != "read")
            action.parameter = "\(t)|\(c ? "true" : "false")|\(r)|\(app)|\(aType)|\(mode)|\(tm)|\(idx)|\(varName)|\(scroll ? "true" : "false")|\(fuzzy)|\(enhance ? "true" : "false")|\(sDir)|\(sAmt)"
        }
        
        VStack(alignment: .leading, spacing: 12) {
            
            // 1. 目标设定与匹配规则
            VStack(alignment: .leading, spacing: 8) {
                TextField("要识别的目标文字 (支持正则)", text: Binding(get: { targetText }, set: { updateParam($0, actionType, regionStr, targetApp, matchMode, timeout, targetIndex, variableName, autoScroll, fuzzyTolerance, enhanceContrast, scrollDirection, scrollAmount) }))
                    .textFieldStyle(.roundedBorder)
                
                HStack {
                    Picker("匹配模式:", selection: Binding(get: { matchMode }, set: { updateParam(targetText, actionType, regionStr, targetApp, $0, timeout, targetIndex, variableName, autoScroll, fuzzyTolerance, enhanceContrast, scrollDirection, scrollAmount) })) {
                        Text("包含 (Contains)").tag("contains")
                        Text("精确等于 (Exact)").tag("exact")
                        Text("模糊纠错 (Fuzzy)").tag("fuzzy")
                        Text("正则 (Regex)").tag("regex")
                    }.frame(width: 180)
                    
                    if matchMode == "fuzzy" {
                        Text("容错字数:").font(.caption).foregroundColor(.orange)
                        TextField("1", text: Binding(get: { fuzzyTolerance }, set: { updateParam(targetText, actionType, regionStr, targetApp, matchMode, timeout, targetIndex, variableName, autoScroll, $0, enhanceContrast, scrollDirection, scrollAmount) }))
                            .textFieldStyle(.roundedBorder).frame(width: 30)
                    }
                    
                    Spacer()
                    
                    Text("命中序号:").font(.caption)
                    TextField("-1为智能", text: Binding(get: { targetIndex }, set: { updateParam(targetText, actionType, regionStr, targetApp, matchMode, timeout, $0, variableName, autoScroll, fuzzyTolerance, enhanceContrast, scrollDirection, scrollAmount) }))
                        .textFieldStyle(.roundedBorder).frame(width: 60)
                }
            }
            
            // 2. 目标 App 过滤器
            HStack {
                Text("限定 App:").font(.caption).frame(width: 60, alignment: .leading)
                TextField("留空为全屏智能扫描", text: Binding(get: { targetApp }, set: { updateParam(targetText, actionType, regionStr, $0, matchMode, timeout, targetIndex, variableName, autoScroll, fuzzyTolerance, enhanceContrast, scrollDirection, scrollAmount) }))
                    .textFieldStyle(.roundedBorder)
                
                Menu {
                    Button("🌐 内置开发者浏览器") {
                        updateParam(targetText, actionType, regionStr, "InternalBrowser", matchMode, timeout, targetIndex, variableName, autoScroll, fuzzyTolerance, enhanceContrast, scrollDirection, scrollAmount)
                    }
                    Divider()
                    
                    let runningApps = NSWorkspace.shared.runningApplications
                        .filter { $0.activationPolicy == .regular }
                        .compactMap { $0.localizedName }.sorted()
                    ForEach(runningApps, id: \.self) { appName in
                        Button(appName) { updateParam(targetText, actionType, regionStr, appName, matchMode, timeout, targetIndex, variableName, autoScroll, fuzzyTolerance, enhanceContrast, scrollDirection, scrollAmount) }
                    }
                } label: { Image(systemName: "list.bullet.rectangle.portrait") }
                .fixedSize()
            }
            
            Divider()
            
            // 3. 动作与变量设置区
            HStack {
                Picker("命中后动作:", selection: Binding(get: { actionType }, set: { updateParam(targetText, $0, regionStr, targetApp, matchMode, timeout, targetIndex, variableName, autoScroll, fuzzyTolerance, enhanceContrast, scrollDirection, scrollAmount) })) {
                    Text("左键点击").tag("leftClick")
                    Text("双击").tag("doubleClick")
                    Text("右键点击").tag("rightClick")
                    Text("鼠标悬停 (Hover)").tag("move")
                    Divider()
                    Text("读取文本存入变量").tag("read")
                    Text("仅等待出现").tag("none")
                    Text("等待消失 (Wait Vanish)").tag("waitVanish")
                }.pickerStyle(.menu).frame(width: 180)
                
                Spacer()
                
                Text("最大等待:").font(.caption)
                TextField("秒", text: Binding(get: { timeout }, set: { updateParam(targetText, actionType, regionStr, targetApp, matchMode, $0, targetIndex, variableName, autoScroll, fuzzyTolerance, enhanceContrast, scrollDirection, scrollAmount) }))
                    .textFieldStyle(.roundedBorder).frame(width: 40)
            }
            
            if actionType == "read" {
                HStack {
                    Image(systemName: "text.insert").foregroundColor(.orange)
                    Text("保存至变量:").font(.caption).foregroundColor(.secondary)
                    TextField("例如: order_id", text: Binding(get: { variableName }, set: { updateParam(targetText, actionType, regionStr, targetApp, matchMode, timeout, targetIndex, $0, autoScroll, fuzzyTolerance, enhanceContrast, scrollDirection, scrollAmount) }))
                        .textFieldStyle(.roundedBorder)
                }
                .padding(.vertical, 4)
                .transition(.opacity)
            }
            
            Divider()
            
            // 4. 空间与拾取区
            HStack {
                TextField("视觉搜索区域 (X,Y,宽,高)", text: Binding(get: { regionStr }, set: { updateParam(targetText, actionType, $0, targetApp, matchMode, timeout, targetIndex, variableName, autoScroll, fuzzyTolerance, enhanceContrast, scrollDirection, scrollAmount) }))
                    .textFieldStyle(.roundedBorder)
                Button(action: {
                    isPickingRegion = true
                    ScreenRegionPicker.shared.pickRegion { rect in
                        if let r = rect { updateParam(targetText, actionType, "\(Int(r.minX)), \(Int(r.minY)), \(Int(r.width)), \(Int(r.height))", targetApp, matchMode, timeout, targetIndex, variableName, autoScroll, fuzzyTolerance, enhanceContrast, scrollDirection, scrollAmount) }
                        isPickingRegion = false
                    }
                }) { Label("框选", systemImage: "viewfinder") }.buttonStyle(.bordered)
            }
            
            OCRMiniDesktop(regionStr: Binding(get: { regionStr }, set: { updateParam(targetText, actionType, $0, targetApp, matchMode, timeout, targetIndex, variableName, autoScroll, fuzzyTolerance, enhanceContrast, scrollDirection, scrollAmount) }), offsetX: $action.offsetX, offsetY: $action.offsetY)
            
            // 5. 高级能力开关与细化面板
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Toggle("未找到时自动滚屏", isOn: Binding(get: { autoScroll }, set: { updateParam(targetText, actionType, regionStr, targetApp, matchMode, timeout, targetIndex, variableName, $0, fuzzyTolerance, enhanceContrast, scrollDirection, scrollAmount) }))
                        .toggleStyle(.switch).controlSize(.small).tint(.blue)
                    
                    Spacer()
                    
                    Toggle("🌟 图像锐化增强", isOn: Binding(get: { enhanceContrast }, set: { updateParam(targetText, actionType, regionStr, targetApp, matchMode, timeout, targetIndex, variableName, autoScroll, fuzzyTolerance, $0, scrollDirection, scrollAmount) }))
                        .toggleStyle(.switch).controlSize(.small).tint(.orange)
                }
                
                // [✨新增] 滚屏配置下沉菜单
                if autoScroll {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.up.and.down").foregroundColor(.blue).font(.caption)
                        Picker("方向:", selection: Binding(get: { scrollDirection }, set: { updateParam(targetText, actionType, regionStr, targetApp, matchMode, timeout, targetIndex, variableName, autoScroll, fuzzyTolerance, enhanceContrast, $0, scrollAmount) })) {
                            Text("向下 (Scroll Down)").tag("down")
                            Text("向上 (Scroll Up)").tag("up")
                        }.frame(width: 140)
                        
                        Text("单次幅度(行):").font(.caption)
                        TextField("5", text: Binding(get: { scrollAmount }, set: { updateParam(targetText, actionType, regionStr, targetApp, matchMode, timeout, targetIndex, variableName, autoScroll, fuzzyTolerance, enhanceContrast, scrollDirection, $0) }))
                            .textFieldStyle(.roundedBorder).frame(width: 40)
                    }
                    .padding(.leading, 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
    }
}

// MARK: - ✨系统消息提醒 独立编辑器组件
struct NotificationEditor: View {
    @Binding var parameter: String
    
    // 动态计算属性，保证输入时的单向数据流与双向绑定安全
    private var parts: [String] { parameter.components(separatedBy: "|") }
    private var isOldFormat: Bool { parts.count == 1 && !parameter.contains("|") }
    
    private var title: String { isOldFormat ? "RPA 提醒" : (parts.count > 0 ? parts[0] : "RPA 提醒") }
    private var bodyText: String { isOldFormat ? parameter : (parts.count > 1 ? parts[1] : "") }
    private var notifyType: String { parts.count > 2 ? parts[2] : "banner" }
    private var playSound: Bool { parts.count > 3 ? (parts[3] == "true") : true }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("主标题 (支持 {{变量}})", text: Binding(
                get: { title },
                set: { parameter = "\($0)|\(bodyText)|\(notifyType)|\(playSound ? "true" : "false")" }
            )).textFieldStyle(.roundedBorder)
            
            // [✨修改] 开启垂直轴向，变成多行文本域
            TextField("详细内容 (支持换行和 {{变量}})", text: Binding(
                get: { bodyText },
                set: { parameter = "\(title)|\($0)|\(notifyType)|\(playSound ? "true" : "false")" }
            ), axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .lineLimit(3...8)
            
            HStack {
                Text("提醒方式:").font(.caption)
                Picker("", selection: Binding(
                    get: { notifyType },
                    set: { parameter = "\(title)|\(bodyText)|\($0)|\(playSound ? "true" : "false")" }
                )) {
                    Text("消息横幅 (后台闪过，不阻塞)").tag("banner")
                    Text("系统弹窗 (暂停流程，等待点击)").tag("alert")
                }.labelsHidden().frame(width: 200)
            }
            
            Toggle("🔊 播放提示音", isOn: Binding(
                get: { playSound },
                set: { parameter = "\(title)|\(bodyText)|\(notifyType)|\($0 ? "true" : "false")" }
            )).toggleStyle(.switch).controlSize(.mini).tint(.blue)
            
            if notifyType == "alert" {
                Text("⚠️ 流程运行到此节点时会暂停，直到您手动点击确定。")
                    .font(.caption2)
                    .foregroundColor(.orange)
            }
        }
    }
}

// MARK: - [逻辑与数据] 条件判断分支编辑器
/// 配置条件分支的左值、比较操作符和右值
struct ConditionEditor: View {
    @Binding var parameter: String
    
    var body: some View {
        let parts = parameter.components(separatedBy: "|")
        let leftValue = parts.count > 0 ? parts[0] : "{{clipboard}}"
        let op = parts.count > 1 ? parts[1] : "contains"
        let rightValue = parts.count > 2 ? parts[2] : ""
        
        HStack {
            TextField("左值", text: Binding(get: { leftValue }, set: { parameter = "\($0)|\(op)|\(rightValue)" }))
                .textFieldStyle(.roundedBorder)
            
            Picker("", selection: Binding(get: { op }, set: { parameter = "\(leftValue)|\($0)|\(rightValue)" })) {
                Text("包含").tag("contains")
                Text("等于").tag("==")
            }.frame(width: 80)
            
            TextField("对比值", text: Binding(get: { rightValue }, set: { parameter = "\(leftValue)|\(op)|\($0)" }))
                .textFieldStyle(.roundedBorder)
        }
    }
}

// MARK: - [✨修复] 框选视图安全重构
class RegionPickerView: NSView {
    var startPointCG: CGPoint?
    var currentPointCG: CGPoint?
    var startPointView: CGPoint?
    var currentPointView: CGPoint?
    var completion: ((CGRect) -> Void)?
    
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }
    
    override func mouseDown(with event: NSEvent) {
        startPointView = event.locationInWindow
        startPointCG = CGEvent(source: nil)?.location
        currentPointView = startPointView
        currentPointCG = startPointCG
    }
    
    override func mouseDragged(with event: NSEvent) {
        currentPointView = event.locationInWindow
        currentPointCG = CGEvent(source: nil)?.location
        needsDisplay = true
    }
    
    override func mouseUp(with event: NSEvent) {
        currentPointView = event.locationInWindow
        currentPointCG = CGEvent(source: nil)?.location
        needsDisplay = true
        
        guard let scg = startPointCG, let ccg = currentPointCG else {
            completion?(.zero)
            return
        }
        
        let w = abs(ccg.x - scg.x)
        let h = abs(ccg.y - scg.y)
        
        if w > 5 && h > 5 {
            completion?(CGRect(x: min(scg.x, ccg.x), y: min(scg.y, ccg.y), width: w, height: h))
        } else {
            completion?(.zero)
        }
    }
    
    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0, alpha: 0.4).set()
        bounds.fill()
        
        if let start = startPointView, let current = currentPointView {
            let rect = NSRect(
                x: min(start.x, current.x),
                y: min(start.y, current.y),
                width: abs(current.x - start.x),
                height: abs(current.y - start.y)
            )
            NSColor.clear.set()
            rect.fill(using: .copy)
            NSColor.systemRed.setStroke()
            let path = NSBezierPath(rect: rect)
            path.lineWidth = 2.0
            path.stroke()
        }
    }
}

class ScreenRegionPicker {
    static let shared = ScreenRegionPicker()
    private var window: NSWindow?
    private var eventMonitor: Any?
    
    @MainActor func pickRegion(completion: @escaping (CGRect?) -> Void) {
        if window != nil { return }
        
        NSApp.windows.first(where: { $0.className.contains("AppKitWindow") })?.miniaturize(nil)
        
        var totalRect = CGRect.zero
        for screen in NSScreen.screens {
            totalRect = totalRect.union(screen.frame)
        }
        
        let win = NSWindow(contentRect: totalRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        win.level = .screenSaver
        win.backgroundColor = .clear
        win.isOpaque = false
        win.hasShadow = false
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        
        let view = RegionPickerView()
        
        // [✨核心修复] 异步延迟释放，彻底杜绝 mouseUp 事件周期内销毁窗口导致的崩溃
        let cleanup = { [weak self] (rect: CGRect?) in
            DispatchQueue.main.async {
                if let monitor = self?.eventMonitor {
                    NSEvent.removeMonitor(monitor)
                    self?.eventMonitor = nil
                }
                self?.window?.close()
                self?.window = nil
                completion(rect)
                NSApp.windows.first(where: { $0.className.contains("AppKitWindow") })?.deminiaturize(nil)
            }
        }
        
        view.completion = { rect in
            cleanup(rect == .zero ? nil : rect)
        }
        
        win.contentView = view
        win.makeKeyAndOrderFront(nil)
        self.window = win
        
        self.eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // ESC 键取消
                cleanup(nil)
                return nil
            }
            return event
        }
    }
}

// MARK: - [✨重构] 深度 UI 元素拾取器 (Deep UI Element Picker)
class UIElementPicker {
    static let shared = UIElementPicker()
    
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isCleaningUp = false
    private var window: NSWindow?
    private var overlayView: UIElementOverlayView?
    private var pickCompletion: ((String, String, String) -> Void)?
    
    func startPicking(completion: @escaping (String, String, String) -> Void) {
        guard eventTap == nil else { return }
        self.pickCompletion = completion
        self.isCleaningUp = false
        
        if let screen = NSScreen.main {
            let win = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            win.isOpaque = false; win.backgroundColor = .clear; win.level = .screenSaver
            win.ignoresMouseEvents = true
            
            // [✨修复3] 关闭自动释放，让 Swift 的 ARC 完全接管 Window 内存生命周期，防止 Double Free
            win.isReleasedWhenClosed = false
            
            let overlay = UIElementOverlayView()
            win.contentView = overlay
            win.makeKeyAndOrderFront(nil)
            self.window = win; self.overlayView = overlay
        }
        
        let mask = (1 << CGEventType.mouseMoved.rawValue) | (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.keyDown.rawValue)
        
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let ref = refcon else { return Unmanaged.passUnretained(event) }
                let picker = Unmanaged<UIElementPicker>.fromOpaque(ref).takeUnretainedValue()
                
                if type == .keyDown {
                    if event.getIntegerValueField(.keyboardEventKeycode) == 53 { picker.finishPicking(app: "", role: "", title: "") }
                } else if type == .mouseMoved {
                    picker.handleMouseMove(event: event)
                } else if type == .leftMouseDown {
                    picker.handleMouseDown()
                    return nil // 吞噬点击事件
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        
        if let tap = eventTap {
            runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        } else { finishPicking(app: "", role: "", title: "") }
    }
    
    private func handleMouseMove(event: CGEvent) {
        let point = event.location
        var element: AXUIElement?
        let systemWide = AXUIElementCreateSystemWide()
        
        if AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &element) == .success, let el = element {
            var pos = CGPoint.zero; var size = CGSize.zero
            var posRef: CFTypeRef?; var sizeRef: CFTypeRef?
            
            // [✨修复2] 严格校验 CFGetTypeID，防止遇到不规范的第三方 App 时强转崩溃
            if AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posRef) == .success,
               let pVal = posRef, CFGetTypeID(pVal) == AXValueGetTypeID() {
                AXValueGetValue(pVal as! AXValue, .cgPoint, &pos)
            }
            if AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeRef) == .success,
               let sVal = sizeRef, CFGetTypeID(sVal) == AXValueGetTypeID() {
                AXValueGetValue(sVal as! AXValue, .cgSize, &size)
            }
            
            var pid: pid_t = 0
            AXUIElementGetPid(el, &pid)
            let app = NSRunningApplication(processIdentifier: pid)?.localizedName ?? ""
            
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef)
            let role = roleRef as? String ?? ""
            
            let title = extractComprehensiveTitle(from: el, depth: 0)
            
            DispatchQueue.main.async {
                self.overlayView?.update(rect: CGRect(origin: pos, size: size), app: app, role: role, title: title)
            }
        }
    }
    
    private func handleMouseDown() {
        let appName = overlayView?.cachedAppName ?? ""
        let role = overlayView?.cachedRole ?? ""
        let title = overlayView?.cachedTitle ?? ""
        
        if appName.isEmpty {
            finishPicking(app: "", role: "", title: "")
        } else {
            finishPicking(app: appName, role: role, title: title)
        }
    }
    
    // [✨修复1] 统一收口回调与清理逻辑，严格推入下一帧 Main 队列执行
    private func finishPicking(app: String, role: String, title: String) {
        guard !isCleaningUp else { return }
        isCleaningUp = true
        
        // 先挂起底层事件监听，防止后续多余鼠标事件打扰
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        
        // 🚨 核心改动：必须使用 DispatchQueue.main.async 异步派发！
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.pickCompletion?(app, role, title)
            self.performCleanup()
        }
    }
    
    private func performCleanup() {
        if let tap = eventTap {
            if let runLoop = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoop, .commonModes) }
            CFMachPortInvalidate(tap)
            eventTap = nil
        }
        runLoopSource = nil
        window?.close()
        window = nil
        overlayView = nil
        pickCompletion = nil // 释放闭包，断开 SwiftUI 视图绑定，防止内存泄漏
    }
    
    private func extractComprehensiveTitle(from element: AXUIElement, depth: Int = 0) -> String {
        if depth > 3 { return "" }
        var valRef: CFTypeRef?
        
        for attr in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXHelpAttribute] {
            if AXUIElementCopyAttributeValue(element, attr as CFString, &valRef) == .success,
               let str = valRef as? String, !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return str }
        }
        
        var childrenRef: CFTypeRef?
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
}

/////////////////////////////////////////////////////////
// MARK: - UI 元素拾取遮罩视图
////////////////////////////////////////////////////////

class UIElementOverlayView: NSView {
    var targetRect: CGRect = .zero
    var cachedAppName = ""; var cachedRole = ""; var cachedTitle = ""
    
    func update(rect: CGRect, app: String, role: String, title: String) {
        // macOS 屏幕物理坐标系 (Top-Left) 转 NSWindow 绘图坐标系 (Bottom-Left)
        guard let screenHeight = NSScreen.main?.frame.height else { return }
        let flippedY = screenHeight - rect.origin.y - rect.height
        
        self.targetRect = CGRect(x: rect.origin.x, y: flippedY, width: rect.width, height: rect.height)
        self.cachedAppName = app; self.cachedRole = role; self.cachedTitle = title
        self.needsDisplay = true
    }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard targetRect.width > 0 && targetRect.height > 0 else { return }
        
        // 绘制红色高亮框
        NSColor.systemRed.withAlphaComponent(0.4).setFill()
        NSColor.systemRed.setStroke()
        let path = NSBezierPath(rect: targetRect)
        path.lineWidth = 3; path.fill(); path.stroke()
        
        // 绘制悬浮信息面板
        let infoStr = " App: \(cachedAppName)\n Role: \(cachedRole)\n Title: \(cachedTitle.isEmpty ? "[未命名元素]" : cachedTitle) "
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .bold),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.7)
        ]
        let size = (infoStr as NSString).size(withAttributes: attrs)
        let textRect = CGRect(x: targetRect.origin.x, y: targetRect.origin.y + targetRect.height + 5, width: size.width, height: size.height)
        
        (infoStr as NSString).draw(in: textRect, withAttributes: attrs)
    }
}

// MARK: - [✨新增] 屏幕精准坐标拾取器
class PointPickerView: NSView {
    var completion: ((CGPoint) -> Void)?
    
    override func resetCursorRects() {
        // 使用系统原生的十字瞄准星光标
        addCursorRect(bounds, cursor: .crosshair)
    }
    
    override func mouseDown(with event: NSEvent) {
        // 获取全局的绝对物理坐标 (左上角原点，与 CGEvent 体系完美契合)
        if let cgLoc = CGEvent(source: nil)?.location {
            completion?(cgLoc)
        } else {
            completion?(.zero)
        }
    }
    
    override func draw(_ dirtyRect: NSRect) {
        // 绘制微弱的全屏遮罩，暗示正在拾取
        NSColor(white: 0, alpha: 0.15).set()
        bounds.fill()
    }
}

class ScreenPointPicker {
    static let shared = ScreenPointPicker()
    private var window: NSWindow?
    private var eventMonitor: Any?
    
    @MainActor func pickPoint(completion: @escaping (CGPoint?) -> Void) {
        if window != nil { return }
        
        // 暂时隐藏主窗口防遮挡
        NSApp.windows.first(where: { $0.className.contains("AppKitWindow") })?.miniaturize(nil)
        
        var totalRect = CGRect.zero
        for screen in NSScreen.screens {
            totalRect = totalRect.union(screen.frame)
        }
        
        let win = NSWindow(contentRect: totalRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        win.level = .screenSaver
        win.backgroundColor = .clear
        win.isOpaque = false
        win.hasShadow = false
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        
        let view = PointPickerView()
        
        let cleanup = { [weak self] (point: CGPoint?) in
            DispatchQueue.main.async {
                if let monitor = self?.eventMonitor {
                    NSEvent.removeMonitor(monitor)
                    self?.eventMonitor = nil
                }
                self?.window?.close()
                self?.window = nil
                completion(point)
                NSApp.windows.first(where: { $0.className.contains("AppKitWindow") })?.deminiaturize(nil)
            }
        }
        
        view.completion = { point in
            cleanup(point)
        }
        
        win.contentView = view
        win.makeKeyAndOrderFront(nil)
        self.window = win
        
        // 支持 ESC 退出
        self.eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                cleanup(nil)
                return nil
            }
            return event
        }
    }
}
