//////////////////////////////////////////////////////////////////
// 文件名：WebScripts.swift
// 文件说明：Web 自动化与 RPA 探针脚本统一管理器
// 功能说明：集中管理注入探针、动作回放、环境清理等核心 JS 脚本，并提供 AppleScript 桥接。
// 代码要求：保证代码的逻辑和完整性，保留代码中的所有注释内容
//////////////////////////////////////////////////////////////////

import Foundation
import AppKit
import WebKit

struct BrowserScriptBridge {
    
    // MARK: - 1. 核心 JS 脚本库
    
    /// 语料录制 JS 探针
    static let probeInjectionJS = """
    (function() {
        if (window.console) console.log('探针JS已植入');
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
    if (window.console) console.log('清理探针 JS');
    if (typeof window._rpaCorpusStop === 'function') { window._rpaCorpusStop(); }
    window._rpaCorpusInjected = false;
    window._rpaEventBuffer = [];
    """
    
    // MARK: - [✨WebAgent 新增] 提取含特征 ID 的 DOM 与 BBox 物理坐标换算
    static let extractDOMJS = """
    (function() {
        if (window.console) console.log('提取特征DOM');
        if (!window._rpaCorpusInjected) { return 'NEED_INJECTION'; }
        let elements = document.querySelectorAll('[data-rpa-id]');
        let domList = [];
        
        /* 获取 Retina 屏幕缩放比，用于将 CSS 逻辑像素映射为截图的物理像素 */
        let dpr = window.devicePixelRatio || 1;
        /* 获取当前视口尺寸 */
        let winHeight = window.innerHeight || document.documentElement.clientHeight;
        let winWidth = window.innerWidth || document.documentElement.clientWidth;
        
        /* 估算浏览器原生 UI(标签栏/地址栏) 的高度补偿，若全屏截的是整个应用窗口，Y 轴需加上此偏移 */
        let yOffset = Math.max(0, window.outerHeight - window.innerHeight);
        
        for(let i = 0; i < elements.length; i++) {
            let el = elements[i];
            let rect = el.getBoundingClientRect();
            
            /* 剔除不可见、尺寸过小、或完全不在当前视口内的元素，防止给 LLM 造成干扰 */
            if (rect.width === 0 || rect.height === 0 || el.style.display === 'none' || el.style.visibility === 'hidden') continue;
            if (rect.bottom < 0 || rect.right < 0 || rect.top > winHeight || rect.left > winWidth) continue;
            
            let text = (el.innerText || el.value || el.placeholder || el.name || '').substring(0, 50).trim().replace(/\\s+/g, ' ');
            if (!text && el.tagName !== 'INPUT' && el.tagName !== 'TEXTAREA') continue;
            
            let tag = el.tagName.toLowerCase();
            let tid = el.getAttribute('data-rpa-id');
            let typeAttr = el.getAttribute('type') ? ` type="${el.getAttribute('type')}"` : '';
            
            /* 计算对齐物理截图的 BBox 坐标 (加入 DPR 缩放和顶部栏补偿) */
            let x = Math.round(rect.left * dpr);
            let y = Math.round((rect.top + yOffset) * dpr);
            let w = Math.round(rect.width * dpr);
            let h = Math.round(rect.height * dpr);
            let bbox = `box="[${x},${y},${w},${h}]"`;
            
            domList.push('<' + tag + ' id="' + tid + '" ' + bbox + typeAttr + '>' + text + '</' + tag + '>');
        }
        return domList.join('\\n');
    })();
    """
    
