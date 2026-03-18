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
        case .askUserInput:     AskUserInputEditor(action: $action)
        case .callWorkflow:     CallWorkflowEditor(action: $action)
        case .fileOperation:    FileOperationEditor(action: $action)
        case .dataExtraction:   DataExtractionEditor(action: $action)
        case .windowOperation:  WindowOperationEditor(action: $action)
        case .loopItems:        LoopItemsEditor(action: $action)
        case .ocrExtract:       OCRExtractEditor(action: $action)
        case .aiVisionLocator:  AIVisionLocatorEditor(action: $action)
        case .aiDataParse:      AITextParseEditor(action: $action)
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
                    Section("导航操作") {
                        Button("到顶部 (CMD+UP)") { action.parameter = "\(textValue)[CMD+UP]|\(speedMode)" }
                        Button("到底部 (CMD+DOWN)") { action.parameter = "\(textValue)[CMD+DOWN]|\(speedMode)" }
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
                }.labelsHidden().pickerStyle(.segmented)
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

// MARK: - [人机协同] 人工介入与提问编辑器
/// 暂停流程，向用户弹窗索要输入或确认
struct AskUserInputEditor: View {
    @Binding var action: RPAAction
    
    var body: some View {
        // 参数格式: 提示语 | 弹窗类型(input/confirm) | 超时时间 | 保存变量
        let parts = action.parameter.components(separatedBy: "|")
        let promptText = parts.count > 0 ? parts[0] : "请输入验证码："
        let dialogType = parts.count > 1 ? parts[1] : "input"
        let timeout = parts.count > 2 ? parts[2] : "60"
        let targetVar = parts.count > 3 ? parts[3] : "user_input"
        
        let updateParam = { (pt: String, dt: String, tm: String, tv: String) in
            action.parameter = "\\(pt)|\\(dt)|\\(tm)|\\(tv)"
        }
        
        VStack(alignment: .leading, spacing: 14) {
            GroupBox("🙋‍♂️ 提问与提示内容") {
                VStack(alignment: .leading) {
                    TextEditor(text: Binding(
                        get: { promptText },
                        set: { updateParam($0, dialogType, timeout, targetVar) }
                    ))
                    .font(.system(size: 13))
                    .frame(height: 50)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3)))
                }.padding(4)
            }
            
            HStack {
                Text("交互模式:").font(.caption)
                Picker("", selection: Binding(get: { dialogType }, set: { updateParam(promptText, $0, timeout, targetVar) })) {
                    Text("⌨️ 文本输入 (如验证码)").tag("input")
                    Text("✅ 确认/取消 (审批决策)").tag("confirm")
                }.labelsHidden().frame(width: 180)
            }
            
            if dialogType == "input" {
                HStack {
                    Image(systemName: "tray.and.arrow.down").foregroundColor(.orange)
                    Text("输入存入变量:").font(.caption).foregroundColor(.secondary)
                    TextField("变量名", text: Binding(get: { targetVar }, set: { updateParam(promptText, dialogType, timeout, $0) }))
                        .textFieldStyle(.roundedBorder)
                }
            }
            
            HStack {
                Text("⏳ 等待超时:").font(.caption)
                TextField("60", text: Binding(get: { timeout }, set: { updateParam(promptText, dialogType, $0, targetVar) }))
                    .textFieldStyle(.roundedBorder).frame(width: 40)
                Text("秒 (超时将走向失败分支)").font(.caption)
            }
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
                        Text("Google Chrome").tag("Google Chrome")
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

// MARK: - [✨修复] 鼠标操作编辑器（包含占位符机制防弹回）
struct MouseActionEditor: View {
    @Binding var parameter: String
    @State private var isPicking = false
    
