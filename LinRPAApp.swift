//
//  LinRPAApp.swift
//  LinRPA主程序

import SwiftUI

// 借助 AppDelegate 在系统完全就绪后设置状态栏模式
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
struct LinRPAApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup(id: "main-window") {
            ContentView()
        }
        
        // 注册知识库窗口，并指定 ID
        WindowGroup(id: "corpus-manager") {
            CorpusManagerView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 800, height: 600)
        
        // 注册独立的 Agent 监控窗口，赋予一个唯一 ID "agentMonitor"
        Window("WebAgent 感知与决策监控", id: "agentMonitor") {
            AgentMonitorView()
                // 强制应用暗色模式，让黑客/极客监控面板更有氛围感
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 800, height: 600) // 设置默认弹出尺寸
        
        // macOS 原生设置面板支持
        Settings {
            AISettingsView()
        }
    }
}

// MARK: - [✨修复] 全局环境变量管理
struct GlobalVariablesSettingsView: View {
    @State private var globalVars: [String: String] = [:]
    @State private var newKey: String = ""
    @State private var newValue: String = ""
    @State private var isSecureMode: Bool = true
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("全局环境变量")
                .font(.title2)
                .fontWeight(.bold)
            
            Text("在此配置的变量可通过 {{global.变量名}} 在任何工作流中调用。适合存放 API Key、通用账号等。")
                .font(.caption)
                .foregroundColor(.secondary)
            
            List {
                ForEach(globalVars.keys.sorted(), id: \.self) { key in
                    HStack {
                        Text(key)
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 150, alignment: .leading)
                        
                        Divider()
                        
                        // [✨防编译器超时] 使用抽离的 binding
                        SecureField("******", text: binding(for: key))
                            .textFieldStyle(.plain)
                        
                        Spacer()
                        
                        Button(action: { deleteVar(key: key) }) {
                            Image(systemName: "trash").foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 4)
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(minHeight: 200)
            
            HStack {
                TextField("新变量名 (如: api_key)", text: $newKey)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                
                if isSecureMode {
                    SecureField("变量值", text: $newValue)
                        .textFieldStyle(.roundedBorder)
                } else {
                    TextField("变量值", text: $newValue)
                        .textFieldStyle(.roundedBorder)
                }
                
                Toggle("密文显示", isOn: $isSecureMode)
                    .toggleStyle(.button)
                
                Button("添加") {
                    guard !newKey.isEmpty else { return }
                    globalVars[newKey.replacingOccurrences(of: "global.", with: "")] = newValue
                    saveGlobalVars()
                    newKey = ""
                    newValue = ""
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .onAppear(perform: loadGlobalVars)
    }
    
    // MARK: - [✨防编译器超时] 抽离字典 Binding 的生成
    private func binding(for key: String) -> Binding<String> {
        Binding<String>(
            get: { self.globalVars[key] ?? "" },
            set: { val in
                self.globalVars[key] = val
                self.saveGlobalVars()
            }
        )
    }
    
    private func loadGlobalVars() {
        if let saved = UserDefaults.standard.dictionary(forKey: "RPA_GlobalVariables") as? [String: String] {
            self.globalVars = saved
        }
    }
    
    private func saveGlobalVars() {
        UserDefaults.standard.set(globalVars, forKey: "RPA_GlobalVariables")
    }
    
    private func deleteVar(key: String) {
        globalVars.removeValue(forKey: key)
        saveGlobalVars()
    }
}

// MARK: - 1. 菜单栏管理器 (单例)
@MainActor
class MenuBarManager: NSObject, NSPopoverDelegate {
    static let shared = MenuBarManager()
    
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    var engine: WorkflowEngine?
    
    private var targetAppToRestore: NSRunningApplication?
    private var globalEventMonitor: Any?
    
    private var animatedIconView: NSImageView?
    
    func setup(engine: WorkflowEngine) {
        self.engine = engine
        
        guard statusItem == nil else { return }
        
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "RPA 引擎")
            button.image?.isTemplate = true
            button.action = #selector(togglePopover(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            
            // 🔪 核心修复 1：放弃 frame 强行赋值，改用 AutoLayout，无视状态栏诡异的生命周期
            let iconView = NSImageView()
            iconView.translatesAutoresizingMaskIntoConstraints = false
            iconView.imageScaling = .scaleProportionallyDown
            iconView.isHidden = true
            button.addSubview(iconView)
            
            NSLayoutConstraint.activate([
                iconView.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                iconView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                iconView.widthAnchor.constraint(equalTo: button.widthAnchor),
                iconView.heightAnchor.constraint(equalTo: button.heightAnchor)
            ])
            
            self.animatedIconView = iconView
        }
        
        popover = NSPopover()
        popover?.contentSize = NSSize(width: 320, height: 400)
        popover?.behavior = .applicationDefined
        popover?.animates = true
        popover?.delegate = self
    }
    
    // [✨核心升级] 状态栏图标双层切换与酷炫动画逻辑
    func updateStatus(isRunning: Bool) {
        guard let button = statusItem?.button, let animatedIconView = self.animatedIconView else { return }
        
        if isRunning {
            let currentSize = button.image?.size ?? NSSize(width: 16, height: 16)
            button.image = NSImage(size: currentSize)
            
            // 🔪 酷炫升级：换成多图层的“声波/频率”图标，完美契合 AI 引擎正在“思考”或“输出”的意象
            animatedIconView.image = NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: "运行中")
            
            // 搭配高亮荧光绿
            animatedIconView.symbolConfiguration = NSImage.SymbolConfiguration(paletteColors: [.systemGreen])
            animatedIconView.isHidden = false
            
            if #available(macOS 14.0, *) {
                animatedIconView.removeAllSymbolEffects()
                
                // ==========================================
                // 🌟 酷炫动画库 (按需解除注释体验)
                // ==========================================
                
                // 🚀 方案 A：AI 思考声波（默认推荐）。像均衡器一样从左到右律动，科技感拉满！
                //animatedIconView.addSymbolEffect(.variableColor.iterative.dimInactiveLayers, options: .repeating)
                
                // 🚀 方案 B：心跳暴击。如果你想要“极度显眼”，这个会让整个图标不断向上弹跳，绝对抢眼！
                // animatedIconView.addSymbolEffect(.bounce.up.byLayer, options: .repeating)
                
                // 🚀 方案 C：雷达发射。换用 "dot.radiowaves.left.and.right" 图标配合此动画，像在向外围发射信号
                animatedIconView.image = NSImage(systemSymbolName: "dot.radiowaves.left.and.right", accessibilityDescription: "运行中")
                animatedIconView.addSymbolEffect(.variableColor.cumulative, options: .repeating)
            }
            
            showPopoverWithoutStealingFocus()
            
        } else {
            // 待机状态：恢复为极简闪电
            let image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "待命")
            image?.isTemplate = true
            button.image = image
            
