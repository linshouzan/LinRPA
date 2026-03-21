//////////////////////////////////////////////////////////////////
// 文件名：AgentMonitorView.swift
// 文件说明：RPA感知监控 (全息快照回放版)
// 功能说明：支持实时多模态感知监控，支持基于时间轴的每轮快照回放（DOM/AXTree/Prompt/画面等）
// 代码要求：请保证代码的逻辑和完整性，保留代码中的所有注释内容
//////////////////////////////////////////////////////////////////

import SwiftUI
import Combine
import AppKit

struct AgentRoundSnapshot: Identifiable {
    let id = UUID()
    let roundIndex: Int
    let vision: NSImage?
    let prompt: String
    let thought: String
    let domSummary: String
    let axTreeSummary: String
    let plannedSteps: [String]
    let executionLogs: [String]
    let timestamp: Date = Date()
}

// MARK: - 1. 感知状态管理器
class AgentMonitorManager: ObservableObject {
    static let shared = AgentMonitorManager()
    
    // 实时状态
    @Published var currentVision: NSImage?
    @Published var domSummary: String = ""
    @Published var axTreeSummary: String = "" // [✨新增] AXTree 实时展示
    @Published var llmThought: String = ""
    @Published var plannedSteps: [String] = []
    @Published var actionExecutionLogs: [String] = []
    
    // [✨新增] 历史快照时间轴
    @Published var roundSnapshots: [AgentRoundSnapshot] = []
    
    @Published var isProcessing: Bool = false
    @AppStorage("autoShowAgentMonitor") var autoShowAgentMonitor: Bool = false
    
    private var window: NSWindow?
    
    @MainActor
    func showWindow(isAutoTrigger: Bool = false) {
        if isAutoTrigger && !autoShowAgentMonitor {
            return
        }
        if window == nil {
            let view = AgentMonitorView()
            let newWin = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 950, height: 750), // 稍微调大以容纳更多观测数据
                styleMask: [.titled, .closable, .resizable, .miniaturizable, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            newWin.title = "🤖 WebAgent 感知与决策监控 (全息观测台)"
            newWin.level = .normal
            newWin.isReleasedWhenClosed = false
            newWin.contentView = NSHostingView(rootView: view)
            newWin.center()
            window = newWin
        }
        window?.makeKeyAndOrderFront(nil)
    }
    
    @MainActor
    func resetForNewTask() {
        currentVision = nil
        domSummary = "正在扫描页面结构..."
        axTreeSummary = ""
        llmThought = "等待视觉接入..."
        plannedSteps.removeAll()
        actionExecutionLogs.removeAll()
        roundSnapshots.removeAll() // 清空上一任务的快照
        isProcessing = true
    }
    
    // [✨新增] 归档保存每一轮的快照
    @MainActor
    func archiveRound(round: Int, vision: NSImage?, prompt: String, thought: String, dom: String, axTree: String, steps: [String], logs: [String]) {
        let snapshot = AgentRoundSnapshot(
            roundIndex: round, vision: vision, prompt: prompt,
            thought: thought, domSummary: dom, axTreeSummary: axTree,
            plannedSteps: steps, executionLogs: logs
        )
        self.roundSnapshots.append(snapshot)
    }
}

// MARK: - 2. 运行时监控控制台 UI
struct AgentMonitorView: View {
    @StateObject private var monitor = AgentMonitorManager.shared
    
    // [✨新增] 用于追踪用户当前正在查看的快照（nil 表示正在查看实时数据）
    @State private var selectedSnapshotID: UUID? = nil
    @State private var showPromptModal: Bool = false
    
    // 动态计算当前展示的数据源（如果是回放模式就用快照，否则用实时数据）
    private var displayVision: NSImage? { activeSnapshot?.vision ?? monitor.currentVision }
    private var displayThought: String { activeSnapshot?.thought ?? monitor.llmThought }
    private var displayDOM: String { activeSnapshot?.domSummary ?? monitor.domSummary }
    private var displayAXTree: String { activeSnapshot?.axTreeSummary ?? monitor.axTreeSummary }
    private var displaySteps: [String] { activeSnapshot?.plannedSteps ?? monitor.plannedSteps }
    private var displayLogs: [String] { activeSnapshot?.executionLogs ?? monitor.actionExecutionLogs }
    private var displayPrompt: String { activeSnapshot?.prompt ?? "当前为实时模式，Prompt仅在轮次结算后生成快照中提供。" }
    
    private var activeSnapshot: AgentRoundSnapshot? {
        guard let id = selectedSnapshotID else { return nil }
        return monitor.roundSnapshots.first(where: { $0.id == id })
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // ==========================================
            // 顶部状态与时间轴栏
            // ==========================================
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(monitor.isProcessing ? Color.green : Color.gray)
                        .frame(width: 8, height: 8)
                    
                    Text(monitor.isProcessing ? "Agent 正在思考与执行..." : "Agent 待命中")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(monitor.isProcessing ? .green : .gray)
                    
                    Spacer()
                    
                    Toggle("运行时自动弹出窗口", isOn: $monitor.autoShowAgentMonitor)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .font(.system(size: 11))
                        .tint(.blue)
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 4)
                
