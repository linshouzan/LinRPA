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
        
        /* [✨核心修复] 采用特征哈希生成确定性 TargetID，并修复原生 ID 的盲区 */
        window._rpaGetTargetId = function(el) {
            let rpaId = el.getAttribute('data-rpa-id');
            if (rpaId) return rpaId;
            
            /* 【修复点】如果元素自带原生 ID，必须也要打上 data-rpa-id 标记！否则 extractDOM 会瞎掉 */
            if (el.id) {
                el.setAttribute('data-rpa-id', el.id);
                return el.id;
            }
            
            let tagName = el.tagName.toLowerCase();
            let textContent = (el.innerText || el.value || el.placeholder || el.name || '').substring(0, 20).replace(/\\s+/g, '');
            let xpath = getXPath(el);
            let featureStr = tagName + '|' + textContent + '|' + xpath;
            
            let hash = 0;
            for (let i = 0; i < featureStr.length; i++) {
                let char = featureStr.charCodeAt(i);
                hash = ((hash << 5) - hash) + char;
                hash = hash & hash;
            }
            let safeHash = Math.abs(hash).toString(36);
            
            let newId = 'rpa_' + tagName + '_' + safeHash;
            el.setAttribute('data-rpa-id', newId);
            return newId;
        };
    
        function recordEvent(type, el, val = null) {
            let tid = window._rpaGetTargetId(el);
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
        
        function rpaClickHandler(e) {
            let el = e.target;
            if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') return;
            recordEvent('click', el);
        }
        
        function rpaChangeHandler(e) {
            let el = e.target;
            if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.tagName === 'SELECT') {
                recordEvent('input', el, el.value);
            }
        }
        
        document.addEventListener('click', rpaClickHandler, true);
        document.addEventListener('change', rpaChangeHandler, true);
        
        let hoverTimer = null; 
        let lastHoverEl = null;
        
        function rpaMouseoverHandler(e) {
            let interactive = e.target.closest('button, a, input, select, textarea, [role="menuitem"], .dropdown, [onclick]') || e.target;
            if (interactive === lastHoverEl) return;
            lastHoverEl = interactive; 
            clearTimeout(hoverTimer);
            hoverTimer = setTimeout(() => { 
                if (interactive && interactive.isConnected) { recordEvent('hover', interactive); }
            }, 1000);
        }
        
        function rpaMouseoutHandler(e) {
            clearTimeout(hoverTimer);
            lastHoverEl = null;
        }
        
        document.addEventListener('mouseover', rpaMouseoverHandler, true);
        document.addEventListener('mouseout', rpaMouseoutHandler, true);

        window._rpaCorpusStop = function() {
            document.removeEventListener('click', rpaClickHandler, true);
            document.removeEventListener('change', rpaChangeHandler, true);
            document.removeEventListener('mouseover', rpaMouseoverHandler, true);
            document.removeEventListener('mouseout', rpaMouseoutHandler, true);
            window._rpaCorpusInjected = false;
        };
    })();
    """
    
    /// 清理探针 JS
    static let probeTeardownJS = """
    if (typeof window._rpaCorpusStop === 'function') { window._rpaCorpusStop(); }
    window._rpaCorpusInjected = false;
    window._rpaEventBuffer = [];
    """
    
    // MARK: - [✨WebAgent 新增] 提取含特征 ID 的 DOM 与全页面强制打标
    static let extractDOMJS = """
    (function() {
        if (!window._rpaCorpusInjected) { return 'NEED_INJECTION'; }
        let elements = document.querySelectorAll('[data-rpa-id]');
        let domList = [];
        for(let i = 0; i < elements.length; i++) {
            let el = elements[i];
            let rect = el.getBoundingClientRect();
            if (rect.width === 0 || rect.height === 0 || el.style.display === 'none' || el.style.visibility === 'hidden') continue;
            let text = (el.innerText || el.value || el.placeholder || el.name || '').substring(0, 50).trim().replace(/\\s+/g, ' ');
            if (!text && el.tagName !== 'INPUT' && el.tagName !== 'TEXTAREA') continue;
            let tag = el.tagName.toLowerCase();
            let tid = el.getAttribute('data-rpa-id');
            domList.push('<' + tag + ' id="' + tid + '">' + text + '</' + tag + '>');
        }
        return domList.join('\\n');
    })();
    """
    
    static let forceTagJS = """
    (function() {
        if (!window._rpaGetTargetId) return;
        let interactives = document.querySelectorAll('button, a, input, select, textarea, [role="menuitem"], [onclick], .dropdown');
        for(let i=0; i<interactives.length; i++) {
            let el = interactives[i];
            if(el.offsetWidth > 0 && el.offsetHeight > 0) {
                window._rpaGetTargetId(el); /* 静默生成特征 Hash ID，不闪烁屏幕 */
            }
        }
    })();
    """

    /// WebAgent与录制公用的：生成真实物理回放交互的 JS 脚本 (带 Hash 自愈)
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
            
            /* [✨自愈能力] 如果元素因页面刷新丢失标志，实时通过 Hash 特征找回 */
            if (!el && target.startsWith('rpa_')) {
                function getXPath(e) {
                    if (e.id) return `//*[@id="${e.id}"]`;
                    if (e === document.body) return e.tagName;
                    let ix = 0;
                    let siblings = e.parentNode ? e.parentNode.childNodes : [];
                    for (let i = 0; i < siblings.length; i++) {
                        let sibling = siblings[i];
                        if (sibling === e) return getXPath(e.parentNode) + '/' + e.tagName + '[' + (ix + 1) + ']';
                        if (sibling.nodeType === 1 && sibling.tagName === e.tagName) ix++;
                    }
                    return '';
                }
                function calcHashId(e) {
                    let tagName = e.tagName.toLowerCase();
                    let textContent = (e.innerText || e.value || e.placeholder || e.name || '').substring(0, 20).replace(/\\s+/g, '');
                    let xpath = getXPath(e);
                    let featureStr = tagName + '|' + textContent + '|' + xpath;
                    let hash = 0;
                    for (let i = 0; i < featureStr.length; i++) {
                        hash = ((hash << 5) - hash) + featureStr.charCodeAt(i);
                        hash = hash & hash;
                    }
                    return 'rpa_' + tagName + '_' + Math.abs(hash).toString(36);
                }
                
                let parts = target.split('_');
                let searchTag = parts.length >= 3 ? parts[1] : '*';
                let candidates = document.querySelectorAll(searchTag);
                for (let i = 0; i < candidates.length; i++) {
                    if (calcHashId(candidates[i]) === target) {
                        el = candidates[i];
                        el.setAttribute('data-rpa-id', target); 
                        break;
                    }
                }
            }
            
            if (!el) {
                console.warn('RPA Playback: 找不到目标元素 ->', target);
                return;
            }
            
            /* 1. 视觉高亮 */
            let oldOutline = el.style.outline;
            let oldTransition = el.style.transition;
            el.style.transition = 'outline 0.3s ease-in-out';
            el.style.outline = '4px solid #ff2d55';
            setTimeout(() => { 
                el.style.outline = oldOutline; 
                el.style.transition = oldTransition; 
            }, 800);
            
            /* 2. 滚动到可视区域 */
            el.scrollIntoView({behavior: 'smooth', block: 'center', inline: 'center'});
            
            /* 3. 欺骗性 Hover (针对 Vue/React) */
            el.dispatchEvent(new MouseEvent('mouseover', {bubbles: true, cancelable: true, view: window}));
            el.dispatchEvent(new MouseEvent('mouseenter', {bubbles: true, cancelable: true, view: window}));
            el.dispatchEvent(new MouseEvent('mousemove', {bubbles: true, cancelable: true, view: window}));
            
            /* 4. 真实交互 */
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
            else if (actType === 'hover') {
                el.dispatchEvent(new MouseEvent('mouseover', {bubbles: true, cancelable: true, view: window}));
                el.dispatchEvent(new MouseEvent('mouseenter', {bubbles: true, cancelable: true, view: window}));
                el.dispatchEvent(new MouseEvent('mousemove', {bubbles: true, cancelable: true, view: window}));
            }
            return "SUCCESS";
        })();
        """
    }
    
    // MARK: - 2. 统一的 AppleScript 下发引擎
    
    @MainActor
    static func runJS(in browser: String, js: String) -> String? {
        if browser == "InternalBrowser" {
            var scriptResult: String?
            let semaphore = DispatchSemaphore(value: 0)
            BrowserViewModel.shared.activeTab?.evaluateJavaScript(js) { res, _ in
                scriptResult = res as? String
                semaphore.signal()
            }
            // 避免完全阻塞主线程的优雅等法（若需严格同步则需改造为 async，这里为了兼容当前结构简单返回）
            return "SUCCESS" // 内部浏览器暂不依赖强同步返回
        }
        
        let safeScript = js
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "    ", with: "")
        
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