    var body: some View {
        let parts = parameter.components(separatedBy: "|")
        let mouseType = parts.count > 0 ? parts[0] : "leftClick"
        let mouseVal1 = parts.count > 1 ? parts[1] : (parameter.contains(",") ? parameter : "0, 0")
        let mouseVal2 = parts.count > 2 ? parts[2] : "0, 0"
        let isRelative = parts.count > 3 ? (parts[3] == "true") : false
        
        // [✨核心修复] 解析底层特殊占位符
        let rawTargetApp = parts.count > 4 ? parts[4] : ""
        let targetApp = rawTargetApp == "__WAIT_INPUT__" ? "" : rawTargetApp
        
        let mainTab = mouseType.lowercased().contains("scroll") ? "scroll" : mouseType
        
        // 衍生当前的坐标模式用于 UI 绑定：此时依据 rawTargetApp 判断，即使是占位符也能维持住 window 状态
        let currentMode = isRelative ? "cursor" : (!rawTargetApp.isEmpty ? "window" : "screen")
        
        let updateParam = { (type: String, v1: String, v2: String, mode: String, app: String) in
            let rel = (mode == "cursor")
            // [✨核心修复] 如果切换到了 window 模式但应用名是空的，写入占位符维持 window 状态不弹回
            let finalApp = (mode == "window") ? (app.isEmpty ? "__WAIT_INPUT__" : app) : ""
            parameter = "\(type)|\(v1)|\(v2)|\(rel ? "true" : "false")|\(finalApp)"
        }
        
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: Binding(
                get: { mainTab },
                set: {
                    let newType = $0 == "scroll" ? "scrollDown" : $0
                    updateParam(newType, mouseVal1, mouseVal2, currentMode, targetApp)
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
                VStack(spacing: 8) {
                    HStack {
                        Text("坐标基准:").font(.caption).foregroundColor(.secondary)
                        Picker("", selection: Binding(
                            get: { currentMode },
                            set: { updateParam(mouseType, mouseVal1, mouseVal2, $0, targetApp) }
                        )) {
                            Text("🖥️ 全屏绝对坐标").tag("screen")
                            Text("🖱️ 当前光标相对偏移").tag("cursor")
                            Text("🪟 指定应用窗口内相对坐标").tag("window")
                        }
                        .pickerStyle(.menu)
                        .frame(width: 220)
                        
                        Spacer()
                    }
                    
                    // 当选择窗口内相对坐标时，显示 App 选择器
                    if currentMode == "window" {
                        HStack {
                            Text("目标应用:").font(.caption).foregroundColor(.secondary)
                            TextField("如: Safari", text: Binding(
                                get: { targetApp },
                                set: { updateParam(mouseType, mouseVal1, mouseVal2, currentMode, $0) }
                            )).textFieldStyle(.roundedBorder)
                            
                            Menu {
                                let runningApps = NSWorkspace.shared.runningApplications
                                    .filter { $0.activationPolicy == .regular }
                                    .compactMap { $0.localizedName }.sorted()
                                ForEach(runningApps, id: \.self) { app in
                                    // 用户从菜单选择后，真实的应用名会覆盖掉占位符
                                    Button(app) { updateParam(mouseType, mouseVal1, mouseVal2, currentMode, app) }
                                }
                            } label: { Image(systemName: "app.dashed") }.fixedSize()
                        }
                    }
                }
                .padding(8)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(6)
                
                HStack {
                    TextField("坐标 (X, Y)", text: Binding(
                        get: { mouseVal1 },
                        set: { updateParam(mouseType, $0, mouseVal2, currentMode, targetApp) }
                    )).textFieldStyle(.roundedBorder)
                    
                    Button(action: {
                        isPicking = true
                        ScreenPointPicker.shared.pickPoint { point in
                            isPicking = false
                            if let pt = point {
                                var finalX = Int(pt.x)
                                var finalY = Int(pt.y)
                                
                                if currentMode == "window" && !targetApp.isEmpty {
                                    if let appFrame = getAppWindowFrame(appName: targetApp) {
                                        finalX -= Int(appFrame.minX)
                                        finalY -= Int(appFrame.minY)
                                    }
                                }
                                updateParam(mouseType, "\(finalX), \(finalY)", mouseVal2, currentMode, targetApp)
                            }
                        }
                    }) {
                        Label(isPicking ? "正在拾取..." : "🎯 屏幕实景拾取", systemImage: "scope")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(isPicking ? .orange : .blue)
                    .controlSize(.small)
                }
                
                MouseMiniDesktop(
                    point1Str: Binding(get: { mouseVal1 }, set: { updateParam(mouseType, $0, mouseVal2, currentMode, targetApp) }),
                    point2Str: Binding(get: { mouseVal2 }, set: { updateParam(mouseType, mouseVal1, $0, currentMode, targetApp) }),
                    isDrag: mainTab == "drag",
                    isRelative: currentMode == "cursor"
                )
            } else {
                HStack {
                    Picker("方向", selection: Binding(get: { mouseType }, set: { updateParam($0, mouseVal1, mouseVal2, currentMode, targetApp) })) {
                        Text("向下滚动").tag("scrollDown")
                        Text("向上滚动").tag("scrollUp")
                    }.frame(width: 150)
                    
                    TextField("滚动行数 (如: 5)", text: Binding(get: { mouseVal1 }, set: { updateParam(mouseType, $0, mouseVal2, currentMode, targetApp) }))
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
    }
    
    private func getAppWindowFrame(appName: String) -> CGRect? {
        let options = CGWindowListOption(arrayLiteral: .excludeDesktopElements, .optionOnScreenOnly)
        guard let windowListInfo = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return nil }
        
        for info in windowListInfo {
            if let ownerName = info[kCGWindowOwnerName as String] as? String, ownerName == appName {
                if let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                   let rect = CGRect(dictionaryRepresentation: boundsDict) {
                    return rect
                }
            }
        }
        return nil
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

// MARK: - ✨系统消息提醒 独立编辑器组件 (重构优化版)
struct NotificationEditor: View {
    @Binding var parameter: String
    
    // 参数格式约定: title | bodyText | notifyType | playSound
    //             标题   | 内容     | 展现形式     | 是否发声
    // 采用计算属性安全补齐参数，保证双向绑定的稳定与安全，彻底抛弃旧版格式兼容
    private var parts: [String] {
        var p = parameter.components(separatedBy: "|")
        while p.count < 4 { p.append("") }
        return p
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            
            GroupBox("通知内容") {
                VStack(spacing: 10) {
                    HStack {
                        Text("主标题:").font(.caption).foregroundColor(.secondary).frame(width: 50, alignment: .trailing)
                        TextField("支持 {{变量}}", text: updateBinding(index: 0, defaultVal: "RPA 提醒"))
                            .textFieldStyle(.roundedBorder)
                    }
                    
                    HStack(alignment: .top) {
                        Text("详细内容:").font(.caption).foregroundColor(.secondary).frame(width: 50, alignment: .trailing).padding(.top, 4)
                        TextField("支持换行和 {{变量}}", text: updateBinding(index: 1, defaultVal: ""), axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(3...6)
                    }
                }
                .padding(.vertical, 4)
            }
            
            GroupBox("交互行为") {
                VStack(spacing: 10) {
                    HStack {
                        Text("提醒方式:").font(.caption).foregroundColor(.secondary).frame(width: 60, alignment: .trailing)
                        Picker("", selection: updateBinding(index: 2, defaultVal: "banner")) {
                            Text("消息横幅 (后台闪过，不阻塞)").tag("banner")
                            Text("系统弹窗 (暂停流程，等待点击)").tag("dialog")
                        }
                        .labelsHidden()
                        .frame(width: 220)
                        
                        Spacer()
                    }
                    
                    HStack {
                        Text("附加效果:").font(.caption).foregroundColor(.secondary).frame(width: 60, alignment: .trailing)
                        Toggle("🔊 播放系统提示音", isOn: Binding<Bool>(
                            get: { updateBinding(index: 3, defaultVal: "true").wrappedValue == "true" },
                            set: { newVal in updateBinding(index: 3, defaultVal: "true").wrappedValue = newVal ? "true" : "false" }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .tint(.blue)
                        
                        Spacer()
                    }
                }
                .padding(.vertical, 4)
            }
            
            // 针对弹窗模式给予用户的明确警告
            if parts[2] == "dialog" {
                Text("⚠️ 注意：流程运行到此节点时会被完全挂起，直到您手动点击弹窗的 [确定] 才会继续执行后续动作。")
                    .font(.caption2)
                    .foregroundColor(.orange)
                    .padding(.top, 2)
            }
        }
    }
    
    // 安全的双向绑定构造器
    private func updateBinding(index: Int, defaultVal: String) -> Binding<String> {
        Binding(
            get: {
                let currentVal = parts[index]
                return currentVal.isEmpty && index == 0 ? defaultVal : currentVal // 仅对标题做默认值视觉填充
            },
            set: { newVal in
                var newParts = parts
                // 若出现极度异常的情况，兜底空值
                if newParts[0].isEmpty { newParts[0] = "RPA 提醒" }
                if newParts[2].isEmpty { newParts[2] = "banner" }
                if newParts[3].isEmpty { newParts[3] = "true" }
                
                newParts[index] = newVal
                parameter = newParts.joined(separator: "|")
            }
        )
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
    // [✨修复1] 引入弱引用记录拾取前的真实主窗口，彻底抛弃危险的 className 扫描
    private weak var previousMainWindow: NSWindow?
    
    @MainActor func pickRegion(completion: @escaping (CGRect?) -> Void) {
        if window != nil { return }
        
        // 安全获取当前可见的主窗口并最小化
        previousMainWindow = NSApp.windows.first(where: { $0.isKeyWindow || ($0.className.contains("AppKitWindow") && $0.isVisible) })
        previousMainWindow?.miniaturize(nil)
        
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
        win.isReleasedWhenClosed = false
        
        let view = RegionPickerView()
        
        let cleanup = { [weak self] (rect: CGRect?) in
            // [✨修复2] 先仅仅在视觉上隐藏窗口，阻断后续误触，但内存不销毁
            self?.window?.orderOut(nil)
            
            // [✨修复3] 强制延迟 0.15 秒，让底层 AppKit 的 MouseUp 事件循环彻底走完，避免强杀报错
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                if let monitor = self?.eventMonitor {
                    NSEvent.removeMonitor(monitor)
                    self?.eventMonitor = nil
                }
                
                self?.window?.close()
                self?.window = nil
                completion(rect)
                
                // [✨修复4] 安全、精准地恢复记录的主窗口
                self?.previousMainWindow?.deminiaturize(nil)
                self?.previousMainWindow = nil
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

// MARK: - [逻辑与数据] 文件操作编辑器
/// 提供对本地纯文本、CSV 等格式文件的读、写、追加操作
struct FileOperationEditor: View {
    @Binding var action: RPAAction
    
    var body: some View {
        let parts = action.parameter.components(separatedBy: "|")
        let opType = parts.count > 0 ? parts[0] : "read"
        let filePath = parts.count > 1 ? parts[1] : ""
        let contentOrVar = parts.count > 2 ? parts[2] : ""
        
        let updateParam = { (t: String, p: String, c: String) in
            action.parameter = "\(t)|\(p)|\(c)"
        }
        
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("操作类型:").font(.caption)
                Picker("", selection: Binding(get: { opType }, set: { updateParam($0, filePath, contentOrVar) })) {
                    Text("📖 读取文件至变量").tag("read")
                    Text("✍️ 覆写内容至文件").tag("write")
                    Text("➕ 追加内容至文件").tag("append")
                    Text("🔍 检测文件是否存在").tag("exists")
                }.labelsHidden().frame(width: 180)
            }
            
            HStack {
                TextField("文件绝对路径 (支持 {{变量}})", text: Binding(get: { filePath }, set: { updateParam(opType, $0, contentOrVar) }))
                    .textFieldStyle(.roundedBorder)
                
                Button(action: {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = false
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url {
                        updateParam(opType, url.path, contentOrVar)
                    }
                }) { Image(systemName: "folder") }
            }
            
            Divider()
            
            if opType == "read" || opType == "exists" {
                HStack {
                    Image(systemName: "tray.and.arrow.down").foregroundColor(.orange)
                    Text("结果存入变量:").font(.caption).foregroundColor(.secondary)
                    TextField("例如: fileData", text: Binding(get: { contentOrVar }, set: { updateParam(opType, filePath, $0) }))
                        .textFieldStyle(.roundedBorder)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("写入的内容 (支持 {{变量}}):").font(.caption).foregroundColor(.secondary)
                    TextEditor(text: Binding(get: { contentOrVar }, set: { updateParam(opType, filePath, $0) }))
                        .font(.system(size: 12))
                        .frame(height: 80)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3)))
                }
            }
        }
    }
}

// MARK: - [逻辑与数据] 数据提取与清洗编辑器
/// 提供 JSON 解析和 正则表达式 提取能力
struct DataExtractionEditor: View {
    @Binding var action: RPAAction
    
    var body: some View {
        let parts = action.parameter.components(separatedBy: "|")
        let sourceData = parts.count > 0 ? parts[0] : "{{http_response}}"
        let extractType = parts.count > 1 ? parts[1] : "json"
        let rule = parts.count > 2 ? parts[2] : ""
        let targetVar = parts.count > 3 ? parts[3] : "extracted_value"
        
        let updateParam = { (s: String, t: String, r: String, v: String) in
            action.parameter = "\(s)|\(t)|\(r)|\(v)"
        }
        
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("数据来源:").font(.caption)
                TextField("如 {{http_response}}", text: Binding(get: { sourceData }, set: { updateParam($0, extractType, rule, targetVar) }))
                    .textFieldStyle(.roundedBorder)
            }
            
            HStack {
                Text("提取方式:").font(.caption)
                Picker("", selection: Binding(get: { extractType }, set: { updateParam(sourceData, $0, rule, targetVar) })) {
                    Text("JSON 键值 (Key)").tag("json")
                    Text("正则表达式 (Regex)").tag("regex")
                }.labelsHidden().frame(width: 160)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(extractType == "json" ? "JSON 提取规则 (例如: data.user.id)" : "正则提取规则 (例如: \\d{4,})").font(.caption).foregroundColor(.secondary)
                TextField("提取规则", text: Binding(get: { rule }, set: { updateParam(sourceData, extractType, $0, targetVar) }))
                    .textFieldStyle(.roundedBorder)
            }
            
            HStack {
                Image(systemName: "tray.and.arrow.down").foregroundColor(.orange)
                Text("结果存入变量:").font(.caption).foregroundColor(.secondary)
                TextField("变量名", text: Binding(get: { targetVar }, set: { updateParam(sourceData, extractType, rule, $0) }))
                    .textFieldStyle(.roundedBorder)
            }
        }
    }
}

// MARK: - [系统与应用] 窗口控制编辑器
struct WindowOperationEditor: View {
    @Binding var action: RPAAction
    
    var body: some View {
        let parts = action.parameter.components(separatedBy: "|")
        let appName = parts.count > 0 ? parts[0] : ""
        let operation = parts.count > 1 ? parts[1] : "maximize" // maximize, minimize, close, bounds
        let boundsRect = parts.count > 2 ? parts[2] : "0, 0, 800, 600"
        
        let updateParam = { (app: String, op: String, bounds: String) in
            action.parameter = "\(app)|\(op)|\(bounds)"
        }
        
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("目标应用:").font(.caption).foregroundColor(.secondary)
                TextField("如: Safari", text: Binding(get: { appName }, set: { updateParam($0, operation, boundsRect) }))
                    .textFieldStyle(.roundedBorder)
                
                Menu {
                    let runningApps = NSWorkspace.shared.runningApplications
                        .filter { $0.activationPolicy == .regular }
                        .compactMap { $0.localizedName }.sorted()
                    ForEach(runningApps, id: \.self) { app in
                        Button(app) { updateParam(app, operation, boundsRect) }
                    }
                } label: { Image(systemName: "app.dashed") }.fixedSize()
            }
            
            HStack {
                Text("执行动作:").font(.caption).foregroundColor(.secondary)
                Picker("", selection: Binding(get: { operation }, set: { updateParam(appName, $0, boundsRect) })) {
                    Text("🟩 全屏 / 最大化").tag("maximize")
                    Text("🟨 最小化到程序坞").tag("minimize")
                    Text("🟥 关闭窗口").tag("close")
                    Text("🔲 调整尺寸与位置").tag("bounds")
                }.labelsHidden().frame(width: 160)
            }
            
            if operation == "bounds" {
                HStack {
                    Text("窗口区域:").font(.caption).foregroundColor(.secondary)
                    TextField("X, Y, 宽, 高 (如: 0, 0, 800, 600)", text: Binding(get: { boundsRect }, set: { updateParam(appName, operation, $0) }))
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
    }
}

// MARK: - [逻辑与数据] 循环遍历编辑器
struct LoopItemsEditor: View {
    @Binding var action: RPAAction
    
    var body: some View {
        let parts = action.parameter.components(separatedBy: "|")
        let sourceArray = parts.count > 0 ? parts[0] : "{{json_array}}"
        let itemVarName = parts.count > 1 ? parts[1] : "item"
        let targetWorkflowId = parts.count > 2 ? parts[2] : ""
        
        let updateParam = { (src: String, item: String, wfId: String) in
            action.parameter = "\(src)|\(item)|\(wfId)"
        }
        
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("数据源 (JSON 数组):").font(.caption).foregroundColor(.secondary)
                TextField("支持 {{变量}}", text: Binding(get: { sourceArray }, set: { updateParam($0, itemVarName, targetWorkflowId) }))
                    .textFieldStyle(.roundedBorder)
            }
            
            HStack {
                Image(systemName: "tray.and.arrow.down").foregroundColor(.orange)
                Text("当前项存入变量:").font(.caption).foregroundColor(.secondary)
                TextField("例如: item", text: Binding(get: { itemVarName }, set: { updateParam(sourceArray, $0, targetWorkflowId) }))
                    .textFieldStyle(.roundedBorder)
            }
            
            Divider()
            
            VStack(alignment: .leading, spacing: 4) {
                Text("为每一项执行子工作流：").font(.caption).foregroundColor(.secondary)
                let allWorkflows = StorageManager.shared.load()
                let currentWorkflowId = allWorkflows.first(where: { wf in wf.actions.contains(where: { $0.id == action.id }) })?.id.uuidString ?? ""
                
                Picker("", selection: Binding(get: { targetWorkflowId }, set: { updateParam(sourceArray, itemVarName, $0) })) {
                    Text("请选择子工作流...").tag("")
                    ForEach(allWorkflows) { wf in
                        // 防死循环机制：排除自己
                        if wf.id.uuidString != currentWorkflowId {
                            Text(wf.name).tag(wf.id.uuidString)
                        }
                    }
                }
                .labelsHidden()
            }
            
            Text("💡 提示：此节点会解析数组，对于数组中的每一个元素，都会将该元素存入变量池中，然后同步调用一次选中的子工作流。").font(.caption2).foregroundColor(.blue)
        }
    }
}

// MARK: - [AI与视觉] AI 视觉元素定位交互编辑器 (终极版)
/// 支持目标窗口隔离截取、自定义区域框选、以及点击坐标偏移量设置
struct AIVisionLocatorEditor: View {
    @Binding var action: RPAAction
    @State private var isPickingRegion = false
    
    var body: some View {
        // 参数格式: 目标描述 | 动作类型 | 超时时间 | 失败是否忽略 | 目标App | 坐标偏移(X,Y) | 扫描区域(X,Y,W,H)
        let parts = action.parameter.components(separatedBy: "|")
        let targetDesc = parts.count > 0 ? parts[0] : ""
        let actionType = parts.count > 1 ? parts[1] : "leftClick"
        let timeout = parts.count > 2 ? parts[2] : "10"
        let ignoreError = parts.count > 3 ? (parts[3] == "true") : false
        let targetApp = parts.count > 4 ? parts[4] : ""
        let offsetStr = parts.count > 5 ? parts[5] : "0,0"
        let regionStr = parts.count > 6 ? parts[6] : ""
        
        let updateParam = { (desc: String, type: String, tm: String, ignore: Bool, app: String, off: String, reg: String) in
            action.parameter = "\(desc)|\(type)|\(tm)|\(ignore ? "true" : "false")|\(app)|\(off)|\(reg)"
        }
        
        VStack(alignment: .leading, spacing: 14) {
            GroupBox("🎯 视觉目标描述 (Prompt)") {
                VStack(alignment: .leading, spacing: 4) {
                    TextEditor(text: Binding(
                        get: { targetDesc },
                        set: { updateParam($0, actionType, timeout, ignoreError, targetApp, offsetStr, regionStr) }
                    ))
                    .font(.system(size: 12))
                    .frame(height: 50)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3)))
                    
                    Text("提示：如'右上角的齿轮设置图标'，大模型将返回该图标坐标。").font(.caption2).foregroundColor(.purple)
                }
                .padding(4)
            }
            
            GroupBox("🔍 扫描范围约束") {
                VStack(spacing: 10) {
                    HStack {
                        Text("限定应用:").font(.caption).foregroundColor(.secondary).frame(width: 60, alignment: .leading)
                        TextField("留空为扫描全屏幕", text: Binding(get: { targetApp }, set: { updateParam(targetDesc, actionType, timeout, ignoreError, $0, offsetStr, regionStr) }))
                        
                        Menu {
                            let runningApps = NSWorkspace.shared.runningApplications
                                .filter { $0.activationPolicy == .regular }
                                .compactMap { $0.localizedName }.sorted()
                            ForEach(runningApps, id: \.self) { appName in
                                Button(appName) { updateParam(targetDesc, actionType, timeout, ignoreError, appName, offsetStr, regionStr) }
                            }
                        } label: { Image(systemName: "app.dashed") }.fixedSize()
                    }
                    
                    HStack {
                        Text("限定区域:").font(.caption).foregroundColor(.secondary).frame(width: 60, alignment: .leading)
                        TextField("X, Y, 宽, 高 (留空为全视窗)", text: Binding(get: { regionStr }, set: { updateParam(targetDesc, actionType, timeout, ignoreError, targetApp, offsetStr, $0) }))
                        Button(action: {
                            isPickingRegion = true
                            ScreenRegionPicker.shared.pickRegion { rect in
                                if let r = rect { updateParam(targetDesc, actionType, timeout, ignoreError, targetApp, offsetStr, "\(Int(r.minX)), \(Int(r.minY)), \(Int(r.width)), \(Int(r.height))") }
                                isPickingRegion = false
                            }
                        }) { Label("拾取", systemImage: "viewfinder") }
                    }
                }
                .textFieldStyle(.roundedBorder)
            }
            
            HStack(spacing: 16) {
                HStack {
                    Text("定位动作:").font(.caption)
                    Picker("", selection: Binding(get: { actionType }, set: { updateParam(targetDesc, $0, timeout, ignoreError, targetApp, offsetStr, regionStr) })) {
                        Text("🖱️ 左键点击").tag("leftClick")
                        Text("🖱️ 双击").tag("doubleClick")
                        Text("🖱️ 右键点击").tag("rightClick")
                        Text("📍 仅移动").tag("move")
                    }.labelsHidden().frame(width: 100)
                }
                
                HStack {
                    Text("坐标偏移:").font(.caption)
                    TextField("X,Y", text: Binding(get: { offsetStr }, set: { updateParam(targetDesc, actionType, timeout, ignoreError, targetApp, $0, regionStr) }))
                        .textFieldStyle(.roundedBorder).frame(width: 60)
                }
            }
            
            HStack(spacing: 16) {
                HStack {
                    Text("⏳ AI超时:").font(.caption)
                    TextField("10", text: Binding(get: { timeout }, set: { updateParam(targetDesc, actionType, $0, ignoreError, targetApp, offsetStr, regionStr) }))
                        .textFieldStyle(.roundedBorder).frame(width: 40)
                    Text("秒").font(.caption)
                }
                
                Toggle("忽略错误并继续", isOn: Binding(
                    get: { ignoreError },
                    set: { updateParam(targetDesc, actionType, timeout, $0, targetApp, offsetStr, regionStr) }
                )).toggleStyle(.switch).controlSize(.mini).tint(.orange)
            }
        }
    }
}