    static let forceTagJS = """
    (function() {
        if (window.console) console.log('标记targetid');
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
    
    /// WebAgent与录制公用的：生成真实物理回放交互的 JS 脚本 (带 Hash 自愈与动态红点)
    static func generatePlaybackJS(targetId: String, actionType: String, inputValue: String) -> String {
        let safeValue = inputValue.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        
        return """
        (function() {
            if (window.console) console.log('回放交互的 JS 脚本');
            var target = '\(targetId)';
            var actType = '\(actionType)';
            var val = "\(safeValue)";
            
            var el = document.querySelector(`[data-rpa-id="${target}"]`) || document.getElementById(target) || document.querySelector(target);
            
            /* 自愈能力逻辑不变... */
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
            
            /* 2. 滚动到可视区域 */
            el.scrollIntoView({behavior: 'smooth', block: 'center', inline: 'center'});
            
            /* 1. [✨修改点4.2] 视觉高亮 + 动态红色圆点扩散动画反馈 */
            let oldOutline = el.style.outline;
            let oldTransition = el.style.transition;
            el.style.transition = 'outline 0.3s ease-in-out';
            el.style.outline = '4px solid #ff2d55';
            
            let rect = el.getBoundingClientRect();
            let dot = document.createElement('div');
            dot.style.position = 'fixed';
            dot.style.left = (rect.left + rect.width / 2 - 10) + 'px';
            dot.style.top = (rect.top + rect.height / 2 - 10) + 'px';
            dot.style.width = '20px';
            dot.style.height = '20px';
            dot.style.backgroundColor = 'rgba(255, 45, 85, 0.8)';
            dot.style.borderRadius = '50%';
            dot.style.zIndex = '2147483647';
            dot.style.pointerEvents = 'none';
            dot.style.boxShadow = '0 0 10px rgba(255, 45, 85, 0.5)';
            dot.style.transition = 'transform 0.5s ease-out, opacity 0.5s ease-out';
            document.body.appendChild(dot);
        
            /* 触发动画帧 */
            requestAnimationFrame(() => {
                dot.style.transform = 'scale(4)';
                dot.style.opacity = '0';
            });
        
            setTimeout(() => { 
                el.style.outline = oldOutline; 
                el.style.transition = oldTransition; 
                if(dot.parentNode) dot.parentNode.removeChild(dot);
            }, 600);
            
            /* 3. 欺骗性 Hover */
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
    
    // 感知网页完整DOM模式执行的JS
    static let envDomJs = """
    (function() {
        if (window.console) console.log('完整DOM模式执行的JS');
        try {
            let root = document.body || document.documentElement;
            if (!root) return 'NOT_FOUND';
            
            /* 1. 等待 SPA 框架异步渲染 */
            if (document.body.children.length <= 1 && document.body.innerText.trim().length < 50) {
                return 'PAGE_LOADING';
            }
            if (document.readyState !== 'complete' && document.readyState !== 'interactive') {
                return 'PAGE_LOADING';
            }
            
            /* ======================================================= */
            /* 2. 获取目标元素，并通过探针 _rpaGetTargetId 赋予 data-rpa-id */
            /* ======================================================= */
            let index = 0;
            let interactiveTags = ['button', 'input', 'select', 'textarea', 'a'];
            
            let elements = Array.from(root.querySelectorAll('*')).filter(function(el) {
                if (!el || !el.tagName) return false;
                let tag = el.tagName.toLowerCase(); 
                let role = el.getAttribute('role') || '';
                let style;
                try { style = window.getComputedStyle(el); } catch(e) {}
                let isPointer = style ? (style.cursor === 'pointer') : false;
                
                return interactiveTags.includes(tag) || 
                       ['button', 'link', 'tab', 'menuitem'].includes(role) || 
                       el.hasAttribute('onclick') || 
                       isPointer;
            });
            
            for(let i = 0; i < elements.length; i++) {
                let el = elements[i];
                let rect = el.getBoundingClientRect(); 
                let style;
                try { style = window.getComputedStyle(el); } catch(e) {}
                
                if(rect.width > 5 && rect.height > 5 && style && style.display !== 'none' && style.visibility !== 'hidden') {
                    let rawText = el.innerText || el.value || el.getAttribute('placeholder') || el.getAttribute('aria-label') || '';
                    let cleanText = String(rawText).trim().replace(/  +/g, ' ').substring(0, 15);
                    
                    /* 过滤无文本的非输入框元素 */
                    if (cleanText === '' && !['input', 'textarea', 'select'].includes(el.tagName.toLowerCase())) {
                        continue;
                    }
                    
                    /* 调用探针的方法获取 ID 或兜底分配 */
                    if (typeof window._rpaGetTargetId === 'function') {
                        let rpaId = window._rpaGetTargetId(el);
                        if (rpaId !== undefined && rpaId !== null && rpaId !== '') {
                            el.setAttribute('data-rpa-id', String(rpaId));
                        }
                    } else {
                        el.setAttribute('data-rpa-id', index.toString());
                        index++;
                    }
                }
            }
            
            /* ======================================================= */
            /* 3. [✨极致提纯]：放弃克隆和结构解析，直接把带有 ID 的元素压平成列表 */
            /* ======================================================= */
            let targets = document.querySelectorAll('[data-rpa-id]');
            let finalHtml = "";
            
            /* 依然保留 iframe 的沙箱警告，让 AI 知道这里有个视线盲区 */
            let iframes = document.querySelectorAll('iframe');
            if (iframes.length > 0) {
                finalHtml += "<iframe data-rpa-id=\\"unknown_iframe\\">[⚠️ iframe 沙箱区域，内部 DOM 无法读取。请查阅 AXTree 获取原生坐标]</iframe>\\n";
            }
            
            for (let i = 0; i < targets.length; i++) {
                let el = targets[i];
                let tag = el.tagName.toLowerCase();
                let rpaId = el.getAttribute('data-rpa-id');
                
                /* 获取元素内容文字 */
                let rawText = el.innerText || el.value || el.getAttribute('placeholder') || el.getAttribute('aria-label') || '';
                /* 消除换行和多余空格，确保单行紧凑 */
                let cleanText = String(rawText).trim().replace(/\\r?\\n|\\r/g, ' ').replace(/  +/g, ' ');
                
                /* 组装最纯净的格式：只保留类型、ID 和 内容文字 */
                finalHtml += "<" + tag + " data-rpa-id=\\"" + rpaId + "\\">" + cleanText + "</" + tag + ">\\n";
            }
            
            /* 软截断：通常扁平化后的代码极短，但为防万一依然保留首尾截断 */
            if (finalHtml.length > 80000) {
                return finalHtml.substring(0, 40000) + '\\n\\n...[内容过长已折叠]...\\n\\n' + finalHtml.substring(finalHtml.length - 40000);
            }
            
            return finalHtml;
        } catch (err) {
            return 'ERROR: ' + err.toString();
        }
    })();
    """
    
    // MARK: - [✨究极版] 强力 Web 框架嗅探探针 (融合 React DevTools 官方机制)
    static let detectFrameworkJS = """
    (function() {
        if (window.console) console.log('Web 框架嗅探探针');
        try {
            /* =======================================================
               防线 1：主世界逃逸 (Main World Injection)
               专门对付 WKWebView、Chrome Extension 等 Bridge 沙箱隔离
            ======================================================= */
            var script = document.createElement('script');
            script.id = 'rpa-fw-detector';
            /* 这段字符串内的代码将强制在页面的真实顶级上下文中执行 */
            script.textContent = `
                (function() {
                    var fw = 'None';
                    /* 尝试突破 iframe 拿到真正的 top window */
                    var targetWin = window;
                    try { if (window.top && window.top.document) targetWin = window.top; } catch(e) {}
                    
                    if (targetWin.__REACT_DEVTOOLS_GLOBAL_HOOK__ || targetWin.__NEXT_DATA__ || targetWin.React) {
                        fw = 'React';
                    } else if (targetWin.__VUE__ || targetWin.Vue) {
                        fw = 'Vue';
                    }
                    /* 将主世界的探查结果通过 DOM 属性偷渡回隔离世界 */
                    document.documentElement.setAttribute('data-rpa-fw-result', fw);
                })();
            `;
            /* 插入 DOM 触发立即执行 */
            document.documentElement.appendChild(script);
            /* 阅后即焚，不留痕迹 */
            script.remove();
            
            /* 从共享的 DOM 中读取主世界传回的情报 */
            var fwResult = document.documentElement.getAttribute('data-rpa-fw-result');
            if (fwResult && fwResult !== 'None') {
                return fwResult;
            }
    
            /* =======================================================
               防线 2：DOM 特征兜底 (DOM 树在两个世界是绝对共享的)
            ======================================================= */
            if (document.querySelector('[data-reactroot]')) {
                return 'React';
            }
    
            var allNodes = document.querySelectorAll('*');
            var maxCheck = Math.min(allNodes.length, 2000);
            
            for (var i = 0; i < maxCheck; i++) {
                var el = allNodes[i];
                if (!el) continue;
                
                /* 注意：某些严格的沙箱连 DOM 上的 expando 属性都会抹除，
                   但如果引擎没那么严格，这个依然是最可靠的底层判断依据 */
                var keys = Object.keys(el);
                for (var j = 0; j < keys.length; j++) {
                    if (keys[j].indexOf('__reactFiber$') === 0 || 
                        keys[j].indexOf('__reactProps$') === 0 || 
                        keys[j].indexOf('__reactContainer$') === 0) {
                        return 'React';
                    }
                }
            }
            
            return 'None';
        } catch (err) {
            if (window.console) console.log('RPA 框架嗅探异常:', err);
            return 'None';
        }
    })();
    """
    
    // MARK: - [✨新增] SoM (Set-of-Mark) 视觉红框标记注入
    static let drawBBoxJS = """
    (function() {
        if (window.console) console.log('视觉红框标记注入');
        if(window._rpaBBoxDrawn) return;
        window._rpaBBoxDrawn = true;
        
        let container = document.createElement('div');
        container.id = 'rpa-bbox-container';
        /* 使用 absolute 覆盖全页面，并禁止阻挡鼠标事件 */
        container.style.cssText = 'position:absolute; top:0; left:0; width:100%; height:100%; pointer-events:none; z-index:2147483647; overflow:visible; margin:0; padding:0;';
        document.body.appendChild(container);
        
        let elements = document.querySelectorAll('[data-rpa-id]');
        for(let i=0; i<elements.length; i++) {
            let el = elements[i];
            let rect = el.getBoundingClientRect();
            
            /* 剔除不在视口内的元素 */
            let winHeight = window.innerHeight || document.documentElement.clientHeight;
            let winWidth = window.innerWidth || document.documentElement.clientWidth;
            if (rect.width === 0 || rect.height === 0) continue;
            if (rect.bottom < 0 || rect.right < 0 || rect.top > winHeight || rect.left > winWidth) continue;
            
            /* 绘制红框 */
            let box = document.createElement('div');
            box.style.cssText = 'position:absolute; border:2px solid #ff2d55; background:rgba(255, 45, 85, 0.05); box-sizing:border-box; border-radius:3px;';
            box.style.left = (rect.left + window.scrollX) + 'px';
            box.style.top = (rect.top + window.scrollY) + 'px';
            box.style.width = rect.width + 'px';
            box.style.height = rect.height + 'px';
            
            /* 绘制 ID 标签 */
            let label = document.createElement('div');
            label.innerText = el.getAttribute('data-rpa-id');
            label.style.cssText = 'position:absolute; background:#ff2d55; color:#fff; font-size:11px; font-weight:bold; padding:2px 4px; border-radius:2px; top:-16px; left:-2px; white-space:nowrap; font-family:monospace; line-height:1;';
            box.appendChild(label);
            
            container.appendChild(box);
        }
    })();
    """
    
    // MARK: - [✨新增] 清除红框标记
    static let clearBBoxJS = """
    (function() {
        let container = document.getElementById('rpa-bbox-container');
        if(container && container.parentNode) {
            container.parentNode.removeChild(container);
        }
        window._rpaBBoxDrawn = false;
    })();
    """
    
    // MARK: - [✨新增] React 专属 DOM 提取脚本 (穿透 Virtual DOM)
    static let reactEnvDomJs = """
    (function() {
        try {
            let root = document.body || document.documentElement;
            if (!root) return 'NOT_FOUND';
            if (document.readyState !== 'complete' && document.readyState !== 'interactive') return 'PAGE_LOADING';
            
            let interactiveTags = ['button', 'input', 'select', 'textarea', 'a'];
            let index = 0;
            
            /* 【核心组件】检查元素是否绑定了 React 事件 */
            function hasReactEvent(el) {
                let keys = Object.keys(el);
                let fiberKey = keys.find(k => k.startsWith('__reactFiber$'));
                if (!fiberKey) return false;
                let fiber = el[fiberKey];
                /* 递归向上追溯两层，防止事件挂载在 Wrapper 容器上 */
                let current = fiber;
                let depth = 0;
                while (current && depth < 3) {
                    if (current.memoizedProps && (typeof current.memoizedProps.onClick === 'function' || typeof current.memoizedProps.onChange === 'function')) {
                        return true;
                    }
                    current = current.return;
                    depth++;
                }
                return false;
            }
            
            let elements = Array.from(root.querySelectorAll('*')).filter(function(el) {
                if (!el || !el.tagName) return false;
                let tag = el.tagName.toLowerCase(); 
                let role = el.getAttribute('role') || '';
                let style;
                try { style = window.getComputedStyle(el); } catch(e) {}
                let isPointer = style ? (style.cursor === 'pointer') : false;
                
                return interactiveTags.includes(tag) || 
                       ['button', 'link', 'tab', 'menuitem'].includes(role) || 
                       isPointer || 
                       hasReactEvent(el); /* 捕获 React 隐藏事件 */
            });
            
            for(let i = 0; i < elements.length; i++) {
                let el = elements[i];
                let rect = el.getBoundingClientRect(); 
                let style;
                try { style = window.getComputedStyle(el); } catch(e) {}
                
                if(rect.width > 5 && rect.height > 5 && style && style.display !== 'none' && style.visibility !== 'hidden') {
                    let rawText = el.innerText || el.value || el.getAttribute('placeholder') || el.getAttribute('aria-label') || '';
                    let cleanText = String(rawText).trim().replace(/  +/g, ' ').substring(0, 15);
                    if (cleanText === '' && !['input', 'textarea', 'select'].includes(el.tagName.toLowerCase())) continue;
                    
                    if (typeof window._rpaGetTargetId === 'function') {
                        let rpaId = window._rpaGetTargetId(el);
                        if (rpaId) el.setAttribute('data-rpa-id', String(rpaId));
                    } else {
                        el.setAttribute('data-rpa-id', 'react_' + index.toString());
                        index++;
                    }
                }
            }
            
            let targets = document.querySelectorAll('[data-rpa-id]');
            let finalHtml = "";
            for (let i = 0; i < targets.length; i++) {
                let el = targets[i];
                let tag = el.tagName.toLowerCase();
                let rpaId = el.getAttribute('data-rpa-id');
                let rawText = el.innerText || el.value || el.getAttribute('placeholder') || el.getAttribute('aria-label') || '';
                let cleanText = String(rawText).trim().replace(/\\r?\\n|\\r/g, ' ').replace(/  +/g, ' ');
                finalHtml += "<" + tag + " data-rpa-id=\\"" + rpaId + "\\">" + cleanText + "</" + tag + ">\\n";
            }
            
            if (finalHtml.length > 80000) return finalHtml.substring(0, 40000) + '\\n...[内容过长已折叠]...\\n' + finalHtml.substring(finalHtml.length - 40000);
            return finalHtml;
        } catch (err) {
            return 'ERROR: ' + err.toString();
        }
    })();
    """
    
    // 打开网页
    static func openUrlJS(safeUrl: String) -> String {
        return """
        (function() {
            let urlStr = '\(safeUrl)';
            if (urlStr.startsWith('http://') || urlStr.startsWith('https://')) {
                window.location.href = urlStr;
            } else {
                /* 相对地址自动附加上当前页面的 host */
                let absolute = new URL(urlStr, window.location.origin).href;
                window.location.href = absolute;
            }
            return "SUCCESS_OPEN_URL";
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
            return "SUCCESS"
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
    
    // MARK: - [✨终极进化] 零依赖、破沙箱的异步 Web JS 控制引擎
    static func runJSAsync(in browser: String, js: String, timeout: Double, context: WorkflowEngine?) async -> String? {
        // 生成此次任务的唯一执行 ID
        let taskId = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        
        // 【极致破壁 1】：废弃 eval，采用纯原生上下文环境。
        // 通过 .call(window) 将沙箱作用域强制绑定到网页最顶层，让你能肆无忌惮地访问任何全局对象。
        let coreJS = """
        window._rpa_async_tasks = window._rpa_async_tasks || {};
        window._rpa_async_tasks['\(taskId)'] = 'PENDING';
        
        (async function() {
            try {
                let userFunc = async function() {
                    \(js)
                };
                // 绑定 window 上下文执行
                let res = await userFunc.call(window);
                
                let safeResult = "";
                if (res === undefined || res === null) {
                    safeResult = String(res);
                } else if (typeof res === 'object') {
                    try {
                        safeResult = JSON.stringify(res);
                    } catch(e) {
                        // 循环引用降级序列化 (完美处理 Document/Window/DOM 对象)
                        if (res.nodeType) {
                            safeResult = '[DOM Node: ' + (res.tagName || res.nodeName).toUpperCase() + ']';
                            if (res.id) safeResult += ' id="' + res.id + '"';
                            if (res.className && typeof res.className === 'string') safeResult += ' class="' + res.className + '"';
                        } else if (res === window) {
                            safeResult = '[Window Object]';
                        } else if (res === document) {
                            safeResult = '[Document Object]';
                        } else {
                            safeResult = Object.prototype.toString.call(res);
                        }
                    }
                } else {
                    safeResult = String(res);
                }
                window._rpa_async_tasks['\(taskId)'] = 'SUCCESS:' + safeResult;
            } catch(e) {
                window._rpa_async_tasks['\(taskId)'] = 'ERROR:' + (e.message || String(e));
            }
        }).call(window);
        """
        
        let pollJS = """
        (function() {
            let state = window._rpa_async_tasks['\(taskId)'];
            if (state && state !== 'PENDING') {
                delete window._rpa_async_tasks['\(taskId)'];
                return state;
            }
            return 'PENDING';
        })();
        """
        
        let cleanupJS = "delete window._rpa_async_tasks['\(taskId)'];"
        
        // =========================================================
        // 场景一：内置开发者浏览器 (WKWebView) - [✨究极终点破壁版]
        // =========================================================
        if browser == "InternalBrowser" {
            // 生成唯一任务 ID
            let taskId = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            
            let executionResult: String = await Task { @MainActor in
                
                guard let tab = BrowserViewModel.shared.activeTab else {
                    return "ERROR: 找不到内置浏览器实例"
                }
                
                // 🚀 1. 核心注入逻辑 (免疫 CSP + 阻断 Promise 报错)
                let coreJS = """
                window._rpa_async_tasks = window._rpa_async_tasks || {};
                window._rpa_async_tasks['\(taskId)'] = 'PENDING';
                
                (async function() {
                    try {
                        let userFunc = async function() {
                            \(js)
                        };
                        let res = await userFunc.call(window);
                        
                        let safeResult = "";
                        if (res === undefined) safeResult = "RPA_RESULT:[undefined / 空值]";
                        else if (res === null) safeResult = "RPA_RESULT:[null]";
                        else if (typeof res === 'object') {
                            if (res.nodeType) safeResult = 'RPA_RESULT:[DOM Node: ' + (res.tagName || res.nodeName).toUpperCase() + ']';
                            else if (res === window) safeResult = 'RPA_RESULT:[Window Object]';
                            else if (res === document) safeResult = 'RPA_RESULT:[Document Object]';
                            else {
                                try { safeResult = 'RPA_RESULT:' + JSON.stringify(res); }
                                catch(e) { safeResult = 'RPA_RESULT:' + Object.prototype.toString.call(res); }
                            }
                        } else {
                            safeResult = "RPA_RESULT:" + String(res);
                        }
                        window._rpa_async_tasks['\(taskId)'] = 'SUCCESS:' + safeResult;
                    } catch(e) {
                        window._rpa_async_tasks['\(taskId)'] = 'ERROR:' + (e.message || String(e));
                    }
                })();
                
                'INJECTED'; // 👈 究极防御：强制让 evaluateJavaScript 返回普通字符串，彻底阻断 unsupported type 崩溃！
                """
                
                let pollJS = """
                (function() {
                    if (!window._rpa_async_tasks) return 'PENDING';
                    let state = window._rpa_async_tasks['\(taskId)'];
                    if (state && state !== 'PENDING') {
                        delete window._rpa_async_tasks['\(taskId)'];
                        return state;
                    }
                    return 'PENDING';
                })();
                """
                
                do {
                    // 2. 发射注入 (此时返回的是 'INJECTED'，完美绕过 Swift 类型检查)
                    _ = try await tab.webView.evaluateJavaScript(coreJS)
                    
                    // 3. 高频安全轮询结果 (每 100ms 抓取一次)
                    let startTime = Date()
                    while Date().timeIntervalSince(startTime) < timeout {
                        if context?.isRunning == false { return "ERROR: Workflow Terminated" }
                        
                        let pollValue = try await tab.webView.evaluateJavaScript(pollJS)
                        let state = pollValue as? String ?? "PENDING"
                        
                        if state != "PENDING" {
                            if state.hasPrefix("SUCCESS:") {
                                let actualData = String(state.dropFirst(8))
                                if actualData.hasPrefix("RPA_RESULT:") {
                                    let finalData = String(actualData.dropFirst(11))
                                    return finalData.isEmpty ? "[空字符串]" : finalData
                                }
                                return actualData
                            }
                            if state.hasPrefix("ERROR:") { return state }
                        }
                        
                        // 挂起协程，防止霸占主线程
                        try await Task.sleep(nanoseconds: 100_000_000)
                    }
                    
                    // 4. 超时强制清理内存痕迹
                    _ = try? await tab.webView.evaluateJavaScript("delete window._rpa_async_tasks['\(taskId)'];")
                    return "TIMEOUT: 执行超过 \(timeout) 秒未返回。"
                    
                } catch {
                    return "ERROR: 引擎执行异常 -> \(error.localizedDescription)"
                }
            }.value
            
            return executionResult
        }
        
        // =========================================================
        // 场景二：外部浏览器 (Safari/Chrome/Edge)
        // =========================================================
        // 【极致破壁 2】：彻底抛弃 Base64 和 atob()，使用无损字符串转义直连底层的自动化通道。
        // AppleScript 编译器处理多行字符串能力极强，只需精准转义反斜杠和双引号。
        func escapeForAppleScript(_ string: String) -> String {
            return string
                .replacingOccurrences(of: "\\", with: "\\\\") // 先转义反斜杠
                .replacingOccurrences(of: "\"", with: "\\\"") // 再转义双引号
        }
        
        let safeCoreJS = escapeForAppleScript(coreJS)
        let safePollJS = escapeForAppleScript(pollJS)
        let safeCleanupJS = escapeForAppleScript(cleanupJS)
        
        func buildAppleScript(for browserName: String, execute script: String) -> String {
            if browserName == "Safari" {
                return "tell application \"Safari\"\n if not (exists document 1) then return \"NOT_FOUND\"\n do JavaScript \"\(script)\" in front document\n end tell"
            } else {
                return "tell application \"\(browserName)\"\n if (count of windows) = 0 then return \"NOT_FOUND\"\n tell active tab of front window\n execute javascript \"\(script)\"\n end tell\n end tell"
            }
        }
        
        let injectAppleScript = buildAppleScript(for: browser, execute: safeCoreJS)
        let pollAppleScript = buildAppleScript(for: browser, execute: safePollJS)
        let cleanupAppleScript = buildAppleScript(for: browser, execute: safeCleanupJS)
        
        // 执行 AppleScript 的辅助闭包
        let runOSA = { (script: String) -> String? in
            var errorInfo: NSDictionary?
            if let scriptObj = NSAppleScript(source: script) {
                let output = scriptObj.executeAndReturnError(&errorInfo)
                if let err = errorInfo { return "ERROR: \(err["NSAppleScriptErrorMessage"] ?? "Unknown Error")" }
                return output.stringValue
            }
            return nil
        }
        
        // 1. 发射注入 (此时浏览器接收到的是最纯粹的明文 JS，不再受 CSP eval 阻拦)
        let injectResult = runOSA(injectAppleScript)
        if injectResult == "NOT_FOUND" || injectResult?.hasPrefix("ERROR") == true {
            return injectResult
        }
        
        // 2. 后台轮询
        let startTime = Date()
        while Date().timeIntervalSince(startTime) < timeout {
            if context?.isRunning == false { return "ERROR: Workflow Terminated" }
            
            let pollState = runOSA(pollAppleScript)
            
            if let state = pollState, state != "PENDING" {
                if state.hasPrefix("SUCCESS:") { return String(state.dropFirst(8)) }
                if state.hasPrefix("ERROR:") { return state }
                if state == "NOT_FOUND" { return "ERROR: 浏览器窗口已关闭" }
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        
        // 3. 超时强制清理
        _ = runOSA(cleanupAppleScript)
        return "TIMEOUT: 执行超过 \(timeout) 秒未返回。"
    }
}