                // [✨新增] 时间轴导航栏
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Button(action: { selectedSnapshotID = nil }) {
                            Text("● Live 实时")
                                .font(.system(size: 11, weight: .bold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(selectedSnapshotID == nil ? Color.blue : Color.gray.opacity(0.2))
                                .foregroundColor(.white)
                                .cornerRadius(6)
                        }
                        .buttonStyle(PlainButtonStyle())
                        
                        ForEach(monitor.roundSnapshots) { snapshot in
                            Button(action: { selectedSnapshotID = snapshot.id }) {
                                Text("第 \(snapshot.roundIndex) 轮快照")
                                    .font(.system(size: 11))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(selectedSnapshotID == snapshot.id ? Color.purple : Color.gray.opacity(0.2))
                                    .foregroundColor(.white)
                                    .cornerRadius(6)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
            }
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            // ==========================================
            // 核心布局：左右分栏结构 (HSplitView 支持自由拖拽)
            // ==========================================
            HSplitView {
                
                // ------------------------------------------
                // 左侧面板：视觉画面与大脑思考
                // ------------------------------------------
                VStack(spacing: 0) {
                    if let img = displayVision {
                        Image(nsImage: img)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 200)
                            .background(Color.black.opacity(0.3))
                            .clipped()
                    }
                    
                    Divider()
                    
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            
                            // [✨新增] 查看完整 Prompt 的入口 (仅在回放模式可用)
                            if selectedSnapshotID != nil {
                                Button(action: { showPromptModal = true }) {
                                    Label("查看发给 AI 的完整 Prompt", systemImage: "text.quote")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundColor(.purple)
                                        .padding(6)
                                        .frame(maxWidth: .infinity, alignment: .center)
                                        .background(Color.purple.opacity(0.1))
                                        .cornerRadius(6)
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                            
                            if !displayThought.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("🧠 决策思考")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundColor(.cyan)
                                    Text(displayThought)
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                }
                            }
                            
                            if !displayDOM.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("📄 DOM 摘要 (精简)")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundColor(.orange)
                                    Text(displayDOM)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .lineLimit(8)
                                }
                            }
                            
                            // [✨新增] AXTree 透出
                            if !displayAXTree.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("👁️ AXTree 原生视图 (坐标轴体系)")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundColor(.indigo)
                                    Text(displayAXTree)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .lineLimit(8)
                                }
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(minWidth: 200, idealWidth: 320)
                
                // ------------------------------------------
                // 右侧面板：执行计划与实时日志
                // ------------------------------------------
                VStack(spacing: 0) {
                    // 1. 计划区
                    if !displaySteps.isEmpty {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("📋 \(selectedSnapshotID == nil ? "当前" : "本轮")执行计划")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.green)
                                
                                ForEach(displaySteps.indices, id: \.self) { idx in
                                    HStack(alignment: .top, spacing: 4) {
                                        Text("\(idx+1).")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundColor(.gray)
                                        Text(displaySteps[idx])
                                            .font(.system(size: 10))
                                    }
                                }
                            }
                            .padding(10)
                        }
                        .frame(maxHeight: 150)
                        
                        Divider()
                    }
                    
                    // 2. 日志区
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("⚡️ 动作执行日志")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.pink)
                                
                                ForEach(displayLogs.indices, id: \.self) { index in
                                    Text(displayLogs[index])
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(Color.gray.opacity(0.9))
                                        .padding(.vertical, 4)
                                        .padding(.horizontal, 6)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(Color.black.opacity(0.2))
                                        .cornerRadius(4)
                                        .id("log_\(index)")
                                }
                            }
                            .padding(10)
                        }
                        .background(Color(NSColor.controlBackgroundColor))
                        .onChange(of: displayLogs.count) { _, newCount in
                            if newCount > 0 && selectedSnapshotID == nil {
                                withAnimation { proxy.scrollTo("log_\(newCount - 1)", anchor: .bottom) }
                            }
                        }
                    }
                }
                .frame(minWidth: 250, idealWidth: 420)
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        // [✨新增] Prompt 弹窗
        .sheet(isPresented: $showPromptModal) {
            VStack {
                Text("本轮发送给 AI 的完整 Prompt")
                    .font(.headline)
                    .padding()
                ScrollView {
                    Text(displayPrompt)
                        .font(.system(size: 11, design: .monospaced))
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color.black.opacity(0.1))
                .cornerRadius(8)
                .padding(.horizontal)
                
                Button("关闭") { showPromptModal = false }
                    .padding()
            }
            .frame(width: 600, height: 500)
        }
    }
}
