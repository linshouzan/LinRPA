//////////////////////////////////////////////////////////////////
// 文件名：ContentView.swift
// 文件说明：这是适用于 macos 14+ 的RPA视图管理 (重构瘦身版)
// 功能说明：加入了左侧边栏的拖拽排序；负责画板拖拽、吸附和连线逻辑；剥离了配置表单。
// 代码要求：没有要求修改不用输出代码，请保证代码的逻辑和完整性，保留代码中的所有注释内容
//////////////////////////////////////////////////////////////////

import SwiftUI
import AppKit
import UniformTypeIdentifiers

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.openWindow) private var openWindow
    
    @State private var engine = WorkflowEngine()
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var isRecordingUI = false
    
    @State private var draggingStartNodeID: UUID? = nil
    @State private var draggingStartPort: PortPosition? = nil
    @State private var dragCurrentPosition: CGPoint? = nil
    @State private var modifyingConnectionID: UUID? = nil
    
    @State private var canvasOffset: CGSize = .zero
    @State private var canvasPan: CGSize = .zero
    var totalOffset: CGSize { CGSize(width: canvasOffset.width + canvasPan.width, height: canvasOffset.height + canvasPan.height) }
    
    @State private var snapLineX: CGFloat? = nil
    @State private var snapLineY: CGFloat? = nil
    @State private var hoveredWorkflowId: UUID? = nil
    
    @State private var showNewFolderAlert = false
    @State private var showRenameFolderAlert = false
    @State private var tempFolderName = ""
    @State private var targetFolderToRename = ""
    
    @StateObject private var appSettings = AppSettings.shared
    @State private var showGlobalSettings = false
    @State private var showSystemTriggers = false
    
    // [✨新增] 控制两个高级配置面板显示的 State 变量
    @State private var showWorkflowProperties = false
    @State private var showGlobalVariables = false
    
    let nodeWidth: CGFloat = 145
    let nodeHeight: CGFloat = 55
    let snapDistance: CGFloat = 40.0
    
    // MARK: - 主体结构 (极致精简)
    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarView
        } content: {
            mainCanvasView
        } detail: {
            componentLibraryView
        }
        .frame(minWidth: 1200, idealWidth: 1400, minHeight: 700, idealHeight: 800)
        .onAppear { engine.checkPermissions(); SystemTriggerManager.shared.setup(engine: engine) }
        .toolbar { topToolbarView }
        // [✨新增] 将引擎挂载到菜单栏管理器
        .onAppear {
            MenuBarManager.shared.setup(engine: engine)
            // 确保初始化时图标状态正确
            MenuBarManager.shared.updateStatus(isRunning: engine.isRunning)
        }
        // [✨新增] 监听引擎运行状态，实时同步给菜单栏的图标指示器
        .onChange(of: engine.isRunning) { _, isRunning in
            MenuBarManager.shared.updateStatus(isRunning: isRunning)
        }
    }
}

