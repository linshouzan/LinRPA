//
//  LinRPAApp.swift
//  LinRPA主程序

import SwiftUI

@main
struct LinRPAApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        
        // [✨ 新增 1] 注册独立的 Agent 监控窗口，赋予一个唯一 ID "agentMonitor"
        Window("WebAgent 感知与决策监控", id: "agentMonitor") {
            AgentMonitorView()
                // 强制应用暗色模式，让黑客/极客监控面板更有氛围感
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 800, height: 600) // 设置默认弹出尺寸
        
        // [✨新增] macOS 原生设置面板支持
        Settings {
            AISettingsView()
        }
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
