//////////////////////////////////////////////////////////////////
// 文件名：MacroRecorder.swift
// 文件说明：这是适用于 macos 14+ 的RPA录制功能管理器
// 功能说明：
// 代码要求：没有要求修改不用输出代码，请保证代码的逻辑和完整性，保留代码中的所有注释内容
//////////////////////////////////////////////////////////////////

import SwiftUI
import Foundation
import AppKit
import CoreGraphics

//////////////////////////////////////////////////////////////////
// MARK: - MacroRecorder
// 录屏功能管理器
//////////////////////////////////////////////////////////////////

class MacroRecorder {
    static let shared = MacroRecorder()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    
    var isRecording = false
    var onActionRecorded: ((RPAAction) -> Void)?
    
    // 防抖与合并状态
    private var typingBuffer = ""
    private var typingTimer: Timer?
    
    func startRecording() {
        guard !isRecording else { return }
        let eventMask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.keyDown.rawValue)
        
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                let recorder = Unmanaged<MacroRecorder>.fromOpaque(refcon!).takeUnretainedValue()
                recorder.handleEvent(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        
        if let tap = eventTap {
            runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            isRecording = true
            flushTypingBuffer()
            print("🔴 录制已启动")
        }
    }
    
    func stopRecording() {
        guard isRecording else { return }
        flushTypingBuffer()
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            eventTap = nil
            runLoopSource = nil
        }
        isRecording = false
        print("⏹️ 录制已停止")
    }
    
    private func handleEvent(type: CGEventType, event: CGEvent) {
        if type == .leftMouseDown {
            flushTypingBuffer()
            let loc = event.location
            
            DispatchQueue.main.async {
                // [✨新增] 脏数据过滤：检查点击位置是否在自身 App 窗口内
                if let screen = NSScreen.screens.first {
                    // 坐标系转换：CGEvent (左上角原点) -> AppKit Window (左下角原点)
                    let flippedPoint = CGPoint(x: loc.x, y: screen.frame.height - loc.y)
                    
                    var isInsideOwnWindow = false
                    for window in NSApp.windows where window.isVisible {
                        if window.frame.contains(flippedPoint) {
                            isInsideOwnWindow = true
                            break
                        }
                    }
                    
                    // 如果点击落在我们自己的窗口上，直接丢弃该事件，不生成节点！
                    if isInsideOwnWindow {
                        print("🛡️ 已过滤自身窗口点击")
                        return
                    }
                }
                
                let action = RPAAction(type: .mouseOperation, parameter: "leftClick|\(Int(loc.x)), \(Int(loc.y))|0, 0|false", customName: "录制: 左键点击")
                self.onActionRecorded?(action)
            }
        } else if type == .keyDown {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if let char = keyCodeToString(keyCode: UInt16(keyCode)) { accumulateTyping(char) }
        }
    }
    
    private func accumulateTyping(_ char: String) {
        typingBuffer += char
        DispatchQueue.main.async {
            self.typingTimer?.invalidate()
            self.typingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in self?.flushTypingBuffer() }
        }
    }
    
    private func flushTypingBuffer() {
        guard !typingBuffer.isEmpty else { return }
        let text = typingBuffer; typingBuffer = ""
        DispatchQueue.main.async {
            let action = RPAAction(type: .typeText, parameter: text, customName: "录制: 键盘输入")
            self.onActionRecorded?(action)
        }
    }
    
    private func keyCodeToString(keyCode: UInt16) -> String? {
        // 简易映射字典
        let map: [UInt16: String] = [0:"a", 1:"s", 2:"d", 3:"f", 4:"h", 5:"g", 6:"z", 7:"x", 8:"c", 9:"v", 11:"b", 12:"q", 13:"w", 14:"e", 15:"r", 16:"y", 17:"t", 31:"o", 32:"u", 34:"i", 35:"p", 37:"l", 38:"j", 40:"k", 45:"n", 46:"m", 36:"[ENTER]", 49:" ", 51:"[BACKSPACE]"]
        return map[keyCode]
    }
}



//////////////////////////////////////////////////////////////////
// MARK: - ToolBar
// 工具栏式悬浮窗
//////////////////////////////////////////////////////////////////

