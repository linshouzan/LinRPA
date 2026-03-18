//////////////////////////////////////////////////////////////////
// 文件名：WebScripts.swift
// 文件说明：Web 自动化与 RPA 探针脚本统一管理器
// 功能说明：集中管理注入探针、动作回放、环境清理等核心 JS 脚本，并提供 AppleScript 桥接。
// 代码要求：请保证代码的逻辑和完整性，保留代码中的所有注释内容
//////////////////////////////////////////////////////////////////

import Foundation
import AppKit

struct BrowserScriptBridge {
    
    // MARK: - 1. 核心 JS 脚本库
    
    /// 语料录制 JS 探针
    static let probeInjectionJS = """
    (function() {
        if (window._rpaCorpusInjected) return;
        window._rpaCorpusInjected = true;
        window._rpaEventBuffer = [];
        
        function flashElement(el, textMark) {
            if (!el) return;
            let oldOutline = el.style.outline;
            let oldTransition = el.style.transition;
            el.style.transition = 'outline 0.3s ease-in-out';
            el.style.outline = '3px solid #ff2d55';
            
            let badge = document.createElement('div');
            badge.innerText = 'RPA 捕获: ' + textMark;
            badge.style.cssText = 'position:absolute; background:#ff2d55; color:#fff; font-size:10px; padding:2px 4px; border-radius:3px; z-index:999999; pointer-events:none;';
            let rect = el.getBoundingClientRect();
            badge.style.top = (rect.top + window.scrollY - 15) + 'px';
            badge.style.left = (rect.left + window.scrollX) + 'px';
            document.body.appendChild(badge);
            
            setTimeout(() => { 
                el.style.outline = oldOutline; 
                el.style.transition = oldTransition; 
                if(badge.parentNode) badge.parentNode.removeChild(badge);
            }, 600);
        }
        
        function getXPath(el) {
            if (el.id) return `//*[@id="${el.id}"]`;
            if (el === document.body) return el.tagName;
            let ix = 0;
            let siblings = el.parentNode ? el.parentNode.childNodes : [];
            for (let i = 0; i < siblings.length; i++) {
                let sibling = siblings[i];
                if (sibling === el) return getXPath(el.parentNode) + '/' + el.tagName + '[' + (ix + 1) + ']';
                if (sibling.nodeType === 1 && sibling.tagName === el.tagName) ix++;
            }
            return '';
        }
        
        function getTargetId(el) {
            if (el.id) return el.id;
            let rpaId = el.getAttribute('data-rpa-id');
            if (rpaId) return rpaId;
            let newId = 'rpa_' + Math.random().toString(36).substr(2, 6);
            el.setAttribute('data-rpa-id', newId);
            return newId;
        }

        function recordEvent(type, el, val = null) {
            let tid = getTargetId(el);
            let text = (el.innerText || el.value || el.placeholder || el.name || tid).substring(0, 30).trim();
            flashElement(el, text);
            window._rpaEventBuffer.push({
                event: type,
                target_id: tid,
                element_text: text,
                input_value: val,
                xpath: getXPath(el),
                dom_summary: document.body.innerText.substring(0, 500)
            });
        }
        
        document.addEventListener('click', function(e) {
            let el = e.target;
            if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') return;
            recordEvent('click', el);
        }, true);
        
        document.addEventListener('change', function(e) {
            let el = e.target;
            if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.tagName === 'SELECT') {
                recordEvent('input', el, el.value);
            }
        }, true);
    })();
    """
    
    /// 清理探针 JS
    static let probeTeardownJS = """
    if (window._rpaCorpusStop) { window._rpaCorpusStop(); }
    window._rpaCorpusInjected = false;
    window._rpaEventBuffer = [];
    """
    
    /// [✨WebAgent与录制公用的] 生成真实物理回放交互的 JS 脚本
    static func generatePlaybackJS(targetId: String, actionType: String, inputValue: String) -> String {
        let safeValue = inputValue.replacingOccurrences(of: "\\", with: "\\\\")
                                  .replacingOccurrences(of: "\"", with: "\\\"")
                                  .replacingOccurrences(of: "\n", with: "\\n")
        
        return """
        (function() {
            var target = '\(targetId)';
            var actType = '\(actionType)';
            var val = "\(safeValue)";
            
            var el = document.querySelector(`[data-rpa-id="${target}"]`) || document.getElementById(target) || document.querySelector(target);
            if (!el) {
                console.warn('RPA Playback: 找不到目标元素 ->', target);
                return;
            }
            
            // 1. 视觉高亮
            let oldOutline = el.style.outline;
            let oldTransition = el.style.transition;
            el.style.transition = 'outline 0.3s ease-in-out';
            el.style.outline = '4px solid #ff2d55';
            setTimeout(() => { 
                el.style.outline = oldOutline; 
                el.style.transition = oldTransition; 
            }, 800);
            
            // 2. 滚动到可视区域
            el.scrollIntoView({behavior: 'smooth', block: 'center', inline: 'center'});
            
            // 3. 欺骗性 Hover (针对 Vue/React)
            el.dispatchEvent(new MouseEvent('mouseover', {bubbles: true, cancelable: true, view: window}));
            el.dispatchEvent(new MouseEvent('mouseenter', {bubbles: true, cancelable: true, view: window}));
            el.dispatchEvent(new MouseEvent('mousemove', {bubbles: true, cancelable: true, view: window}));
            
            // 4. 真实交互
            if (actType === 'click' || actType === 'mousedown') {
                el.dispatchEvent(new MouseEvent('mousedown', {bubbles: true, cancelable: true, view: window}));
                el.dispatchEvent(new MouseEvent('mouseup', {bubbles: true, cancelable: true, view: window}));
                el.click();
            } 
            else if (actType === 'input') {
                el.focus();
                let nativeInputValueSetter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value')?.set;
                let nativeTextAreaValueSetter = Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value')?.set;
                if (nativeInputValueSetter && el.tagName.toLowerCase() === 'input') { nativeInputValueSetter.call(el, val); } 
                else if (nativeTextAreaValueSetter && el.tagName.toLowerCase() === 'textarea') { nativeTextAreaValueSetter.call(el, val); } 
                else { el.value = val; }
                el.dispatchEvent(new Event('input', { bubbles: true }));
                el.dispatchEvent(new Event('change', { bubbles: true }));
            }
        })();
        """
    }
    
    // MARK: - 2. 统一的 AppleScript 下发引擎
    
    @MainActor
    static func runJS(in browser: String, js: String) -> String? {
        // 压缩脚本防止多行解析错误
        let safeScript = js.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "    ", with: "")
        
        let appleScript: String
        if browser == "Safari" {
            appleScript = "tell application \"Safari\"\n if not (exists document 1) then return \"NOT_FOUND\"\n do JavaScript \"\(safeScript)\" in front document\n end tell"
        } else {
            appleScript = "tell application \"Google Chrome\"\n if (count of windows) = 0 then return \"NOT_FOUND\"\n tell active tab of front window\n execute javascript \"\(safeScript)\"\n end tell\n end tell"
        }
        
        var errorInfo: NSDictionary?
        if let scriptObj = NSAppleScript(source: appleScript) {
            let output = scriptObj.executeAndReturnError(&errorInfo)
            if let err = errorInfo {
                print("🍎 AppleScript 执行错误: \(err)")
                return nil
            }
            return output.stringValue
        }
        return nil
    }
}
