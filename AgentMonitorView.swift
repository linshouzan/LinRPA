//////////////////////////////////////////////////////////////////
// 文件名：MacroRecorder.swift
// 文件说明：这是适用于 macos 14+ 的RPA WebAgent感知监控
// 功能说明：
// 代码要求：没有要求修改不用输出代码，请保证代码的逻辑和完整性，保留代码中的所有注释内容
//////////////////////////////////////////////////////////////////

import SwiftUI
import Combine

// MARK: - 1. 感知状态管理器
class AgentMonitorManager: ObservableObject {
    static let shared = AgentMonitorManager()
    
    @Published var currentVision: NSImage?     // Agent 眼中带有红框的截图
    @Published var domSummary: String = ""     // 提取出的可交互 DOM 列表
    @Published var llmThought: String = ""     // 模型正在思考的推理过程
    @Published var plannedSteps: [String] = [] // 计划执行的动作序列
    @Published var isProcessing: Bool = false  // 运行状态指示器
}

// MARK: - 2. 运行时监控控制台 UI
struct AgentMonitorView: View {
    @StateObject private var monitor = AgentMonitorManager.shared
    
    var body: some View {
        VStack(spacing: 0) {
            // 顶部：Agent 视觉区 (多模态的“眼”)
            ZStack {
                Color.black.opacity(0.8)
                if let img = monitor.currentVision {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(8)
                } else {
                    VStack {
                        Image(systemName: "eye.slash.fill")
                            .font(.largeTitle)
                            .foregroundColor(.gray)
                        Text("等待 Agent 获取视野...")
                            .foregroundColor(.gray)
                            .padding(.top, 4)
                    }
                }
                
                // 扫描动画叠加层
                if monitor.isProcessing {
                    VStack {
                        Spacer()
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .red))
                            .scaleEffect(1.5)
                        Spacer()
                    }
                }
            }
            .frame(minHeight: 250, maxHeight: 400)
            
            Divider().background(Color.gray)
            
            // 底部：内部状态分析区 (多模态的“脑”)
            HSplitView {
                // 左侧：DOM 结构缓存
                VStack(alignment: .leading) {
                    Text("📦 提取的深度DOM树 (SoM)")
                        .font(.caption).bold()
                        .foregroundColor(.cyan)
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
                
                // 右侧：大模型思维链与动作池
                VStack(alignment: .leading) {
                    Text("🧠 AI 实时推演与决策")
                        .font(.caption).bold()
                        .foregroundColor(.purple)
                        .padding([.top, .leading], 8)
                    
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(monitor.llmThought.isEmpty ? "等待流式推理..." : monitor.llmThought)
                                .font(.system(size: 12))
                                .foregroundColor(.primary)
                            
                            if !monitor.plannedSteps.isEmpty {
                                Divider()
                                Text("⚡️ 动作队列序列:")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.orange)
                                ForEach(monitor.plannedSteps, id: \.self) { step in
                                    Text(step)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(.white)
                                        .padding(.vertical, 2)
                                        .padding(.horizontal, 6)
                                        .background(Color.blue.opacity(0.3))
                                        .cornerRadius(4)
                                }
                            }
                        }
                        .padding(8)
                    }
                }
                .frame(minWidth: 250)
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
    }
}
