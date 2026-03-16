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
    
    private var window: NSWindow?
    
    @MainActor
    func showWindow() {
        if window == nil {
            let view = AgentMonitorView()
            let newWin = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 850, height: 650),
                styleMask: [.titled, .closable, .resizable, .miniaturizable, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            newWin.title = "🤖 WebAgent 感知与决策监控"
            newWin.level = .floating
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
            // 顶部：Agent 视觉区
            ZStack {
                Color.black.opacity(0.8)
                if let img = monitor.currentVision {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(8)
                } else {
                    VStack {
                        Image(systemName: "eye.slash.fill").font(.largeTitle).foregroundColor(.gray)
                        Text("等待 Agent 获取视野...").foregroundColor(.gray).padding(.top, 4)
                    }
                }
                
                if monitor.isProcessing {
                    VStack {
                        Spacer()
                        ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .red)).scaleEffect(1.5)
                        Spacer()
                    }
                }
            }
            .frame(minHeight: 250, maxHeight: 400)
            
            Divider().background(Color.gray)
            
            // 底部：内部状态分析区
            HSplitView {
                // 左侧：DOM 结构缓存
                VStack(alignment: .leading) {
                    Text("📦 提取的深度DOM树 (SoM)")
                        .font(.caption).bold().foregroundColor(.cyan)
                        .padding([.top, .leading], 8)
                    
                    ScrollView {
                        Text(monitor.domSummary.isEmpty ? "暂无数据" : monitor.domSummary)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.green)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                }
                .frame(minWidth: 200)
                
                // 右侧：大模型思维链与底层执行日志
                VStack(alignment: .leading) {
                    Text("🧠 AI 决策与底层执行日志")
                        .font(.caption).bold().foregroundColor(.purple)
                        .padding([.top, .leading], 8)
                    
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(monitor.llmThought.isEmpty ? "等待流式推理..." : monitor.llmThought)
                                    .font(.system(size: 12))
                                    .foregroundColor(.primary)
                                
                                if !monitor.plannedSteps.isEmpty {
                                    Divider()
                                    Text("⚡️ 动作队列序列:")
                                        .font(.system(size: 11, weight: .bold)).foregroundColor(.orange)
                                    ForEach(monitor.plannedSteps, id: \.self) { step in
                                        Text(step)
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundColor(.white)
                                            .padding(.vertical, 2).padding(.horizontal, 6)
                                            .background(Color.blue.opacity(0.3)).cornerRadius(4)
                                    }
                                }
                                
                                // [✨新增] 底层 JS 脚本与返回结果监控区
                                if !monitor.actionExecutionLogs.isEmpty {
                                    Divider()
                                    Text("🛠️ 底层 JS 注入与执行反馈:")
                                        .font(.system(size: 11, weight: .bold)).foregroundColor(.pink)
                                    
                                    ForEach(monitor.actionExecutionLogs.indices, id: \.self) { index in
                                        Text(monitor.actionExecutionLogs[index])
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundColor(.gray)
                                            .padding(6)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background(Color.black.opacity(0.3))
                                            .cornerRadius(6)
                                            .id("log_\(index)") // 锚点用于滚动
                                    }
                                }
                            }
                            .padding(8)
                        }
                        .onChange(of: monitor.actionExecutionLogs.count) { _, newCount in
                            // 当有新日志写入时，自动滚动到最底部
                            if newCount > 0 {
                                withAnimation { proxy.scrollTo("log_\(newCount - 1)", anchor: .bottom) }
                            }
                        }
                    }
                }
                .frame(minWidth: 250)
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
    }
}