// MARK: - [逻辑与数据] AI 智能数据结构化编辑器 (进阶版)
/// 支持强制 JSON Schema 模板校验约束
struct AITextParseEditor: View {
    @Binding var action: RPAAction
    
    var body: some View {
        let parts = action.parameter.components(separatedBy: "|")
        let sourceVar = parts.count > 0 ? parts[0] : "{{clipboard}}"
        let instruction = parts.count > 1 ? parts[1] : ""
        let targetVar = parts.count > 2 ? parts[2] : "parsed_data"
        let jsonTemplate = parts.count > 3 ? parts[3] : ""
        
        let updateParam = { (src: String, inst: String, tar: String, tpl: String) in
            action.parameter = "\(src)|\(inst)|\(tar)|\(tpl)"
        }
        
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("原始数据源:").font(.caption)
                TextField("如 {{clipboard}} 或 {{ocr_data}}", text: Binding(get: { sourceVar }, set: { updateParam($0, instruction, targetVar, jsonTemplate) }))
                    .textFieldStyle(.roundedBorder)
            }
            
            GroupBox("🧠 提取指令与结构要求") {
                VStack(alignment: .leading, spacing: 8) {
                    // [✨修复] 使用纯净编辑器替代 TextEditor
                    PlainCodeEditor(text: Binding(
                        get: { instruction },
                        set: { updateParam(sourceVar, $0, targetVar, jsonTemplate) }
                    ))
                    .frame(height: 50)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3)))
                    
                    Text("强制输出格式模板 (JSON Schema)：").font(.caption).foregroundColor(.secondary)
                    
                    // [✨修复] 使用纯净编辑器，彻底告别中文引号
                    PlainCodeEditor(text: Binding(
                        get: { jsonTemplate },
                        set: { updateParam(sourceVar, instruction, targetVar, $0) }
                    ))
                    .frame(height: 60)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.blue.opacity(0.3)))
                    
                    Text("例如填入: {\"name\": \"未知\", \"age\": 0}，可彻底消除下游 JSON 解析崩溃风险。").font(.caption2).foregroundColor(.blue)
                }
                .padding(4)
            }
            
            HStack {
                Image(systemName: "tray.and.arrow.down").foregroundColor(.orange)
                Text("结果存入变量:").font(.caption).foregroundColor(.secondary)
                TextField("变量名，例如: user_info", text: Binding(get: { targetVar }, set: { updateParam(sourceVar, instruction, $0, jsonTemplate) }))
                    .textFieldStyle(.roundedBorder)
            }
        }
    }
}


