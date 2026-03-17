//////////////////////////////////////////////////////////////////
// 文件名：AgentMonitorView.swift
// 文件说明：RPA感知监控
// 功能说明：
// 代码要求：没有要求修改不用输出代码，请保证代码的逻辑和完整性，保留代码中的所有注释内容
//////////////////////////////////////////////////////////////////

import SwiftUI
import Combine

// MARK: - 1. 感知状态管理器
class AgentMonitorManager: ObservableObject {
    static let shared = AgentMonitorManager()
    
    @Published var currentVision: NSImage?
    @Published var domSummary: String = ""
    @Published var llmThought: String = ""
    @Published var plannedSteps: [String] = []
    
    // [✨新增] 专门用于存放底层 JS 脚本和执行返回值的日志
    @Published var actionExecutionLogs: [String] = []
    
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
                contentRect: NSRect(x: 0, y: 0, width: 850, height: 650),
                styleMask: [.titled, .closable, .resizable, .miniaturizable, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            newWin.title = "🤖 WebAgent 感知与决策监控"
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
        llmThought = "等待视觉接入..."
        plannedSteps.removeAll()
        actionExecutionLogs.removeAll() // [✨新增] 任务开始前清空执行日志
        isProcessing = true
    }
}

// MARK: - 2. 运行时监控控制台 UI
struct AgentMonitorView: View {
    @StateObject private var monitor = AgentMonitorManager.shared
    
    var body: some View {
        VStack(spacing: 0) {
            // ==========================================
            // 顶部状态与控制栏
            // ==========================================
            HStack(spacing: 8) {
                Circle()
                    .fill(monitor.isProcessing ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
                
                Text(monitor.isProcessing ? "Agent 正在思考与执行..." : "Agent 待命中")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(monitor.isProcessing ? .green : .gray)
                
                Spacer()
                
                // 自动弹出开关，方便用户随时调整
                Toggle("运行时自动弹出窗口", isOn: $monitor.autoShowAgentMonitor)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.system(size: 11))
                    .tint(.blue)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
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
                    if let img = monitor.currentVision {
                        Image(nsImage: img)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 160) // 限制最大高度，避免占据太多垂直空间
                            .background(Color.black.opacity(0.3))
                            .clipped()
                    }
                    
                    Divider()
                    
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if !monitor.llmThought.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("🧠 决策思考")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundColor(.cyan)
                                    Text(monitor.llmThought)
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                }
                            }
                            
                            if !monitor.domSummary.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("📄 DOM 摘要 (精简)")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundColor(.orange)
                                    Text(monitor.domSummary)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .lineLimit(5) // 限制行数，避免太长导致滚动灾难
                                }
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(minWidth: 200, idealWidth: 260)
                
                // ------------------------------------------
                // 右侧面板：执行计划与实时日志
                // ------------------------------------------
                VStack(spacing: 0) {
                    // 1. 计划区
                    if !monitor.plannedSteps.isEmpty {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("📋 当前执行计划")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.green)
                                
                                ForEach(monitor.plannedSteps.indices, id: \.self) { idx in
                                    HStack(alignment: .top, spacing: 4) {
                                        Text("\(idx+1).")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundColor(.gray)
                                        Text(monitor.plannedSteps[idx])
                                            .font(.system(size: 10))
                                    }
                                }
                            }
                            .padding(10)
                        }
                        .frame(maxHeight: 130) // 限制计划区域高度
                        
                        Divider()
                    }
                    
                    // 2. 日志区
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("⚡️ 动作执行日志")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.pink)
                                
                                ForEach(monitor.actionExecutionLogs.indices, id: \.self) { index in
                                    Text(monitor.actionExecutionLogs[index])
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
                        .onChange(of: monitor.actionExecutionLogs.count) { _, newCount in
                            if newCount > 0 {
                                withAnimation { proxy.scrollTo("log_\(newCount - 1)", anchor: .bottom) }
                            }
                        }
                    }
                }
                .frame(minWidth: 250, idealWidth: 390)
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
    }
}