// MARK: - 悬浮窗控制器
class ExecutionToolbarManager {
    static let shared = ExecutionToolbarManager()
    private var window: NSWindow?
    
    @MainActor
    func show(engine: WorkflowEngine) {
        if window == nil {
            let view = ExecutionToolbarView(engine: engine)
            
            // 使用非激活面板 (NonActivatingPanel)，点击时绝不抢走当前 App 的焦点
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 80),
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered,
                                defer: false)
            
            panel.isFloatingPanel = true
            panel.level = .floating // 始终置顶
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false // 阴影由 SwiftUI 内部处理，更细腻
            
            // 确保用户切换桌面空间 (Space) 时，工具栏依然如影随形
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            
            panel.contentView = NSHostingView(rootView: view)
            self.window = panel
        }
        
        // 计算坐标：定位到主屏幕右上角，预留出安全边距
        if let screenFrame = NSScreen.main?.visibleFrame, let win = window {
            let margin: CGFloat = 20
            let x = screenFrame.maxX - win.frame.width - margin
            let y = screenFrame.maxY - win.frame.height - margin
            win.setFrameOrigin(NSPoint(x: x, y: y))
            win.orderFront(nil)
        }
    }
    
    @MainActor
    func hide() {
        window?.orderOut(nil)
        window = nil // 销毁释放内存，每次重新执行生成最新视图
    }
}

// MARK: - 呼吸灯动画修饰器
struct PulseEffect: ViewModifier {
    @State private var isPulsing = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(isPulsing ? 1.2 : 0.8)
            .opacity(isPulsing ? 1.0 : 0.5)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isPulsing)
            .onAppear { isPulsing = true }
    }
}

// MARK: - 悬浮执行监控面板
struct ExecutionToolbarView: View {
    var engine: WorkflowEngine
    
    // 动态获取当前正在执行的节点名称
    var currentActionName: String {
        guard let idx = engine.currentWorkflowIndex,
              let actionId = engine.currentActionId,
              let action = engine.workflows[idx].actions.first(where: { $0.id == actionId }) else {
            return "准备调度任务..."
        }
        return action.displayTitle
    }
    
    // 动态获取最后一条日志（清洗换行符保证单行显示）
    var lastLogText: String {
        let text = engine.logs.last ?? "等待引擎输出日志..."
        return text.replacingOccurrences(of: "\n", with: " ")
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 上半部分：状态指示与操作按钮
            HStack(spacing: 12) {
                // 运行状态呼吸灯
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)
                    .modifier(PulseEffect())
                    .shadow(color: .green.opacity(0.6), radius: 3)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("LinRPA 运行中")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)
                    
                    Text(currentActionName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .frame(maxWidth: 160, alignment: .leading)
                        // 使用平滑过渡动画切换节点名
                        .animation(.easeInOut, value: currentActionName)
                }
                
                Spacer()
                
                // 恢复主界面按钮
                Button(action: restoreMainWindow) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.blue)
                        .frame(width: 26, height: 26)
                        .background(Color.blue.opacity(0.15))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("恢复显示主界面")
                
                // 紧急停止按钮
                Button(action: stopWorkflow) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.red)
                        .frame(width: 26, height: 26)
                        .background(Color.red.opacity(0.15))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("紧急停止任务 (Cmd+Opt+S)")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            
            Divider()
            
            // 下半部分：最新日志滚动显示
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                    .font(.system(size: 10))
                    .foregroundColor(.gray)
                
                Text(lastLogText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // 让日志的变更有一点灵动的淡入淡出效果
                    .animation(.easeInOut(duration: 0.2), value: lastLogText)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black.opacity(0.04))
        }
        .frame(width: 300)
        // 关键视觉：苹果原生毛玻璃效果
        .background(Material.regular)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
        )
        // 悬浮阴影，增强立体空间感
        .shadow(color: Color.black.opacity(0.15), radius: 15, x: 0, y: 8)
    }
    
    private func restoreMainWindow() {
        if let mainWindow = NSApp.windows.first(where: { $0.className.contains("AppKitWindow") }) {
            mainWindow.deminiaturize(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    
    private func stopWorkflow() {
        engine.isRunning = false
    }
}