// -----------------------------------------------------------------------------------
// 💡极客级辅助视图代码 (MiniDesktop, OCRMiniDesktop, 连接线绘制, 截屏工具等)
// -----------------------------------------------------------------------------------

// MARK: - [✨新增] 屏幕精准坐标拾取器
class PointPickerView: NSView {
    var completion: ((CGPoint) -> Void)?
    
    override func resetCursorRects() {
        // 使用系统原生的十字瞄准星光标
        addCursorRect(bounds, cursor: .crosshair)
    }
    
    override func mouseDown(with event: NSEvent) {
        // 获取全局的绝对物理坐标 (左上角原点，与 CGEvent 体系完美契合)
        let cgLoc = CGEvent(source: nil)?.location ?? .zero
        
        // [✨核心修复] 必须异步派发！脱离当前 NSEvent 的事件循环周期。
        // 否则如果在 mouseDown 瞬间销毁 window，会导致 AppKit 底层野指针崩溃
        DispatchQueue.main.async {
            self.completion?(cgLoc)
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
        
        // [✨核心修复] 关闭自动释放，让 Swift 的 ARC 完全接管，防止 Window Double Free 崩溃
        win.isReleasedWhenClosed = false
        
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

// MARK: - 迷你桌面渲染器 (鼠标动作)
/// 可视化指示鼠标将要在屏幕上执行的坐标动作
struct MouseMiniDesktop: View {
    @Binding var point1Str: String
    @Binding var point2Str: String
    var isDrag: Bool
    var isRelative: Bool
    
    // [✨核心修复] 必须使用 screens.first (主屏幕)！因为 CGEvent 的 (0,0) 永远在主屏幕的左上角
    let screen = NSScreen.screens.first?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
    
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
                            // [✨核心修复] minimumDistance: 0 配合 val.location，摒弃 translation 累积误差
                            DragGesture(minimumDistance: 0)
                                .onChanged { val in
                                    if isRelative {
                                        let rawX = (val.location.x - vP1.x) / scaleX
                                        let rawY = (val.location.y - vP1.y) / scaleY
                                        point2Str = "\(Int(rawX)), \(Int(rawY))"
                                    } else {
                                        // 绝对坐标系：直接将手势所在画布的绝对位置换算为屏幕真实坐标
                                        let rawX = val.location.x / scaleX
                                        let rawY = val.location.y / scaleY
                                        let clampedX = max(0, min(screen.width, rawX))
                                        let clampedY = max(0, min(screen.height, rawY))
                                        point2Str = "\(Int(clampedX)), \(Int(clampedY))"
                                    }
                                }
                        )
                }
                
                Circle()
                    .fill(Color.green)
                    .frame(width: 14, height: 14)
                    .position(vP1)
                    .overlay(Text(isDrag ? "起" : "点").font(.system(size: 9)).position(vP1).foregroundColor(.white))
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { val in
                                if isRelative {
                                    let rawX = (val.location.x - center.x) / scaleX
                                    let rawY = (val.location.y - center.y) / scaleY
                                    point1Str = "\(Int(rawX)), \(Int(rawY))"
                                } else {
                                    let rawX = val.location.x / scaleX
                                    let rawY = val.location.y / scaleY
                                    let clampedX = max(0, min(screen.width, rawX))
                                    let clampedY = max(0, min(screen.height, rawY))
                                    point1Str = "\(Int(clampedX)), \(Int(clampedY))"
                                }
                            }
                    )
            }
        }
        .aspectRatio(screen.width / screen.height, contentMode: .fit)
        .frame(height: 120)
    }
}

