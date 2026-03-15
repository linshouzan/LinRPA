//////////////////////////////////////////////////////////////////
// 文件名：MacroRecorder.swift
// 文件说明：这是适用于 macos 14+ 的RPA录制功能管理器
// 功能说明：
// 代码要求：没有要求修改不用输出代码，请保证代码的逻辑和完整性，保留代码中的所有注释内容
//////////////////////////////////////////////////////////////////

import Foundation
import AppKit
import CoreGraphics

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