            animatedIconView.isHidden = true
            
            if #available(macOS 14.0, *) {
                animatedIconView.removeAllSymbolEffects()
            }
            
            hidePopover()
        }
    }
    
    // 🔪 安全展开气泡的封装方法
    private func showPopoverWithoutStealingFocus() {
        guard let popover = popover, let button = statusItem?.button, let engine = self.engine else { return }
        
        if !popover.isShown {
            // 1. 抓取目标 App 用于退还焦点
            if let frontApp = NSWorkspace.shared.frontmostApplication,
               frontApp.bundleIdentifier != Bundle.main.bundleIdentifier {
                self.targetAppToRestore = frontApp
            }
            
            // 2. 刷新最新数据
            popover.contentViewController = NSHostingController(rootView: MenuBarPopupView(engine: engine))
            
            // 3. 弹出
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            
            // 4. 立刻退还焦点给底层应用，这样气泡弹出来了，但键盘输入依然在 Safari/微信 里
            restoreFocusOnly()
            
            // 5. 监听点击外部收起
            setupGlobalEventMonitor()
        }
    }
    
    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let popover = popover, let button = statusItem?.button, let engine = self.engine else { return }
        
        if popover.isShown {
            hidePopoverAndRestoreFocus()
        } else {
            if let frontApp = NSWorkspace.shared.frontmostApplication,
               frontApp.bundleIdentifier != Bundle.main.bundleIdentifier {
                self.targetAppToRestore = frontApp
            }
            
            popover.contentViewController = NSHostingController(rootView: MenuBarPopupView(engine: engine))
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            
            setupGlobalEventMonitor()
        }
    }
    
    func hidePopover() {
        if let popover = popover, popover.isShown {
            popover.performClose(nil)
        }
    }
    
    func hidePopoverAndRestoreFocus() {
        if let popover = popover, popover.isShown {
            popover.performClose(nil)
        }
        
        if let targetApp = targetAppToRestore {
            targetApp.activate(options: .activateIgnoringOtherApps)
            self.targetAppToRestore = nil
        } else {
            NSApp.deactivate()
        }
    }
    
    // [✨新增] 仅退还焦点，不收起气泡
    func restoreFocusOnly() {
        if let targetApp = targetAppToRestore {
            targetApp.activate(options: .activateIgnoringOtherApps)
        } else {
            NSApp.deactivate()
        }
    }
    
    // MARK: - 全局监听与清理机制
    private func setupGlobalEventMonitor() {
        guard globalEventMonitor == nil else { return }
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            if self?.engine?.isRunning == true { return }
            self?.hidePopoverAndRestoreFocus()
        }
    }
    
    private func removeGlobalEventMonitor() {
        if let monitor = globalEventMonitor {
            NSEvent.removeMonitor(monitor)
            globalEventMonitor = nil
        }
    }
    
    func popoverDidClose(_ notification: Notification) {
        removeGlobalEventMonitor()
    }
}

