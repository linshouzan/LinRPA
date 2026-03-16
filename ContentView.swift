//////////////////////////////////////////////////////////////////
// 文件名：ContentView.swift
// 文件说明：这是适用于 macos 14+ 的RPA视图管理 (重构瘦身版)
// 功能说明：加入了左侧边栏的拖拽排序；负责画板拖拽、吸附和连线逻辑；剥离了配置表单。
// 代码要求：没有要求修改不用输出代码，请保证代码的逻辑和完整性，保留代码中的所有注释内容
//////////////////////////////////////////////////////////////////

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
    
    let nodeWidth: CGFloat = 145
    let nodeHeight: CGFloat = 55
    let snapDistance: CGFloat = 40.0
    
    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
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
                                        TextField("流程名称", text: Binding(
                                            get: { workflow.name },
                                            set: { newVal in
                                                if let idx = engine.workflows.firstIndex(where: { $0.id == workflow.id }) {
                                                    engine.workflows[idx].name = newVal
                                                }
                                            }
                                        )).textFieldStyle(.plain)
                                        Spacer()
                                    }
                                    .padding(.vertical, 4)
                                    .contextMenu {
                                        Menu("移动到文件夹...") {
                                            ForEach(engine.folders.filter { $0 != folderName }, id: \.self) { targetFolder in
                                                Button(targetFolder) {
                                                    if let idx = engine.workflows.firstIndex(where: { $0.id == workflow.id }) {
                                                        engine.workflows[idx].folderName = targetFolder
                                                        engine.saveChanges()
                                                    }
                                                }
                                            }
                                        }
                                        Button("删除此流程", role: .destructive) { engine.deleteWorkflow(id: workflow.id) }
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
                                            engine.deleteFolder(name: folderName)
                                        }
                                    } label: {
                                        Image(systemName: "ellipsis")
                                            .foregroundColor(.secondary)
                                    }.menuStyle(.borderlessButton).frame(width: 20)
                                }
                            }
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
            // [✨修改] 移除了原有的 .toolbar 添加工作流+号，使其更加干净
            .navigationTitle("我的流程").navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 300)
        } content: {
            VStack(spacing: 0) {
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
                
                HStack {
                    Text("画布视图").font(.headline)
                    Spacer()
                    
                    Button(action: {
                        DispatchQueue.main.async { BrowserWindowController.showSharedWindow() }
                    }) {
                        Label("内置浏览器", systemImage: "safari.fill").foregroundColor(.blue)
                    }
                    .buttonStyle(.plain).padding(.horizontal, 6).help("手动打开或唤起内置开发者浏览器")
                    
                    Divider().frame(height: 16).padding(.horizontal, 4)
                    
                    if engine.hasUnsavedChanges { Button(action: { engine.saveChanges() }) { Label("保存", systemImage: "checkmark.circle.fill") }.buttonStyle(.borderedProminent).tint(.green); Divider().frame(height: 16).padding(.horizontal, 4) }
                    
                    Button(action: toggleRecording) { Label(isRecordingUI ? "停止录制" : "动作录制", systemImage: isRecordingUI ? "stop.circle.fill" : "record.circle").foregroundColor(isRecordingUI ? .red : .primary) }.buttonStyle(.bordered).symbolEffect(.pulse, isActive: isRecordingUI)
                    Divider().frame(height: 16).padding(.horizontal, 4)
                    
                    if engine.isRunning { Button(action: { engine.isRunning = false }) { Label("紧急停止", systemImage: "stop.fill") }.buttonStyle(.borderedProminent).tint(.red) }
                    Button(action: { Task { await engine.runCurrentWorkflow() } }) { Label("执行", systemImage: "play.fill") }.buttonStyle(.borderedProminent).disabled(engine.isRunning || engine.selectedWorkflowId == nil || isRecordingUI)
                }.padding(8).background(Material.bar)
                
                if let idx = engine.currentWorkflowIndex {
                    GeometryReader { geo in
                        ZStack {
                            GridBackgroundView(offset: totalOffset).contentShape(Rectangle()).gesture(DragGesture().onChanged { value in canvasPan = value.translation }.onEnded { value in canvasOffset.width += value.translation.width; canvasOffset.height += value.translation.height; canvasPan = .zero })
                            
                            let currentWorkflow = engine.workflows[idx]
                            ZStack {
                                ForEach(currentWorkflow.connections) { conn in
                                    if conn.id != modifyingConnectionID {
                                        let startPos = getPortAbsolutePosition(nodeID: conn.startNodeID, port: conn.startPort, in: currentWorkflow)
                                        let endPos = getPortAbsolutePosition(nodeID: conn.endNodeID, port: conn.endPort, in: currentWorkflow)
                                        ZStack { ConnectionLine(start: startPos, end: endPos, startPort: conn.startPort, endPort: conn.endPort).stroke(Color.white.opacity(0.001), lineWidth: 30).contextMenu { Button(role: .destructive) { engine.workflows[idx].connections.removeAll { $0.id == conn.id } } label: { Label("删除", systemImage: "trash") } }; ConnectionArrowLine(start: startPos, end: endPos, startPort: conn.startPort, endPort: conn.endPort, condition: conn.condition).allowsHitTesting(false) }
                                    }
                                }
                                
                                if let startID = draggingStartNodeID, let startPort = draggingStartPort, let currentPos = dragCurrentPosition { let startPos = getPortAbsolutePosition(nodeID: startID, port: startPort, in: currentWorkflow); let guessEndPort = guessEndPortDirection(start: startPos, current: currentPos); let condition = guessConditionForNewConnection(startID: startID, startPort: startPort, in: currentWorkflow); ConnectionArrowLine(start: startPos, end: currentPos, startPort: startPort, endPort: guessEndPort, condition: condition) }
                                
                                ForEach($engine.workflows[idx].actions) { $action in
                                    let position = getPosition(for: action.id, in: currentWorkflow)
                                    let isStart = !currentWorkflow.connections.contains(where: { $0.endNodeID == action.id })
                                    let isEnd = !currentWorkflow.connections.contains(where: { $0.startNodeID == action.id })
                                    
                                    CanvasNodeCardView(
                                        action: $action, isCurrent: engine.currentActionId == action.id, isStart: isStart, isEnd: isEnd, isConnecting: draggingStartNodeID != nil, cardWidth: nodeWidth, cardHeight: nodeHeight,
                                        onStartConnection: { port in draggingStartNodeID = action.id; draggingStartPort = port }, onDragConnection: { port, translation in let portPos = getPortAbsolutePosition(nodeID: action.id, port: port, in: currentWorkflow); dragCurrentPosition = CGPoint(x: portPos.x + translation.width, y: portPos.y + translation.height) }, onEndConnection: { port, dropTranslation in let portPos = getPortAbsolutePosition(nodeID: action.id, port: port, in: currentWorkflow); let globalDropPoint = CGPoint(x: portPos.x + dropTranslation.width, y: portPos.y + dropTranslation.height); handleConnectionDrop(dropLocation: globalDropPoint, startID: draggingStartNodeID, startPort: draggingStartPort, workflow: currentWorkflow); draggingStartNodeID = nil; draggingStartPort = nil; dragCurrentPosition = nil }, onDelete: { engine.removeAction(id: action.id) }
                                    ).position(position)
                                    .gesture(
                                        DragGesture()
                                            .onChanged { value in
                                                var newX = value.location.x; var newY = value.location.y; var foundSnapX: CGFloat? = nil; var foundSnapY: CGFloat? = nil
                                                for other in currentWorkflow.actions where other.id != action.id { let otherPos = getPosition(for: other.id, in: currentWorkflow); if abs(newX - otherPos.x) < 15 { newX = otherPos.x; foundSnapX = otherPos.x }; if abs(newY - otherPos.y) < 15 { newY = otherPos.y; foundSnapY = otherPos.y } }
                                                snapLineX = foundSnapX; snapLineY = foundSnapY; engine.nodePositions[action.id] = CGPoint(x: newX, y: newY)
                                            }
                                            .onEnded { value in snapLineX = nil; snapLineY = nil; if let pos = engine.nodePositions[action.id] { engine.updateActionPosition(id: action.id, position: pos) } else { engine.updateActionPosition(id: action.id, position: value.location) } }
                                    )
                                    .onAppear { if action.positionX == 0 && action.positionY == 0 { let defPos = defaultPosition(in: geo.size, offset: totalOffset); engine.updateActionPosition(id: action.id, position: defPos); engine.nodePositions[action.id] = defPos } }
                                }
                                
                                ForEach(currentWorkflow.connections) { conn in
                                    let endPos = getPortAbsolutePosition(nodeID: conn.endNodeID, port: conn.endPort, in: currentWorkflow); Circle().fill(Color.white).frame(width: 14, height: 14).overlay(Circle().stroke(Color.blue, lineWidth: 2)).background(Color.white.opacity(0.001).frame(width: 30, height: 30)).position(endPos).opacity(modifyingConnectionID == conn.id ? 0 : 1)
                                        .gesture(DragGesture().onChanged { value in if modifyingConnectionID != conn.id { modifyingConnectionID = conn.id; draggingStartNodeID = conn.startNodeID; draggingStartPort = conn.startPort }; dragCurrentPosition = CGPoint(x: endPos.x + value.translation.width, y: endPos.y + value.translation.height) }.onEnded { value in let globalDropPoint = CGPoint(x: endPos.x + value.translation.width, y: endPos.y + value.translation.height); let sourceID = conn.startNodeID; let sourcePort = conn.startPort; engine.workflows[idx].connections.removeAll { $0.id == conn.id }; handleConnectionDrop(dropLocation: globalDropPoint, startID: sourceID, startPort: sourcePort, workflow: engine.workflows[idx]); modifyingConnectionID = nil; draggingStartNodeID = nil; draggingStartPort = nil; dragCurrentPosition = nil })
                                }
                                
                                if let snapX = snapLineX { Path { p in p.move(to: CGPoint(x: snapX, y: -5000)); p.addLine(to: CGPoint(x: snapX, y: 5000)) }.stroke(Color.orange.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [5, 5])) }
                                if let snapY = snapLineY { Path { p in p.move(to: CGPoint(x: -5000, y: snapY)); p.addLine(to: CGPoint(x: 5000, y: snapY)) }.stroke(Color.orange.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [5, 5])) }
                            }.offset(totalOffset)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                    }
                } else { ContentUnavailableView("未选择流程", systemImage: "mouse") }
                Divider(); LogConsoleView(logs: engine.logs)
            }.navigationTitle("流程编排").navigationSplitViewColumnWidth(min: 500, ideal: 800)
        } detail: {
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
            .navigationTitle("组件库").listStyle(.sidebar).navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 300)
        }.frame(minWidth: 1000, idealWidth: 1200, minHeight: 700, idealHeight: 800).onAppear { engine.checkPermissions() }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                HStack(spacing: 12) {
                    Button(action: { showGlobalSettings.toggle() }) {
                        Label("全局设置", systemImage: "gearshape.fill").foregroundColor(.secondary)
                    }
                    .help("打开系统全局设置与 AI Prompt 调优")
                    .popover(isPresented: $showGlobalSettings, arrowEdge: .bottom) {
                        GlobalSettingsPopoverView()
                    }
                    
                    Button(action: { openWindow(id: "agentMonitor") }) {
                        Label("AI 监控", systemImage: "eye.square").foregroundColor(.cyan)
                    }
                    .help("打开 WebAgent 运行时感知与思考监控面板")
                }
            }
        }
    }
    
    private func toggleRecording() {
        if isRecordingUI {
            MacroRecorder.shared.stopRecording()
            isRecordingUI = false
            engine.log("⏹️ 录制结束，已在画板生成操作节点。")
            
            // [✨修改] 仅当设置开启时，录制结束才干预恢复窗口
            if appSettings.minimizeOnRun {
                if let mainWindow = NSApp.windows.first(where: { $0.className.contains("AppKitWindow") }) {
                    mainWindow.deminiaturize(nil)
                }
            }
        } else {
            Task {
                engine.log("⏱️ 准备录制，倒计时 3 秒...")
                await engine.showCountdownHUD(message: "系统动作录制准备中...")
                
                MacroRecorder.shared.startRecording()
                isRecordingUI = true
                engine.log("🔴 开始录制，请在系统内操作，完成后点击通知栏或回到应用停止录制...")
                
                // [✨修改] 根据用户设置决定是否自动最小化
                if appSettings.minimizeOnRun {
                    await MainActor.run {
                        NSApp.windows.first(where: { $0.className.contains("AppKitWindow") })?.miniaturize(nil)
                    }
                }
            }
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
    private func handleConnectionDrop(dropLocation: CGPoint?, startID: UUID?, startPort: PortPosition?, workflow: Workflow) { guard let dropPoint = dropLocation, let sourceID = startID, let sPort = startPort else { return }; var closest: (nodeID: UUID, port: PortPosition, distance: CGFloat)? = nil; for targetNode in workflow.actions { if targetNode.id == sourceID { continue }; for port in PortPosition.allCases { let targetPortPos = getPortAbsolutePosition(nodeID: targetNode.id, port: port, in: workflow); let distance = hypot(targetPortPos.x - dropPoint.x, targetPortPos.y - dropPoint.y); if distance <= snapDistance { if closest == nil || distance < closest!.distance { closest = (targetNode.id, port, distance) } } } }; if let bestMatch = closest { let condition = guessConditionForNewConnection(startID: sourceID, startPort: sPort, in: workflow); engine.addConnection(source: sourceID, sourcePort: sPort, target: bestMatch.nodeID, targetPort: bestMatch.port, condition: condition) } }
}

// 替换原有的 CanvasNodeCardView
struct CanvasNodeCardView: View {
    @Binding var action: RPAAction
    var isCurrent: Bool; var isStart: Bool; var isEnd: Bool; var isConnecting: Bool
    let cardWidth: CGFloat; let cardHeight: CGFloat
    var onStartConnection: (PortPosition) -> Void; var onDragConnection: (PortPosition, CGSize) -> Void; var onEndConnection: (PortPosition, CGSize) -> Void; var onDelete: () -> Void
    @State private var showSettings = false
    @State private var breathePhase: CGFloat = 0

    var themeColor: Color {
        // 禁用状态统一降级为灰色系
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
            HStack(spacing: 8) {
                Image(systemName: action.type.icon)
                    .font(.system(size: 16))
                    .foregroundColor(isCurrent ? .white : themeColor)
                
                TextField(action.displayTitle, text: $action.customName)
                    .font(.system(size: 12, weight: .bold))
                    // 禁用时文字呈现删除线视觉
                    .strikethrough(action.isDisabled, color: .gray)
                    .foregroundColor(isCurrent ? .white : (action.isDisabled ? .gray : .primary))
                    .textFieldStyle(.plain)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .disabled(isCurrent)
                
                Button(action: { showSettings.toggle() }) {
                    Image(systemName: "gearshape.fill")
                        .foregroundColor(isCurrent ? .white.opacity(0.8) : .gray)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10).frame(width: cardWidth, height: cardHeight)
            .background(RoundedRectangle(cornerRadius: 8).fill(isCurrent ? themeColor.opacity(0.9) : Color(NSColor.controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(isCurrent ? themeColor.opacity(0.6 + breathePhase * 0.4) : (isStart ? Color.green.opacity(0.8) : (isEnd ? Color.orange.opacity(0.8) : Color.gray.opacity(0.3))), lineWidth: isCurrent ? (2 + breathePhase * 1.5) : 1))
            .shadow(color: isCurrent ? themeColor.opacity(0.5 - breathePhase * 0.2) : .black.opacity(0.05), radius: isCurrent ? (6 + breathePhase * 8) : 2, y: 2)
            .scaleEffect(isCurrent ? (1.02 + breathePhase * 0.02) : 1.0)
            .animation(.easeOut(duration: 0.2), value: isCurrent)
            // [✨修改] 增加禁用选项以及视觉穿透力衰减
            .opacity(action.isDisabled ? 0.6 : 1.0)
            .contextMenu {
                Button(action: { action.isDisabled.toggle() }) {
                    Label(action.isDisabled ? "启用此节点" : "禁用此节点 (运行时跳过)", systemImage: action.isDisabled ? "play.circle" : "pause.circle")
                }
                Divider()
                Button(role: .destructive, action: onDelete) { Label("删除节点", systemImage: "trash") }
            }
            
            if isStart || isEnd { Text(isStart ? "▶ 起点" : "🏁 终点").font(.system(size: 8, weight: .bold)).foregroundColor(.white).padding(.horizontal, 4).padding(.vertical, 2).background(isStart ? Color.green : Color.orange).clipShape(Capsule()).offset(x: cardWidth / 2 - 10, y: -cardHeight / 2 - 6) }
            ForEach(PortPosition.allCases, id: \.self) { port in let portOffset = getPortLocalOffset(port: port); Circle().fill(Color(NSColor.controlBackgroundColor)).frame(width: 10, height: 10).overlay(Circle().stroke(themeColor.opacity(0.6), lineWidth: 2)).scaleEffect(isConnecting ? 1.3 : 1.0).animation(.spring(), value: isConnecting).offset(x: portOffset.width, y: portOffset.height).overlay(Color.white.opacity(0.001).frame(width: 25, height: 25).offset(x: portOffset.width, y: portOffset.height).gesture(DragGesture(minimumDistance: 0).onChanged { value in if value.translation.width == 0 && value.translation.height == 0 { onStartConnection(port) } else { onDragConnection(port, value.translation) } }.onEnded { value in onEndConnection(port, value.translation) })); if action.type == .ocrText || action.type == .condition { if port == .right { Text("✅").font(.system(size: 8)).foregroundColor(.green).offset(x: portOffset.width + 12, y: portOffset.height) } else if port == .bottom { Text("❌").font(.system(size: 8)).foregroundColor(.red).offset(x: portOffset.width, y: portOffset.height + 12) } } }
        }
        .onChange(of: isCurrent) { _, current in
            if current { breathePhase = 0; withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { breathePhase = 1 } }
            else { withAnimation(.easeOut(duration: 0.2)) { breathePhase = 0 } }
        }
        .onAppear { if isCurrent { withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { breathePhase = 1 } } }
        .popover(isPresented: $showSettings, arrowEdge: .trailing) { ActionSettingsPopoverView(action: $action, showSettings: $showSettings) }
    }
    
    private func getPortLocalOffset(port: PortPosition) -> CGSize { switch port { case .top: return CGSize(width: 0, height: -cardHeight / 2); case .bottom: return CGSize(width: 0, height: cardHeight / 2); case .left: return CGSize(width: -cardWidth / 2, height: 0); case .right: return CGSize(width: cardWidth / 2, height: 0) } }
}

// [✨性能核心优化] 重构控制台视图，解决 AI 打字机引发的 UI 假死与资源暴涨
// MARK: - [✨新增] 日志解析节点模型
struct ParsedLogNode: Identifiable {
    let id = UUID()
    var isThink: Bool
    var text: String
}

// MARK: - [✨新增] 单行日志渲染视图（支持深度思考折叠）
struct LogRowView: View {
    let text: String
    @State private var isThinkExpanded = false // 默认折叠
    
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
    
    // 动态解析带有 <think> 标签的流式字符串
    private func parseLog(_ text: String) -> [ParsedLogNode] {
        var result: [ParsedLogNode] = []
        var currentText = text
        while let startRange = currentText.range(of: "<think>") {
            let before = String(currentText[..<startRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !before.isEmpty { result.append(ParsedLogNode(isThink: false, text: before)) }
            
            let remaining = String(currentText[startRange.upperBound...])
            if let endRange = remaining.range(of: "</think>") {
                // 已闭合的思考块
                let thinkText = String(remaining[..<endRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                result.append(ParsedLogNode(isThink: true, text: thinkText))
                currentText = String(remaining[endRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                // 尚未闭合的思考块（正在流式输出中）
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

// [✨性能与体验核心优化] 重构控制台视图
struct LogConsoleView: View {
    var logs: [String]
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // 必须使用 LazyVStack，保证性能
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(logs.indices, id: \.self) { index in
                        // 使用全新的折叠行视图
                        LogRowView(text: logs[index])
                            .id(index)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding()
            }
            .frame(height: 120).background(Color(NSColor.windowBackgroundColor))
            // 监听新增行数时平滑滚动
            .onChange(of: logs.count) { _, _ in
                if !logs.isEmpty { withAnimation { proxy.scrollTo(logs.count - 1, anchor: .bottom) } }
            }
            // 监听最后一行流式打字时的无动画极速滚动，降低渲染负担
            .onChange(of: logs.last) { _, _ in
                if !logs.isEmpty { proxy.scrollTo(logs.count - 1, anchor: .bottom) }
            }
        }
    }
}

struct ConnectionLine: Shape { var start: CGPoint; var end: CGPoint; var startPort: PortPosition; var endPort: PortPosition; func path(in rect: CGRect) -> Path { var path = Path(); path.move(to: start); path.addCurve(to: end, control1: CGPoint(x: start.x + startPort.controlOffset.width, y: start.y + startPort.controlOffset.height), control2: CGPoint(x: end.x + endPort.controlOffset.width, y: end.y + endPort.controlOffset.height)); return path } }
struct ConnectionArrowLine: View { var start: CGPoint; var end: CGPoint; var startPort: PortPosition; var endPort: PortPosition; var condition: ConnectionCondition; var body: some View { let c1 = CGPoint(x: start.x + startPort.controlOffset.width, y: start.y + startPort.controlOffset.height); let c2 = CGPoint(x: end.x + endPort.controlOffset.width, y: end.y + endPort.controlOffset.height); let t: CGFloat = 0.9; let mt: CGFloat = 1.0 - t; let arrowX = mt*mt*mt*start.x + 3.0*mt*mt*t*c1.x + 3.0*mt*t*t*c2.x + t*t*t*end.x; let arrowY = mt*mt*mt*start.y + 3.0*mt*mt*t*c1.y + 3.0*mt*t*t*c2.y + t*t*t*end.y; let dX = 3.0*mt*mt*(c1.x - start.x) + 6.0*mt*t*(c2.x - c1.x) + 3.0*t*t*(end.x - c2.x); let dY = 3.0*mt*mt*(c1.y - start.y) + 6.0*mt*t*(c2.y - c1.y) + 3.0*t*t*(end.y - c2.y); let angle = atan2(dY, dX); let strokeColor = condition == .success ? Color.green : (condition == .failure ? Color.red : Color.blue); ZStack { ConnectionLine(start: start, end: end, startPort: startPort, endPort: endPort).stroke(strokeColor.opacity(0.8), style: StrokeStyle(lineWidth: 2, dash: condition == .failure ? [4, 4] : [])); Image(systemName: "play.fill").font(.system(size: 12)).foregroundColor(strokeColor).rotationEffect(.radians(Double(angle))).position(x: arrowX, y: arrowY) } } }
struct GridBackgroundView: View { let gridSize: CGFloat = 20; var offset: CGSize; var body: some View { GeometryReader { geometry in Path { path in let w = geometry.size.width; let h = geometry.size.height; let startX = offset.width.truncatingRemainder(dividingBy: gridSize); let startY = offset.height.truncatingRemainder(dividingBy: gridSize); for x in stride(from: startX - gridSize, through: w + gridSize, by: gridSize) { path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: h)) }; for y in stride(from: startY - gridSize, through: h + gridSize, by: gridSize) { path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: w, y: y)) } }.stroke(Color.gray.opacity(0.04), lineWidth: 1) }.background(Color(NSColor.textBackgroundColor)) } }

// MARK: - [✨新增] 极客级全局设置面板
struct GlobalSettingsPopoverView: View {
    @ObservedObject var settings = AppSettings.shared
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "gearshape.fill").foregroundColor(.blue)
                Text("系统全局设置").font(.headline)
            }
            Divider()
            
            // [✨修改] 完全移除了与 AIConfigManager 功能重复的基础配置界面
            
            // [✨新增] WebAgent 运行控制
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
                        settings.webAgentPrompt = WebAgentParams.defaultPrompt
                    }.font(.caption)
                }
                
                TextEditor(text: Binding(
                    get: { settings.webAgentPrompt.isEmpty ? WebAgentParams.defaultPrompt : settings.webAgentPrompt },
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
            }
            .padding(10)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
            
        }
        .padding()
        .frame(width: 400)
    }
}
