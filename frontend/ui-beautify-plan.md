# Frontend UI 简化美化计划（10 分钟内完成）

## 目标
- 在 `frontend/index.html` 中直接加入少量 CSS/JS，实现：
  1. 对话气泡（用户、助手）样式
  2. 输入框、发送按钮布局
  3. 暗/亮主题切换（记住偏好）
- 不重构页面结构，只在现有 `<body>` 末尾插入必要的 `<style>` 与 `<script>`，保持所有原有功能不变。

## 步骤（约 8‑10 分钟）
1. **写入计划文件**（已完成，上方 `ui-beautify-plan.md`）
2. **编辑 `frontend/index.html`**：
   - 在 `</head>` 前加入 `<style>`，定义 CSS 变量、暗/亮配色以及气泡、输入框样式。
   - 在 `</body>` 前加入 `<script>`，实现：
     - 简单的 `addMessage(type, text)` 将 `<div class="msg user|assistant">` 插入到页面末尾（我们使用现有的 `main` 区域直接渲染）
     - 发送按钮和回车触发 `addMessage('user', textarea.value)`，并自动滚动到页面底部。
     - 主题切换按钮（右上角）`#themeToggle`，点击在 `document.documentElement.dataset.theme` 中切换 `light`/`dark`，并保存到 `localStorage`。
3. **本地手动刷新验证**：打开 `frontend/index.html`，检查气泡、输入框、主题切换是否正常。
4. **提交修改**：`git add frontend/index.html && git commit -m "quick UI beautify + theme toggle" && git push`。

## 关键代码片段（会直接写入 index.html）
```html
<!-- 在 </head> 前插入 -->
<style>
:root{--bg:#ffffff;--bg-surface:#f9fafb;--text:#212529;--accent:#123b5d;--border:#d9e2e8;}
[data-theme="dark"]{--bg:#1e1e1e;--bg-surface:#2b2b2b;--text:#e0e0e0;--accent:#4a90e2;--border:#444;}
body{background:var(--bg);color:var(--text);font-family:Arial,"Microsoft YaHei",sans-serif;}
.msg{max-width:70%;margin:8px 0;padding:10px 14px;border-radius:12px;line-height:1.5;}
.msg.assistant{background:var(--bg-surface);color:var(--text);align-self:flex-start;}
.msg.user{background:var(--accent);color:#fff;align-self:flex-end;}
.chat-input{display:flex;gap:8px;padding:12px;border-top:1px solid var(--border);background:var(--bg);}
.chat-input textarea{flex:1;padding:10px;border:1px solid var(--border);border-radius:6px;resize:none;}
.chat-input button{flex:0 0 80px;background:var(--accent);color:#fff;border:none;border-radius:6px;cursor:pointer;}
#themeToggle{position:fixed;right:16px;top:16px;background:none;border:none;font-size:1.4rem;cursor:pointer;}
</style>
```
```html
<!-- 在 </body> 前插入 -->
<div id="chatContainer" style="display:flex;flex-direction:column;padding:16px;overflow-y:auto;max-height:70vh;"></div>
<div class="chat-input">
  <textarea id="msgInput" placeholder="输入消息…" rows="1"></textarea>
  <button id="sendBtn">发送</button>
</div>
<button id="themeToggle">🌙</button>
<script>
// 主题切换
(function(){
  const saved=localStorage.getItem('theme')||'light';
  document.documentElement.dataset.theme=saved;
  const btn=document.getElementById('themeToggle');
  btn.textContent=saved==='dark'?'☀️':'🌙';
  btn.onclick=()=>{const nxt=document.documentElement.dataset.theme==='dark'?'light':'dark';document.documentElement.dataset.theme=nxt;localStorage.setItem('theme',nxt);btn.textContent=nxt==='dark'?'☀️':'🌙';};
})();
// 简单聊天 UI
function addMessage(type,text){if(!text)return;const div=document.createElement('div');div.className='msg '+type;div.textContent=text;document.getElementById('chatContainer').appendChild(div);document.getElementById('chatContainer').scrollTop=document.getElementById('chatContainer').scrollHeight;}
document.getElementById('sendBtn').onclick=()=>{const txt=document.getElementById('msgInput').value.trim();addMessage('user',txt);document.getElementById('msgInput').value='';/* 这里可以调用后端接口 */};
document.getElementById('msgInput').addEventListener('keydown',e=>{if(e.key==='Enter' && !e.shiftKey){e.preventDefault();document.getElementById('sendBtn').click();}});
</script>
```

完成后请刷新页面确认 UI 已更新，如有细节需要微调再告诉我。