// MARK: - 2. 极简菜单栏控制台 UI
struct MenuBarPopupView: View {
    var engine: WorkflowEngine
    @Environment(\.openWindow) private var openWindow
    @State private var hoveredWorkflowId: UUID? = nil
    
    private var groupedWorkflows: [(String, [Workflow])] {
        let grouped = Dictionary(grouping: engine.workflows, by: \.folderName)
        return grouped.sorted { (first, second) in
            if first.key == "默认文件夹" { return true }
            if second.key == "默认文件夹" { return false }
            return first.key < second.key
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // --- 头部 ---
            HStack(spacing: 8) {
                // 左上角图标改为可点击按钮，用于打开主窗体
                Button {
                    // 1. 收起气泡面板
                    MenuBarManager.shared.hidePopover()
                    
                    // 2. 使用 SwiftUI 官方 API 唤醒主窗体
                    // 如果窗体被关了，它会自动新建；如果被最小化了，它会自动恢复。
                    openWindow(id: "main-window")
                    
                    // 3. 稍微延迟一点点，确保系统创建完窗口后，强制将我们的 App 激活到最前台
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        NSApp.activate(ignoringOtherApps: true)
                    }
                } label: {
                    Image(systemName: "cpu")
                        .foregroundColor(.blue)
                        .font(.system(size: 16))
                        .contentShape(Rectangle()) // 扩大点击热区
                }
                .buttonStyle(.plain)
                .help("打开主控制台") // 鼠标悬停提示
                
                // [✨修改 2] 将写死的标题改为显示最后一行日志
                Text(engine.logs.last ?? "LinRPA 助理就绪")
                    .font(.system(size: 12)) // 字体略微调小，更像日志风格
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading) // 让文字靠左对齐并占据中间可用空间
                
                if engine.isRunning {
                    ExecutionBreatheLight(isRunning: true)
                } else {
                    Text("待命中").font(.caption).foregroundColor(.secondary)
                }
            }
            .padding(14)
            .background(Color(NSColor.windowBackgroundColor).opacity(0.5))
            
            Divider()
            