// MARK: - UI 拆解: 侧边栏 (Sidebar)
extension ContentView {
    @ViewBuilder
    private var sidebarView: some View {
        VStack(spacing: 0) {
            HStack {
                Text("RPA 流程库").font(.headline)
                Spacer()
                Menu {
                    Button("新建工作流", action: { engine.createNewWorkflow() })
                    Button("新建文件夹", action: { tempFolderName = ""; showNewFolderAlert = true })
                } label: {
                    Image(systemName: "plus.circle.fill").imageScale(.large).foregroundColor(.blue)
                }.menuStyle(.borderlessButton)
            }
            .padding()
            
            Divider()
            
            List(selection: $engine.selectedWorkflowId) {
                ForEach(engine.folders, id: \.self) { folderName in
                    Section {
                        let folderWorkflows = engine.workflows.filter { $0.folderName == folderName }
                        
                        ForEach(folderWorkflows) { workflow in
                            NavigationLink(value: workflow.id) {
                                HStack {
                                    Image(systemName: "bolt.square.fill").foregroundColor(.yellow)
                                    TextField("流程名称", text: workflowNameBinding(for: workflow.id))
                                        .textFieldStyle(.plain)
                                    Spacer()
                                }
                                .padding(.vertical, 4)
                                .contextMenu {
                                    Menu("移动到文件夹...") {
                                        ForEach(engine.folders.filter { $0 != folderName }, id: \.self) { targetFolder in
                                            Button(targetFolder) {
                                                withAnimation(.easeInOut(duration: 0.2)) {
                                                    engine.moveWorkflow(id: workflow.id, toFolder: targetFolder)
                                                }
                                            }
                                        }
                                    }
                                    Button("删除此流程", role: .destructive) { engine.deleteWorkflow(id: workflow.id) }
                                }
                            }
                            .itemProvider { NSItemProvider(object: workflow.id.uuidString as NSString) }
                        }
                        .onMove { source, destination in
                            engine.moveWorkflowWithinFolder(folder: folderName, source: source, destination: destination)
                        }
                        .onInsert(of: [UTType.plainText]) { index, providers in
                            guard let provider = providers.first else { return }
                            _ = provider.loadObject(ofClass: String.self) { idString, _ in
                                if let idStr = idString, let id = UUID(uuidString: idStr) {
                                    DispatchQueue.main.async {
                                        engine.insertWorkflow(id: id, into: folderName, at: index)
                                    }
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Text(folderName).font(.subheadline).bold()
                            Spacer()
                            if folderName != "默认文件夹" {
                                Menu {
                                    Button("重命名") {
                                        targetFolderToRename = folderName
                                        tempFolderName = folderName
                                        showRenameFolderAlert = true
                                    }
                                    Button("删除文件夹 (流程将移至默认)", role: .destructive) {
                                        withAnimation { engine.deleteFolder(name: folderName) }
                                    }
                                } label: {
                                    Image(systemName: "ellipsis").foregroundColor(.secondary)
                                }.menuStyle(.borderlessButton).frame(width: 20)
                            }
                        }
                    }
                    .dropDestination(for: String.self) { items, location in
                        guard let firstItem = items.first, let id = UUID(uuidString: firstItem) else { return false }
                        if let wf = engine.workflows.first(where: { $0.id == id }), wf.folderName != folderName {
                            engine.moveWorkflow(id: id, toFolder: folderName)
                            return true
                        }
                        return false
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .alert("新建文件夹", isPresented: $showNewFolderAlert) {
            TextField("文件夹名称", text: $tempFolderName)
            Button("取消", role: .cancel) { }
            Button("确定") { engine.addFolder(name: tempFolderName) }
        }
        .alert("重命名文件夹", isPresented: $showRenameFolderAlert) {
            TextField("新文件夹名称", text: $tempFolderName)
            Button("取消", role: .cancel) { }
            Button("确定") { engine.renameFolder(oldName: targetFolderToRename, newName: tempFolderName) }
        }
        .navigationTitle("我的流程").navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 300)
    }
}

// MARK: - UI 拆解: 主画板区 (Canvas)
extension ContentView {
    @ViewBuilder
    private var mainCanvasView: some View {
        VStack(spacing: 0) {
            permissionWarningView
            canvasToolbarView
            
            if let idx = engine.currentWorkflowIndex {
                canvasArea(for: idx)
            } else {
                ContentUnavailableView("未选择流程", systemImage: "mouse")
            }
            
            Divider()
            LogConsoleView(logs: engine.logs)
        }
        .navigationTitle("流程编排")
        .navigationSplitViewColumnWidth(min: 500, ideal: 800)
        .sheet(isPresented: $showWorkflowProperties) {
            if let idx = engine.currentWorkflowIndex {
                WorkflowPropertiesView(
                    workflow: $engine.workflows[idx],
                    allWorkflows: engine.workflows
                )
            }
        }
    }
    
    @ViewBuilder
    private var permissionWarningView: some View {
        if !engine.hasAccessibilityPermission || !engine.hasScreenRecordingPermission {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.yellow)
                Text(engine.hasAccessibilityPermission ? "⚠️ 缺少屏幕录制权限：Agent 视觉与截图将失效！" : "⚠️ 缺少辅助功能权限：录制和点击事件将被拦截！").font(.subheadline)
                Spacer()
                Button("去授权并刷新") {
                    engine.checkPermissions(isUserInitiated: true)
                }.buttonStyle(.borderedProminent).tint(.orange)
            }.padding(8).background(Color.red.opacity(0.1))
        }
    }
    
    @ViewBuilder
    private var canvasToolbarView: some View {
        HStack {
            Text("画布视图").font(.headline)
            Spacer()
            
            Button(action: { DispatchQueue.main.async { BrowserWindowController.showSharedWindow() } }) {
                Label("内置浏览器", systemImage: "safari.fill").foregroundColor(.blue)
            }.buttonStyle(.plain).padding(.horizontal, 6).help("手动打开或唤起内置开发者浏览器")
            
            Divider().frame(height: 16).padding(.horizontal, 4)
            
            Button(action: { showWorkflowProperties = true }) {
                Label("流程变量与设置", systemImage: "slider.horizontal.3")
                    .foregroundColor(.purple)
            }
            .buttonStyle(.bordered)
            .disabled(engine.selectedWorkflowId == nil)
            .help("配置当前流程的入参、出参、定时调度与容错兜底")
            
            Divider().frame(height: 16).padding(.horizontal, 4)
            
            if engine.hasUnsavedChanges {
                Button(action: { engine.saveChanges() }) { Label("保存", systemImage: "checkmark.circle.fill") }.buttonStyle(.borderedProminent).tint(.green)
                Divider().frame(height: 16).padding(.horizontal, 4)
            }
            
            Button(action: {
                isRecordingUI ? CorpusHUDManager.shared.hideHUD() : { CorpusHUDManager.shared.showHUD(); if let mainWindow = NSApp.windows.first(where: { $0.title == "我的流程" || $0.className.contains("AppKitWindow"); }) { mainWindow.miniaturize(nil) } }()
                isRecordingUI.toggle()
            }) {
                Label(isRecordingUI ? "停止录制" : "动作录制", systemImage: isRecordingUI ? "stop.circle.fill" : "record.circle").foregroundColor(isRecordingUI ? .red : .primary)
            }.buttonStyle(.bordered).symbolEffect(.pulse, isActive: isRecordingUI)
            
            Divider().frame(height: 16).padding(.horizontal, 4)
            
            if engine.isRunning {
                Button(action: { engine.isRunning = false }) { Label("紧急停止", systemImage: "stop.fill") }.buttonStyle(.borderedProminent).tint(.red)
            }
            Button(action: { Task { await engine.runCurrentWorkflow() } }) {
                Label("执行", systemImage: "play.fill")
            }.buttonStyle(.borderedProminent).disabled(engine.isRunning || engine.selectedWorkflowId == nil || isRecordingUI)
        }
        .padding(8).background(Material.bar)
    }
    
    private func canvasArea(for idx: Int) -> some View {
        GeometryReader { geo in
            ZStack {
                GridBackgroundView(offset: totalOffset)
                    .contentShape(Rectangle())
                    .gesture(DragGesture()
                        .onChanged { value in canvasPan = value.translation }
                        .onEnded { value in
                            canvasOffset.width += value.translation.width
                            canvasOffset.height += value.translation.height
                            canvasPan = .zero
                        }
                    )
                
                let currentWorkflow = engine.workflows[idx]
                
                ZStack {
                    renderedConnections(for: currentWorkflow, index: idx)
                    draggingConnectionLine(for: currentWorkflow)
                    renderedNodes(for: idx, geoSize: geo.size)
                    renderedConnectionTargets(for: currentWorkflow, index: idx)
                    snapLinesView
                }
                .offset(totalOffset)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
    }
}

// MARK: - UI 拆解: 画板内部层级提取
extension ContentView {
    @ViewBuilder
    private func renderedConnections(for workflow: Workflow, index: Int) -> some View {
        ForEach(workflow.connections) { conn in
            if conn.id != modifyingConnectionID {
                let startPos = getPortAbsolutePosition(nodeID: conn.startNodeID, port: conn.startPort, in: workflow)
                let endPos = getPortAbsolutePosition(nodeID: conn.endNodeID, port: conn.endPort, in: workflow)
                
                ZStack {
                    ConnectionLine(start: startPos, end: endPos, startPort: conn.startPort, endPort: conn.endPort)
                        .stroke(Color.white.opacity(0.001), lineWidth: 30)
                        .contextMenu {
                            Button(role: .destructive) { engine.workflows[index].connections.removeAll { $0.id == conn.id } } label: { Label("删除", systemImage: "trash") }
                        }
                    ConnectionArrowLine(start: startPos, end: endPos, startPort: conn.startPort, endPort: conn.endPort, condition: conn.condition)
                        .allowsHitTesting(false)
                }
            }
        }
    }
    
    @ViewBuilder
    private func draggingConnectionLine(for workflow: Workflow) -> some View {
        if let startID = draggingStartNodeID, let startPort = draggingStartPort, let currentPos = dragCurrentPosition {
            let startPos = getPortAbsolutePosition(nodeID: startID, port: startPort, in: workflow)
            let guessEndPort = guessEndPortDirection(start: startPos, current: currentPos)
            let condition = guessConditionForNewConnection(startID: startID, startPort: startPort, in: workflow)
            ConnectionArrowLine(start: startPos, end: currentPos, startPort: startPort, endPort: guessEndPort, condition: condition)
        }
    }
    
    @ViewBuilder
    private func renderedNodes(for index: Int, geoSize: CGSize) -> some View {
        let currentWorkflow = engine.workflows[index]
        ForEach($engine.workflows[index].actions) { $action in
            let position = getPosition(for: action.id, in: currentWorkflow)
            let isStart = !currentWorkflow.connections.contains(where: { $0.endNodeID == action.id })
            let isEnd = !currentWorkflow.connections.contains(where: { $0.startNodeID == action.id })
            
            CanvasNodeCardView(
                action: $action,
                engine: engine,
                isCurrent: engine.currentActionId == action.id,
                isStart: isStart,
                isEnd: isEnd,
                isConnecting: draggingStartNodeID != nil,
                cardWidth: nodeWidth,
                cardHeight: nodeHeight,
                onStartConnection: { port in draggingStartNodeID = action.id; draggingStartPort = port },
                onDragConnection: { port, translation in handleDragConnection(actionID: action.id, port: port, translation: translation, workflow: currentWorkflow) },
                onEndConnection: { port, dropTranslation in handleEndConnection(actionID: action.id, port: port, translation: dropTranslation, workflow: currentWorkflow) },
                onDelete: { engine.removeAction(id: action.id) }
            )
            .position(position)
            .gesture(
                DragGesture()
                    .onChanged { value in handleNodeDragChange(actionID: action.id, location: value.location, workflow: currentWorkflow) }
                    .onEnded { value in handleNodeDragEnd(actionID: action.id, location: value.location) }
            )
            .onAppear {
                if action.positionX == 0 && action.positionY == 0 {
                    let defPos = defaultPosition(in: geoSize, offset: totalOffset)
                    engine.updateActionPosition(id: action.id, position: defPos)
                    engine.nodePositions[action.id] = defPos
                }
            }
        }
    }
    
    @ViewBuilder
    private func renderedConnectionTargets(for workflow: Workflow, index: Int) -> some View {
        ForEach(workflow.connections) { conn in
            let endPos = getPortAbsolutePosition(nodeID: conn.endNodeID, port: conn.endPort, in: workflow)
            
            Circle().fill(Color.white).frame(width: 14, height: 14)
                .overlay(Circle().stroke(Color.blue, lineWidth: 2))
                .background(Color.white.opacity(0.001).frame(width: 30, height: 30))
                .position(endPos)
                .opacity(modifyingConnectionID == conn.id ? 0 : 1)
                .gesture(DragGesture()
                    .onChanged { value in
                        if modifyingConnectionID != conn.id {
                            modifyingConnectionID = conn.id
                            draggingStartNodeID = conn.startNodeID
                            draggingStartPort = conn.startPort
                        }
                        dragCurrentPosition = CGPoint(x: endPos.x + value.translation.width, y: endPos.y + value.translation.height)
                    }
                    .onEnded { value in
                        let globalDropPoint = CGPoint(x: endPos.x + value.translation.width, y: endPos.y + value.translation.height)
                        let sourceID = conn.startNodeID
                        let sourcePort = conn.startPort
                        engine.workflows[index].connections.removeAll { $0.id == conn.id }
                        handleConnectionDrop(dropLocation: globalDropPoint, startID: sourceID, startPort: sourcePort, workflow: engine.workflows[index])
                        modifyingConnectionID = nil
                        draggingStartNodeID = nil
                        draggingStartPort = nil
                        dragCurrentPosition = nil
                    }
                )
        }
    }
    
    @ViewBuilder
    private var snapLinesView: some View {
        if let snapX = snapLineX {
            Path { p in p.move(to: CGPoint(x: snapX, y: -5000)); p.addLine(to: CGPoint(x: snapX, y: 5000)) }
            .stroke(Color.orange.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
        }
        if let snapY = snapLineY {
            Path { p in p.move(to: CGPoint(x: -5000, y: snapY)); p.addLine(to: CGPoint(x: 5000, y: snapY)) }
            .stroke(Color.orange.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
        }
    }
}

// MARK: - UI 拆解: 组件库与顶部工具栏
extension ContentView {
    @ViewBuilder
    private var componentLibraryView: some View {
        List {
            ForEach(ActionCategory.allCases, id: \.self) { category in
                Section(header: Text(category.rawValue).font(.subheadline).bold()) {
                    let filteredActions = ActionType.allCases.filter { $0.category == category }
                    ForEach(filteredActions, id: \.self) { type in
                        Button(action: { withAnimation { engine.addAction(type) } }) {
                            HStack {
                                Image(systemName: type.icon).foregroundColor(category == .aiVision ? .purple : (category == .logicData ? .orange : .blue)).frame(width: 20)
                                Text(type.rawValue).font(.system(size: 12))
                                Spacer()
                            }
                            .padding(8).background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.controlBackgroundColor)))
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
        .navigationTitle("组件库")
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 300)
    }
    
    @ViewBuilder
    private var topToolbarView: some View {
        HStack(spacing: 12) {
            // [✨新增] 自动化触发器配置入口
            Button(action: { showSystemTriggers = true }) {
                Label("触发器", systemImage: "bolt.badge.clock.fill")
                    .foregroundColor(.yellow)
            }
            .help("配置监听 macOS 系统事件自动触发工作流")
            .sheet(isPresented: $showSystemTriggers) {
                SystemTriggersView(engine: engine)
            }

            Button(action: { showGlobalVariables = true }) {
                Label("环境变量", systemImage: "lock.rectangle.on.rectangle")
                    .foregroundColor(.orange)
            }
            .help("管理全局 API Key 与共享的系统加密变量")
            .sheet(isPresented: $showGlobalVariables) {
                VStack(spacing: 0) {
                    HStack {
                        Spacer()
                        Button("关闭") { showGlobalVariables = false }
                    }
                    .padding()
                    GlobalVariablesSettingsView()
                }
                .frame(width: 550, height: 450)
            }
            
            Button(action: { showGlobalSettings.toggle() }) {
                Label("全局设置", systemImage: "gearshape.fill").foregroundColor(.secondary)
            }
            .help("打开系统全局设置与 AI Prompt 调优")
            .popover(isPresented: $showGlobalSettings, arrowEdge: .bottom) {
                GlobalSettingsPopoverView()
            }
            
            Button(action: { openWindow(id: "corpus-manager") }) {
                Label("知识库", systemImage: "book.fill")
            }.help("打开AI语料管理库")
            
            Button(action: { openWindow(id: "agentMonitor") }) {
                Label("AI 监控", systemImage: "eye.square").foregroundColor(.cyan)
            }.help("打开 WebAgent 运行时感知与思考监控面板")
        }
    }
}

// MARK: - 逻辑与计算助手 (剥离出 ViewBuilder 避免超时)
extension ContentView {
    
    private func workflowNameBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: { engine.workflows.first(where: { $0.id == id })?.name ?? "" },
            set: { newVal in
                if let idx = engine.workflows.firstIndex(where: { $0.id == id }) {
                    engine.workflows[idx].name = newVal
                }
            }
        )
    }

    private func handleDragConnection(actionID: UUID, port: PortPosition, translation: CGSize, workflow: Workflow) {
        let portPos = getPortAbsolutePosition(nodeID: actionID, port: port, in: workflow)
        dragCurrentPosition = CGPoint(x: portPos.x + translation.width, y: portPos.y + translation.height)
    }
    
    private func handleEndConnection(actionID: UUID, port: PortPosition, translation: CGSize, workflow: Workflow) {
        let portPos = getPortAbsolutePosition(nodeID: actionID, port: port, in: workflow)
        let globalDropPoint = CGPoint(x: portPos.x + translation.width, y: portPos.y + translation.height)
        handleConnectionDrop(dropLocation: globalDropPoint, startID: draggingStartNodeID, startPort: draggingStartPort, workflow: workflow)
        draggingStartNodeID = nil; draggingStartPort = nil; dragCurrentPosition = nil
    }
    
    private func handleNodeDragChange(actionID: UUID, location: CGPoint, workflow: Workflow) {
        var newX = location.x; var newY = location.y
        var foundSnapX: CGFloat? = nil; var foundSnapY: CGFloat? = nil
        
        for other in workflow.actions where other.id != actionID {
            let otherPos = getPosition(for: other.id, in: workflow)
            if abs(newX - otherPos.x) < 15 { newX = otherPos.x; foundSnapX = otherPos.x }
            if abs(newY - otherPos.y) < 15 { newY = otherPos.y; foundSnapY = otherPos.y }
        }
        
        snapLineX = foundSnapX; snapLineY = foundSnapY
        engine.nodePositions[actionID] = CGPoint(x: newX, y: newY)
    }
    
    private func handleNodeDragEnd(actionID: UUID, location: CGPoint) {
        snapLineX = nil; snapLineY = nil
        if let pos = engine.nodePositions[actionID] {
            engine.updateActionPosition(id: actionID, position: pos)
        } else {
            engine.updateActionPosition(id: actionID, position: location)
        }
    }
    
    private func getPosition(for id: UUID, in workflow: Workflow) -> CGPoint { if let pos = engine.nodePositions[id] { return pos }; if let action = workflow.actions.first(where: { $0.id == id }) { return CGPoint(x: action.positionX, y: action.positionY) }; return .zero }
    private func defaultPosition(in size: CGSize, offset: CGSize) -> CGPoint { return CGPoint(x: size.width / 2 - offset.width + CGFloat.random(in: -30...30), y: size.height / 3 - offset.height + CGFloat.random(in: -30...30)) }
    private func getPortAbsolutePosition(nodeID: UUID, port: PortPosition, in workflow: Workflow) -> CGPoint { let center = getPosition(for: nodeID, in: workflow); switch port { case .top: return CGPoint(x: center.x, y: center.y - nodeHeight / 2); case .bottom: return CGPoint(x: center.x, y: center.y + nodeHeight / 2); case .left: return CGPoint(x: center.x - nodeWidth / 2, y: center.y); case .right: return CGPoint(x: center.x + nodeWidth / 2, y: center.y) } }
    private func guessEndPortDirection(start: CGPoint, current: CGPoint) -> PortPosition { let dx = current.x - start.x; let dy = current.y - start.y; if abs(dx) > abs(dy) { return dx > 0 ? .left : .right } else { return dy > 0 ? .top : .bottom } }
    private func guessConditionForNewConnection(startID: UUID, startPort: PortPosition, in workflow: Workflow) -> ConnectionCondition {
        guard let sourceAction = workflow.actions.first(where: { $0.id == startID }) else { return .always }
        if sourceAction.type == .ocrText || sourceAction.type == .condition || sourceAction.type == .webAgent {
            if startPort == .right { return .success }
            if startPort == .bottom { return .failure }
        }
        return .always
    }
    
    private func handleConnectionDrop(dropLocation: CGPoint?, startID: UUID?, startPort: PortPosition?, workflow: Workflow) {
        guard let dropPoint = dropLocation, let sourceID = startID, let sPort = startPort else { return }
        var closest: (nodeID: UUID, port: PortPosition, distance: CGFloat)? = nil
        
        for targetNode in workflow.actions {
            if targetNode.id == sourceID { continue }
            for port in PortPosition.allCases {
                let targetPortPos = getPortAbsolutePosition(nodeID: targetNode.id, port: port, in: workflow)
                let distance = hypot(targetPortPos.x - dropPoint.x, targetPortPos.y - dropPoint.y)
                if distance <= snapDistance {
                    if closest == nil || distance < closest!.distance { closest = (targetNode.id, port, distance) }
                }
            }
        }
        
        if let bestMatch = closest {
            let condition = guessConditionForNewConnection(startID: sourceID, startPort: sPort, in: workflow)
            engine.addConnection(source: sourceID, sourcePort: sPort, target: bestMatch.nodeID, targetPort: bestMatch.port, condition: condition)
        }
    }
}

struct CanvasNodeCardView: View {
    @Binding var action: RPAAction
    var engine: WorkflowEngine
    var isCurrent: Bool; var isStart: Bool; var isEnd: Bool; var isConnecting: Bool
    let cardWidth: CGFloat; let cardHeight: CGFloat
    var onStartConnection: (PortPosition) -> Void; var onDragConnection: (PortPosition, CGSize) -> Void; var onEndConnection: (PortPosition, CGSize) -> Void; var onDelete: () -> Void
    @State private var showSettings = false
    @State private var breathePhase: CGFloat = 0

    var themeColor: Color {
        if action.isDisabled { return .gray }
        switch action.type {
        case .aiVision, .ocrText: return .purple
        case .webAgent: return .indigo
        case .condition: return .orange
        case .uiInteraction: return .cyan
        case .runShell, .runAppleScript: return .green
        default: return .blue
        }
    }

    var body: some View {
        ZStack {
            // --- 1. 背景视觉层（承担所有呼吸动画、阴影、缩放，与内容物理隔离） ---
            RoundedRectangle(cornerRadius: 8)
                .fill(isCurrent ? themeColor.opacity(0.9) : Color(NSColor.controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isCurrent ? themeColor.opacity(0.6 + breathePhase * 0.4) : (isStart ? Color.green.opacity(0.8) : (isEnd ? Color.orange.opacity(0.8) : Color.gray.opacity(0.3))), lineWidth: isCurrent ? (2 + breathePhase * 1.5) : 1)
                )
                .shadow(color: isCurrent ? themeColor.opacity(0.5 - breathePhase * 0.2) : .black.opacity(0.05), radius: isCurrent ? (6 + breathePhase * 8) : 2, y: 2)
                // ⚠️ 动画只作用于背景形状，绝不波及上层的 TextField
                .scaleEffect(isCurrent ? (1.02 + breathePhase * 0.02) : 1.0)
                .animation(.easeOut(duration: 0.2), value: isCurrent)

            // --- 2. 交互内容层（绝对静止，杜绝 AppKit 布局死锁） ---
            HStack(spacing: 8) {
                Image(systemName: action.type.icon)
                    .font(.system(size: 16))
                    .foregroundColor(isCurrent ? .white : themeColor)
                
                // 使用 ZStack + Opacity，避免 TextField 被频繁销毁和重建
                ZStack(alignment: .leading) {
                    Text(action.customName.isEmpty ? action.displayTitle : action.customName)
                        .font(.system(size: 12, weight: .bold))
                        .strikethrough(action.isDisabled, color: .gray)
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .opacity(isCurrent ? 1.0 : 0.0)
                    
                    TextField(action.displayTitle, text: $action.customName)
                        .font(.system(size: 12, weight: .bold))
                        .strikethrough(action.isDisabled, color: .gray)
                        .foregroundColor(action.isDisabled ? .gray : .primary)
                        .textFieldStyle(.plain)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .opacity(isCurrent ? 0.0 : 1.0)
                        .allowsHitTesting(!isCurrent)
                }
                .transaction { transaction in
                    transaction.animation = nil // 阻断内部任何隐式动画
                }
                
                Button(action: { showSettings.toggle() }) {
                    Image(systemName: "gearshape.fill")
                        .foregroundColor(isCurrent ? .white.opacity(0.8) : .gray)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            // 🚨 绝对不要在这里加 .scaleEffect 或 .animation
            
            // --- 3. 端口连线点与状态标记层 ---
            if isStart || isEnd {
                Text(isStart ? "▶ 起点" : "🏁 终点")
                    .font(.system(size: 8, weight: .bold)).foregroundColor(.white)
                    .padding(.horizontal, 4).padding(.vertical, 2)
                    .background(isStart ? Color.green : Color.orange)
                    .clipShape(Capsule())
                    .offset(x: cardWidth / 2 - 10, y: -cardHeight / 2 - 6)
            }
            
            ForEach(PortPosition.allCases, id: \.self) { port in
                let portOffset = getPortLocalOffset(port: port)
                Circle()
                    .fill(Color(NSColor.controlBackgroundColor))
                    .frame(width: 10, height: 10)
                    .overlay(Circle().stroke(themeColor.opacity(0.6), lineWidth: 2))
                    .scaleEffect(isConnecting ? 1.3 : 1.0)
                    .animation(.spring(), value: isConnecting)
                    .offset(x: portOffset.width, y: portOffset.height)
                    .overlay(
                        Color.white.opacity(0.001)
                            .frame(width: 25, height: 25)
                            .offset(x: portOffset.width, y: portOffset.height)
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { value in
                                        if value.translation.width == 0 && value.translation.height == 0 { onStartConnection(port) }
                                        else { onDragConnection(port, value.translation) }
                                    }
                                    .onEnded { value in onEndConnection(port, value.translation) }
                            )
                    )
                
                if action.type == .ocrText || action.type == .condition || action.type == .webAgent {
                    if port == .right { Text("✅").font(.system(size: 8)).foregroundColor(.green).offset(x: portOffset.width + 12, y: portOffset.height) }
                    else if port == .bottom { Text("❌").font(.system(size: 8)).foregroundColor(.red).offset(x: portOffset.width, y: portOffset.height + 12) }
                }
            }
        }
        // 将原先挂载在 HStack 上的整体控制移动到 ZStack
        .frame(width: cardWidth, height: cardHeight)
        .opacity(action.isDisabled ? 0.6 : 1.0)
        .contextMenu {
            Button(action: { action.isDisabled.toggle() }) {
                Label(action.isDisabled ? "启用此节点" : "禁用此节点 (运行时跳过)", systemImage: action.isDisabled ? "play.circle" : "pause.circle")
            }
            Divider()
            Button(role: .destructive, action: onDelete) { Label("删除节点", systemImage: "trash") }
        }
        .onChange(of: isCurrent) { _, current in
            if current { breathePhase = 0; withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { breathePhase = 1 } }
            else { withAnimation(.easeOut(duration: 0.2)) { breathePhase = 0 } }
        }
        .onAppear { if isCurrent { withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { breathePhase = 1 } } }
        .popover(isPresented: $showSettings, arrowEdge: .trailing) { ActionSettingsPopoverView(action: $action, showSettings: $showSettings, engine: engine) }
    }
    
    private func getPortLocalOffset(port: PortPosition) -> CGSize { switch port { case .top: return CGSize(width: 0, height: -cardHeight / 2); case .bottom: return CGSize(width: 0, height: cardHeight / 2); case .left: return CGSize(width: -cardWidth / 2, height: 0); case .right: return CGSize(width: cardWidth / 2, height: 0) } }
}

struct ParsedLogNode: Identifiable {
    let id = UUID()
    var isThink: Bool
    var text: String
}

struct LogRowView: View {
    let text: String
    @State private var isThinkExpanded = false
    
    var body: some View {
        let nodes = parseLog(text)
        VStack(alignment: .leading, spacing: 2) {
            ForEach(nodes) { node in
                if node.isThink {
                    DisclosureGroup(isExpanded: $isThinkExpanded) {
                        Text(node.text)
                            .foregroundColor(.purple.opacity(0.8))
                            .font(.system(size: 11, design: .monospaced))
                            .padding(.leading, 4)
                            .padding(.vertical, 2)
                    } label: {
                        Text("🧠 [AI 深度思考过程]").foregroundColor(.purple).font(.system(size: 11, weight: .bold))
                    }
                } else {
                    if !node.text.isEmpty {
                        Text(node.text)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(node.text.contains("❌") ? .red : (node.text.contains("🎯") ? .green : (node.text.contains("🧠") ? .purple : .primary)))
                    }
                }
            }
        }
    }
    
    private func parseLog(_ text: String) -> [ParsedLogNode] {
        var result: [ParsedLogNode] = []
        var currentText = text
        while let startRange = currentText.range(of: "<think>") {
            let before = String(currentText[..<startRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !before.isEmpty { result.append(ParsedLogNode(isThink: false, text: before)) }
            
            let remaining = String(currentText[startRange.upperBound...])
            if let endRange = remaining.range(of: "</think>") {
                let thinkText = String(remaining[..<endRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                result.append(ParsedLogNode(isThink: true, text: thinkText))
                currentText = String(remaining[endRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                let streamingThink = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
                result.append(ParsedLogNode(isThink: true, text: streamingThink + " ..."))
                currentText = ""
                break
            }
        }
        if !currentText.isEmpty {
            result.append(ParsedLogNode(isThink: false, text: currentText))
        }
        return result
    }
}

struct LogConsoleView: View {
    var logs: [String]
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(logs.indices, id: \.self) { index in
                        LogRowView(text: logs[index])
                            .id(index)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding()
            }
            .frame(height: 120).background(Color(NSColor.windowBackgroundColor))
            .textSelection(.enabled)
            .onChange(of: logs.count) { _, _ in
                if !logs.isEmpty { withAnimation { proxy.scrollTo(logs.count - 1, anchor: .bottom) } }
            }
            .onChange(of: logs.last) { _, _ in
                if !logs.isEmpty { proxy.scrollTo(logs.count - 1, anchor: .bottom) }
            }
        }
    }
}

struct ConnectionLine: Shape { var start: CGPoint; var end: CGPoint; var startPort: PortPosition; var endPort: PortPosition; func path(in rect: CGRect) -> Path { var path = Path(); path.move(to: start); path.addCurve(to: end, control1: CGPoint(x: start.x + startPort.controlOffset.width, y: start.y + startPort.controlOffset.height), control2: CGPoint(x: end.x + endPort.controlOffset.width, y: end.y + endPort.controlOffset.height)); return path } }
struct ConnectionArrowLine: View { var start: CGPoint; var end: CGPoint; var startPort: PortPosition; var endPort: PortPosition; var condition: ConnectionCondition; var body: some View { let c1 = CGPoint(x: start.x + startPort.controlOffset.width, y: start.y + startPort.controlOffset.height); let c2 = CGPoint(x: end.x + endPort.controlOffset.width, y: end.y + endPort.controlOffset.height); let t: CGFloat = 0.9; let mt: CGFloat = 1.0 - t; let arrowX = mt*mt*mt*start.x + 3.0*mt*mt*t*c1.x + 3.0*mt*t*t*c2.x + t*t*t*end.x; let arrowY = mt*mt*mt*start.y + 3.0*mt*mt*t*c1.y + 3.0*mt*t*t*c2.y + t*t*t*end.y; let dX = 3.0*mt*mt*(c1.x - start.x) + 6.0*mt*t*(c2.x - c1.x) + 3.0*t*t*(end.x - c2.x); let dY = 3.0*mt*mt*(c1.y - start.y) + 6.0*mt*t*(c2.y - c1.y) + 3.0*t*t*(end.y - c2.y); let angle = atan2(dY, dX); let strokeColor = condition == .success ? Color.green : (condition == .failure ? Color.red : Color.blue); ZStack { ConnectionLine(start: start, end: end, startPort: startPort, endPort: endPort).stroke(strokeColor.opacity(0.8), style: StrokeStyle(lineWidth: 2, dash: condition == .failure ? [4, 4] : [])); Image(systemName: "play.fill").font(.system(size: 12)).foregroundColor(strokeColor).rotationEffect(.radians(Double(angle))).position(x: arrowX, y: arrowY) } } }
struct GridBackgroundView: View { let gridSize: CGFloat = 20; var offset: CGSize; var body: some View { GeometryReader { geometry in Path { path in let w = geometry.size.width; let h = geometry.size.height; let startX = offset.width.truncatingRemainder(dividingBy: gridSize); let startY = offset.height.truncatingRemainder(dividingBy: gridSize); for x in stride(from: startX - gridSize, through: w + gridSize, by: gridSize) { path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: h)) }; for y in stride(from: startY - gridSize, through: h + gridSize, by: gridSize) { path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: w, y: y)) } }.stroke(Color.gray.opacity(0.04), lineWidth: 1) }.background(Color(NSColor.textBackgroundColor)) } }

struct GlobalSettingsPopoverView: View {
    @ObservedObject var settings = AppSettings.shared
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "gearshape.fill").foregroundColor(.blue)
                Text("系统全局设置").font(.headline)
            }
            Divider()
            
            VStack(alignment: .leading, spacing: 12) {
                Label("界面交互偏好", systemImage: "macwindow").font(.subheadline).bold()
                
                HStack {
                    Text("监控面板样式:")
                    Picker("", selection: $settings.hudStyle) {
                        ForEach(HUDStyle.allCases, id: \.self) { style in
                            Text(style.rawValue).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                
                Text(settings.hudStyle == .classic ? "提供完整的节点进度与运行日志查看面板。" : "极致隐蔽的胶囊态设计，日常缩小为右下角/右上角的呼吸圆点，鼠标点击后可展开控制。")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(10)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
            
            VStack(alignment: .leading, spacing: 12) {
                Label("WebAgent 运行控制", systemImage: "globe").font(.subheadline).bold()
                HStack {
                    Text("最大思考与动作轮数:").font(.caption)
                    Stepper(value: $settings.webAgentMaxRounds, in: 1...50) {
                        Text("\(settings.webAgentMaxRounds) 轮")
                    }
                }
                Text("防止 WebAgent 在特殊页面陷入死循环，超过此轮数将强制终止。").font(.caption2).foregroundColor(.secondary)
            }
            .padding(10)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
            
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("🧠 WebAgent 智能体核心 Prompt", systemImage: "brain").font(.subheadline).bold()
                    Spacer()
                    Button("恢复系统默认") {
                        settings.webAgentPrompt = AppSettings.defaultWebAgentPrompt
                    }.font(.caption)
                }
                
                TextEditor(text: Binding(
                    get: { settings.webAgentPrompt.isEmpty ? AppSettings.shared.webAgentPrompt : settings.webAgentPrompt },
                    set: { settings.webAgentPrompt = $0 }
                ))
                .font(.system(size: 11, design: .monospaced))
                .frame(height: 160)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3)))
                
                HStack {
                    Text("全局可用变量:").font(.caption2).foregroundColor(.secondary)
                    Text("{{TaskDesc}} {{SuccessAssertion}} {{Manual}} {{History}} {{DOM}}").font(.caption2).foregroundColor(.blue)
                }
            }
            .padding(10)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
            
            VStack(alignment: .leading, spacing: 12) {
                Label("引擎运行偏好", systemImage: "cpu").font(.subheadline).bold()
                Toggle("执行流程时，自动最小化主窗口 (防止遮挡屏幕视觉)", isOn: $settings.minimizeOnRun)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                
                HStack {
                    Text("执行前倒计时:")
                    Stepper(value: $settings.countdownSeconds, in: 0...10) {
                        Text("\(settings.countdownSeconds) 秒")
                            .foregroundColor(settings.countdownSeconds == 0 ? .red : .primary)
                    }
                }
                .font(.system(size: 13))
                .help("设置为 0 秒可跳过倒计时，直接执行。")
            }
            .padding(10)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
        }
        .padding()
        .frame(width: 400)
    }
}

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - 系统级事件触发器统一配置面板
struct SystemTriggersView: View {
    @StateObject private var settings = AppSettings.shared
    var engine: WorkflowEngine
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("自动化事件触发器").font(.headline)
                Spacer()
                Button(action: addTrigger) { Label("新建触发器", systemImage: "plus") }
            }
            .padding()
            
            Divider()
            
            if settings.systemTriggers.isEmpty {
                ContentUnavailableView("暂无触发器", systemImage: "bolt.badge.clock", description: Text("添加触发器，使工作流在特定系统事件发生时自动执行。"))
            } else {
                List {
                    ForEach($settings.systemTriggers) { $trigger in
                        VStack(spacing: 10) {
                            HStack(spacing: 12) {
                                Toggle("", isOn: $trigger.isEnabled).labelsHidden()
                                
                                Picker("", selection: $trigger.eventType) {
                                    ForEach(TriggerEventType.allCases, id: \.self) { type in
                                        Text(type.rawValue).tag(type)
                                    }
                                }
                                .frame(width: 140)
                                
                                // [✨重构] 应用程序选择器：输入框 + 原生选择按钮
                                if trigger.eventType == .appLaunched || trigger.eventType == .appTerminated {
                                    HStack(spacing: 4) {
                                        TextField("包名(如 com.apple.Safari)", text: $trigger.targetAppBundleId)
                                            .textFieldStyle(.roundedBorder)
                                            .frame(width: 150)
                                        
                                        Button(action: {
                                            selectApplication(for: $trigger)
                                        }) {
                                            Image(systemName: "folder.magnifyingglass")
                                                .foregroundColor(.blue)
                                                .frame(width: 24, height: 24)
                                                .background(Color(NSColor.controlBackgroundColor))
                                                .cornerRadius(4)
                                        }
                                        .buttonStyle(.plain)
                                        .help("从系统中选择应用程序")
                                    }
                                }
                                
                                Image(systemName: "arrow.right").foregroundColor(.secondary)
                                
                                Picker("", selection: $trigger.workflowId) {
                                    Text("请选择要触发的工作流...").tag(UUID?.none)
                                    ForEach(engine.workflows) { wf in
                                        Text(wf.name).tag(UUID?.some(wf.id))
                                    }
                                }
                                
                                Spacer()
                                
                                Button(action: { remove(id: trigger.id) }) {
                                    Image(systemName: "trash").foregroundColor(.red)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
            
            Divider()
            
            HStack {
                Spacer()
                Button("完成") {
                    // 手动触发一次赋值，强制触发 AppStorage 的 didSet 保存
                    settings.systemTriggers = settings.systemTriggers
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
            }
            .padding()
        }
        .frame(width: 850, height: 500)
    }
    
    // MARK: - 辅助方法
    private func addTrigger() {
        settings.systemTriggers.append(SystemTrigger())
    }
    
    private func remove(id: UUID) {
        settings.systemTriggers.removeAll { $0.id == id }
    }
    
    // [✨新增] 调用 macOS 原生文件选择器，提取 App Bundle ID
    private func selectApplication(for trigger: Binding<SystemTrigger>) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        // 限制只能选 .app 文件
        panel.allowedContentTypes = [UTType.application]
        // 默认直达 /Applications 目录
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "选择"
        panel.message = "请选择要监控的应用程序"
        
        // 模态弹窗拦截
        if panel.runModal() == .OK, let url = panel.url {
            // 解析出 Bundle ID 并自动填入
            if let bundle = Bundle(url: url), let bundleId = bundle.bundleIdentifier {
                trigger.wrappedValue.targetAppBundleId = bundleId
            } else {
                // 如果是某些非标 App，降级提取它的英文文件名作为标识
                trigger.wrappedValue.targetAppBundleId = url.deletingPathExtension().lastPathComponent
            }
        }
    }
}