// MARK: - OCR区域截取迷你桌面
/// 用于展示和微调视觉搜索区域的缩略图组件
struct OCRMiniDesktop: View {
    @Binding var regionStr: String
    @Binding var offsetX: Double
    @Binding var offsetY: Double
    
    // [✨核心修复] 同样使用第一主屏幕
    let screen = NSScreen.screens.first?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
    @State private var dragStartRegion: CGRect? = nil
    
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
                let absoluteCenter = CGPoint(x: r.midX, y: r.midY)
                
                let offsetViewX = offsetX * scaleX
                let offsetViewY = offsetY * scaleY
                let targetViewPt = CGPoint(x: center.x + offsetViewX, y: center.y + offsetViewY)
                
                Path { p in
                    p.move(to: center)
                    p.addLine(to: targetViewPt)
                }.stroke(Color.red, style: StrokeStyle(lineWidth: 1, dash: [2,2]))
                
                Circle().fill(Color.green).frame(width: 6, height: 6).position(center)
                
                Circle()
                    .fill(Color.red)
                    .frame(width: 14, height: 14)
                    .position(targetViewPt)
                    .overlay(Text("点").font(.system(size: 9)).position(targetViewPt).foregroundColor(.white))
                    .gesture(
                        // [✨核心修复] 使用画布绝对位置直接反推 Offset
                        DragGesture(minimumDistance: 0)
                            .onChanged { val in
                                let absoluteX = val.location.x / scaleX
                                let absoluteY = val.location.y / scaleY
                                
                                let clampedAbsX = max(0, min(screen.width, absoluteX))
                                let clampedAbsY = max(0, min(screen.height, absoluteY))
                                
                                offsetX = clampedAbsX - absoluteCenter.x
                                offsetY = clampedAbsY - absoluteCenter.y
                            }
                    )
            }
        }
        .aspectRatio(screen.width / screen.height, contentMode: .fit)
        .frame(height: 120)
    }
}