            // --- 内容区 ---
            VStack(alignment: .leading, spacing: 14) {
                if engine.isRunning {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("当前执行节点：")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Text(getCurrentActionName())
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(2)
                            .foregroundColor(.primary)
                    }
                    
                    HStack {
                        Spacer()
                        Button(role: .destructive) {
                            engine.isRunning = false
                        } label: {
                            Label("紧急终止", systemImage: "stop.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(.red)
                    }
                } else {
                    if engine.workflows.isEmpty {
                        Text("暂无可用流程，请先在主界面创建。")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 30)
                    } else {
                        ScrollView(showsIndicators: false) {
                            LazyVStack(alignment: .leading, spacing: 12) {
                                ForEach(groupedWorkflows, id: \.0) { folderName, workflows in
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text(folderName)
                                                .font(.system(size: 11, weight: .bold))
                                                .foregroundColor(.secondary)
                                            Spacer()
                                        }
                                        .padding(.horizontal, 4)
                                        .padding(.top, 4)
                                        
                                        VStack(spacing: 2) {
                                            ForEach(workflows) { workflow in
                                                workflowRow(for: workflow)
                                            }
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                        }
                        .frame(maxHeight: 320)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 320)
    }
    
    // MARK: - 使用原生 Button 替代 onTapGesture，实现一键穿透触发
    @ViewBuilder
    private func workflowRow(for workflow: Workflow) -> some View {
        let isHovered = hoveredWorkflowId == workflow.id
        
        Button {
            // 1. 调用管理器，强行退还/恢复目标应用的焦点
            MenuBarManager.shared.restoreFocusOnly()
            
            // 2. 给予系统 500 毫秒的安全渲染时间后启动引擎
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                Task {
                    await engine.startRootWorkflow(id: workflow.id, skipCountdown: true)
                }
            }
        } label: {
            HStack {
                Image(systemName: "bolt.horizontal.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(isHovered ? .blue : .blue.opacity(0.6))
                
                Text(workflow.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                
                Spacer()
                
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(isHovered ? .blue : .secondary.opacity(0.3))
                    .scaleEffect(isHovered ? 1.1 : 1.0)
                    .animation(.spring(response: 0.2, dampingFraction: 0.6), value: isHovered)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Color.blue.opacity(0.1) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain) // ⚠️ 核心：必须使用 plain 样式才能去除按钮默认背景并穿透事件
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                hoveredWorkflowId = hovering ? workflow.id : nil
            }
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
    
    private func getCurrentActionName() -> String {
        if let id = engine.currentActionId,
           let idx = engine.currentWorkflowIndex,
           let action = engine.workflows[idx].actions.first(where: { $0.id == id }) {
            return action.customName.isEmpty ? action.displayTitle : action.customName
        }
        return "引擎调度中..."
    }
}

struct AISettingsView: View {
    @StateObject private var configManager = AIConfigManager.shared
    @State private var selectedId: UUID?
    
    var body: some View {
        NavigationSplitView {
            List(selection: $selectedId) {
                ForEach(configManager.providers) { provider in
                    HStack {
                        Image(systemName: configManager.activeProviderId == provider.id ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(configManager.activeProviderId == provider.id ? .green : .secondary)
                            .onTapGesture {
                                configManager.activeProviderId = provider.id
                            }
                        
                        Text(provider.name)
                            .font(.system(size: 13))
                        
                        Spacer()
                    }
                    .padding(.vertical, 4)
                    .tag(provider.id)
                }
            }
            .navigationTitle("AI 节点列表")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: addProvider) { Image(systemName: "plus") }
                }
                ToolbarItem(placement: .automatic) {
                    Button(action: removeSelected) { Image(systemName: "minus") }
                        .disabled(selectedId == nil || configManager.providers.count <= 1)
                }
            }
        } detail: {
            if let id = selectedId, let index = configManager.providers.firstIndex(where: { $0.id == id }) {
                Form {
                    Section(header: Text("模型基础配置").font(.headline)) {
                        TextField("节点名称", text: $configManager.providers[index].name)
                        
                        TextField("接口地址 (Host URL)", text: $configManager.providers[index].host)
                            .font(.system(.body, design: .monospaced))
                            .help("例如: http://127.0.0.1:11434/v1/chat/completions")
                        
                        TextField("模型名称 (Model)", text: $configManager.providers[index].modelName)
                            .font(.system(.body, design: .monospaced))
                            .help("例如: qwen3-vl:4b 或 gpt-4o")
                        
                        SecureField("API Key (Bearer Token)", text: $configManager.providers[index].apiKey)
                            .help("本地大模型可随意填写，云端模型请填写真实密钥")
                    }
                    
                    VStack(alignment: .leading, spacing: 10) {
                        Divider().padding(.vertical, 10)
                        Text("💡 提示：").bold()
                        Text("• WebAgent 4.0 强烈建议配置**支持视觉多模态(VLM)**的模型。")
                        Text("• 切换节点后，全局生效，无需重启应用。")
                        
                        Button(action: {
                            configManager.activeProviderId = id
                        }) {
                            Text(configManager.activeProviderId == id ? "当前正在使用该节点" : "激活并使用此节点")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(configManager.activeProviderId == id ? .green : .blue)
                        .padding(.top, 10)
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                .padding()
                .frame(minWidth: 400)
            } else {
                Text("请在左侧选择或添加一个 AI 节点")
                    .foregroundColor(.secondary)
            }
        }
        .frame(minWidth: 650, minHeight: 400)
        .onAppear {
            if selectedId == nil {
                selectedId = configManager.activeProviderId ?? configManager.providers.first?.id
            }
        }
    }
    
    private func addProvider() {
        let newProvider = AIProvider(name: "新建自定义节点", host: "https://api.openai.com/v1/chat/completions", modelName: "gpt-4o", apiKey: "")
        configManager.providers.append(newProvider)
        selectedId = newProvider.id
    }
    
    private func removeSelected() {
        if let id = selectedId {
            configManager.providers.removeAll { $0.id == id }
            if configManager.activeProviderId == id {
                configManager.activeProviderId = configManager.providers.first?.id
            }
            selectedId = configManager.providers.first?.id
        }
    }
}