// MARK: - [AI与视觉] OCR 结构化全文提取编辑器
struct OCRExtractEditor: View {
    @Binding var action: RPAAction
    @State private var isPickingRegion = false
    
    var body: some View {
        // 参数格式: regionStr | targetApp | outputFormat | languages | level | variableName
        let parts = action.parameter.components(separatedBy: "|")
        let regionStr = parts.count > 0 ? parts[0] : ""
        let targetApp = parts.count > 1 ? parts[1] : ""
        let outputFormat = parts.count > 2 ? parts[2] : "json"
        let languages = parts.count > 3 ? parts[3] : "zh-Hans,en-US"
        let level = parts.count > 4 ? parts[4] : "accurate"
        let variableName = parts.count > 5 ? parts[5] : "ocr_data"
        
        let updateParam = { (r: String, app: String, fmt: String, lang: String, lvl: String, vName: String) in
            action.parameter = "\(r)|\(app)|\(fmt)|\(lang)|\(lvl)|\(vName)"
        }
        
        VStack(alignment: .leading, spacing: 14) {
            
            // 1. 范围设定
            GroupBox("🔍 扫描范围") {
                VStack(spacing: 10) {
                    HStack {
                        Text("限定应用:").font(.caption).foregroundColor(.secondary).frame(width: 60, alignment: .leading)
                        TextField("留空为扫描整个屏幕", text: Binding(get: { targetApp }, set: { updateParam(regionStr, $0, outputFormat, languages, level, variableName) }))
                        
                        Menu {
                            Button("🌐 内置开发者浏览器") { updateParam(regionStr, "InternalBrowser", outputFormat, languages, level, variableName) }
                            Divider()
                            let runningApps = NSWorkspace.shared.runningApplications
                                .filter { $0.activationPolicy == .regular }.compactMap { $0.localizedName }.sorted()
                            ForEach(runningApps, id: \.self) { appName in
                                Button(appName) { updateParam(regionStr, appName, outputFormat, languages, level, variableName) }
                            }
                        } label: { Image(systemName: "app.dashed") }.fixedSize()
                    }
                    
                    HStack {
                        Text("限定区域:").font(.caption).foregroundColor(.secondary).frame(width: 60, alignment: .leading)
                        TextField("X, Y, 宽, 高 (留空为全视窗)", text: Binding(get: { regionStr }, set: { updateParam($0, targetApp, outputFormat, languages, level, variableName) }))
                        Button(action: {
                            isPickingRegion = true
                            ScreenRegionPicker.shared.pickRegion { rect in
                                if let r = rect { updateParam("\(Int(r.minX)), \(Int(r.minY)), \(Int(r.width)), \(Int(r.height))", targetApp, outputFormat, languages, level, variableName) }
                                isPickingRegion = false
                            }
                        }) { Label("拾取", systemImage: "viewfinder") }
                    }
                }
                .textFieldStyle(.roundedBorder)
            }
            
            // 2. 引擎参数
            HStack(spacing: 16) {
                HStack {
                    Text("识别语言:").font(.caption)
                    Picker("", selection: Binding(get: { languages }, set: { updateParam(regionStr, targetApp, outputFormat, $0, level, variableName) })) {
                        Text("中文+英文").tag("zh-Hans,en-US")
                        Text("繁体中文").tag("zh-Hant,en-US")
                        Text("纯英文").tag("en-US")
                        Text("日文").tag("ja,en-US")
                        Text("韩文").tag("ko,en-US")
                    }.labelsHidden().frame(width: 100)
                }
                
                HStack {
                    Text("性能模式:").font(.caption)
                    Picker("", selection: Binding(get: { level }, set: { updateParam(regionStr, targetApp, outputFormat, languages, $0, variableName) })) {
                        Text("🎯 精准 (慢)").tag("accurate")
                        Text("⚡️ 极速 (快)").tag("fast")
                    }.labelsHidden().frame(width: 100)
                }
            }
            
            Divider()
            
            // 3. 输出设定
            HStack {
                Text("数据格式:").font(.caption)
                Picker("", selection: Binding(get: { outputFormat }, set: { updateParam(regionStr, targetApp, $0, languages, level, variableName) })) {
                    Text("结构化 JSON (带坐标宽高)").tag("json")
                    Text("纯文本合并 (按行)").tag("text")
                }.labelsHidden().frame(width: 180)
            }
            
            HStack {
                Image(systemName: "tray.and.arrow.down").foregroundColor(.orange)
                Text("保存至变量:").font(.caption).foregroundColor(.secondary)
                TextField("例如: ocr_data", text: Binding(get: { variableName }, set: { updateParam(regionStr, targetApp, outputFormat, languages, level, $0) }))
                    .textFieldStyle(.roundedBorder)
            }
            Text(outputFormat == "json" ? "💡 提示：JSON 格式将返回包含 text, x, y, width, height 的数组，其坐标可直接传给鼠标节点使用。" : "💡 提示：纯文本格式适合直接传给大模型进行阅读理解或摘要提取。")
                .font(.caption2).foregroundColor(.blue)
        }
    }
}


// MARK: - 公共的纯净代码编辑器 (禁用智能引号与拼写检查，专为 JSON 和脚本设计)
struct PlainCodeEditor: NSViewRepresentable {
    @Binding var text: String
    var minHeight: CGFloat = 60
    
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    
    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        
        textView.delegate = context.coordinator
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.textColor = NSColor.textColor
        
        // 核心修复：彻底关闭 macOS 的“智能替换”特性
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        //textView.isSmartInsertDeleteEnabled = false
        textView.allowsUndo = true
        
        return scrollView
    }
    
    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            let selectedRange = textView.selectedRange()
            textView.string = text
            textView.setSelectedRange(selectedRange)
        }
    }
    
    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PlainCodeEditor
        init(_ parent: PlainCodeEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}
