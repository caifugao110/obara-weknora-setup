/* ============================================================
 * OBARA 知识问答平台 — 前端逻辑
 * 依赖 WeKnora REST API，通过 portal/server.py 代理转发
 * ============================================================ */

// ---------- 全局状态 ----------
const STATE = {
  token: localStorage.getItem('obara_token') || '',
  user: null,
  tenants: [],
  currentTenantId: localStorage.getItem('obara_tenant') || '',
  currentPage: 'chat',
  currentAgentId: '',
  currentSessionId: '',
  chatHistory: [],    // [{role, content, citations}]
  streaming: false,
  canCreateTenant: false,
};

const API_BASE = '/api/v1';

// 平台统一品牌名称
const BRAND = 'OBARA 知识库问答平台';

// ---------- 工具函数 ----------
function toast(msg, type = 'info') {
  const t = document.getElementById('toast');
  t.textContent = msg;
  t.className = `toast ${type}`;
  setTimeout(() => t.classList.add('hidden'), 3000);
}

function authHeaders(extra = {}) {
  const h = { 'Content-Type': 'application/json', ...extra };
  if (STATE.token) h['Authorization'] = `Bearer ${STATE.token}`;
  if (STATE.currentTenantId) h['X-Tenant-ID'] = STATE.currentTenantId;
  return h;
}

async function api(method, path, body = null, opts = {}) {
  const init = { method, headers: authHeaders(opts.headers || {}) };
  if (body && !(body instanceof FormData)) init.body = JSON.stringify(body);
  else if (body) init.body = body;
  const resp = await fetch(API_BASE + path, init);
  const text = await resp.text();
  let data;
  try { data = text ? JSON.parse(text) : {}; } catch { data = { raw: text }; }
  if (!resp.ok) {
    // 后端错误体：{"error":{"message":"..."}} 或 {"message":"..."}
    const e = data && data.error;
    const msg = (e && (e.message || e.details)) || (data && data.message) || `HTTP ${resp.status}`;
    throw new Error(msg);
  }
  return data;
}

// 流式请求（SSE）
// 注意：后端部分错误（如智能体未配置对话模型）不会写入 SSE 流，只会返回 200 + 空流，
// 因此这里对响应体中的 error / response_type=error 做识别，及时报错而不是一直等待。
async function apiStream(method, path, body, onChunk, onDone, onError) {
  const resp = await fetch(API_BASE + path, {
    method,
    headers: authHeaders({ Accept: 'text/event-stream' }),
    body: JSON.stringify(body),
  });
  if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
  const reader = resp.body.getReader();
  const decoder = new TextDecoder();
  let buffer = '';
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });
    const lines = buffer.split('\n');
    buffer = lines.pop();
    for (const line of lines) {
      const l = line.trim();
      if (!l || !l.startsWith('data:')) continue;
      const payload = l.slice(5).trim();
      if (payload === '[DONE]') { onDone && onDone(); return; }
      let obj = null;
      try {
        obj = JSON.parse(payload);
      } catch { continue; }   // 忽略非 JSON 行
      if (obj && (obj.response_type === 'error' || obj.error)) {
        const e = new Error(obj.error || obj.message || '后端处理失败');
        if (onError) { onError(e); return; }
        throw e;
      }
      onChunk && onChunk(obj);
    }
  }
  onDone && onDone();
}

function escapeHtml(s) {
  const div = document.createElement('div');
  div.textContent = s;
  return div.innerHTML;
}

// 页脚版权年份：随当前时间自动更新
(function initFooterYear() {
  const year = new Date().getFullYear();
  document.querySelectorAll('.footer-year').forEach(el => { el.textContent = year; });
})();

// ---------- 角色与权限 ----------
// 部门内的管理类功能（人员 / 智能体 / 文档）仅对下列角色开放，
// 默认只有文档管理员 Owner 可用；如需放开其它角色，在此集合追加即可。
const MANAGE_ROLES = ['owner'];
const MANAGE_PAGES = ['members', 'agents', 'documents'];
const ROLE_TEXT = { owner: '文档管理员', admin: '管理员', contributor: '普通成员', viewer: '只读成员' };

function roleText(role) { return ROLE_TEXT[role] || role || '未知角色'; }

function getRoleBadge(role) {
  const map = { owner: 'badge-owner', admin: 'badge-admin', contributor: 'badge-contributor', viewer: 'badge-viewer' };
  const cls = map[role] || 'badge-viewer';
  return `<span class="badge ${cls}">${roleText(role)}</span>`;
}

// 当前用户在「当前部门」中的成员身份
function currentMembership() {
  const list = (STATE.user && STATE.user.memberships) || [];
  return list.find(m => String(m.tenant_id) === String(STATE.currentTenantId)) || null;
}
function currentRole() { return (currentMembership() || {}).role || ''; }

// 系统管理员：可跨工作空间管理（后端对 X-Tenant-ID 切换授予临时 Admin）
function isSystemAdmin() {
  const u = (STATE.user && STATE.user.user) || {};
  return !!(u.is_system_admin || u.can_access_all_tenants);
}
function isDeptManager() { return isSystemAdmin() || MANAGE_ROLES.includes(currentRole()); }
function canAccessPage(page) { return !MANAGE_PAGES.includes(page) || isDeptManager(); }

// 按当前部门内的角色刷新界面可见性
function applyPermissionUI() {
  const manage = isDeptManager();
  document.querySelectorAll('.nav-item').forEach(n => {
    if (MANAGE_PAGES.includes(n.dataset.page)) n.classList.toggle('hidden', !manage);
  });
  const group = document.getElementById('nav-group-admin');
  if (group) group.classList.toggle('hidden', !manage);
  ['btn-invite-member', 'btn-create-agent', 'btn-create-kb'].forEach(id => {
    const el = document.getElementById(id);
    if (el) el.classList.toggle('hidden', !manage);
  });
  const chip = document.getElementById('user-role');
  if (chip) {
    const role = currentRole();
    const sys = isSystemAdmin();
    chip.textContent = sys ? '系统管理员' : (role ? roleText(role) : '未加入部门');
    chip.className = `role-chip ${sys ? 'role-chip-admin' : `role-chip-${role || 'none'}`}`;
  }
}

// ---------- 认证 ----------
document.getElementById('login-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const email = document.getElementById('login-email').value.trim();
  const password = document.getElementById('login-password').value;
  try {
    const resp = await api('POST', '/auth/login', { email, password });
    STATE.token = resp.token || (resp.data && resp.data.token);
    if (!STATE.token) throw new Error('登录响应无 token');
    localStorage.setItem('obara_token', STATE.token);
    await initApp();
    toast('登录成功', 'success');
  } catch (err) {
    toast('登录失败：' + err.message, 'error');
  }
});

async function logout() {
  if (!confirm('确定退出登录？')) return;
  localStorage.removeItem('obara_token');
  localStorage.removeItem('obara_tenant');
  STATE.token = '';
  STATE.user = null;
  showLoginOnly();
}

function showLoginOnly() {
  document.getElementById('app').classList.add('hidden');
  document.getElementById('register-page').classList.add('hidden');
  document.getElementById('login-page').classList.remove('hidden');
}

// ---------- 邀请注册（/register?token=...） ----------
const INVITE_TOKEN = new URLSearchParams(location.search).get('token') || '';

function showRegisterPage() {
  document.getElementById('login-page').classList.add('hidden');
  document.getElementById('app').classList.add('hidden');
  document.getElementById('register-page').classList.remove('hidden');
}

async function initRegisterPage() {
  showRegisterPage();
  if (!INVITE_TOKEN) {
    document.getElementById('register-subtitle').textContent = '邀请链接缺少 token，请联系部门文档管理员重新获取。';
    document.getElementById('register-form').classList.add('hidden');
    return;
  }
  try {
    // token 一律走 POST body，避免落入访问日志
    const resp = await api('POST', '/auth/invitations/lookup', { token: INVITE_TOKEN });
    const d = resp.data || {};
    document.getElementById('register-subtitle').innerHTML =
      `你将加入 <strong>${escapeHtml(d.tenant_name || ('空间 ' + d.tenant_id))}</strong>，角色：<strong>${roleText(d.role)}</strong>`;
  } catch (err) {
    document.getElementById('register-subtitle').textContent = '邀请链接无效或已过期：' + err.message;
    document.getElementById('register-form').classList.add('hidden');
  }
}

document.getElementById('register-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const username = document.getElementById('register-username').value.trim();
  const email = document.getElementById('register-email').value.trim();
  const password = document.getElementById('register-password').value;
  try {
    if (STATE.token) {
      // 已登录用户：直接接受邀请
      await api('POST', '/me/invitations/accept-by-token', { token: INVITE_TOKEN });
    } else {
      const resp = await api('POST', '/auth/register-by-invite', { token: INVITE_TOKEN, username, email, password });
      const t = resp.token || (resp.data && resp.data.token);
      if (!t) throw new Error('注册响应无 token，请直接登录');
      STATE.token = t;
      localStorage.setItem('obara_token', t);
    }
    location.href = '/';
  } catch (err) {
    toast('加入失败：' + err.message, 'error');
  }
});

// ---------- 初始化 ----------
async function initApp() {
  if (!STATE.token) {
    document.getElementById('app').classList.add('hidden');
    document.getElementById('login-page').classList.remove('hidden');
    return;
  }
  try {
    const me = await api('GET', '/auth/me');
    STATE.user = me.data || me;
  } catch (err) {
    logout();
    return;
  }
  document.getElementById('login-page').classList.add('hidden');
  document.getElementById('app').classList.remove('hidden');
  document.getElementById('user-name').textContent = STATE.user.name || STATE.user.username || STATE.user.email || '用户';
  document.getElementById('user-avatar').textContent = (STATE.user.username || STATE.user.email || 'U').charAt(0).toUpperCase();
  await loadTenants();
  showPage(STATE.currentPage);
}

// ---------- 工作空间切换 ----------
// GET /tenants 只返回用户归属的单个空间；可切换的空间列表来自 /auth/me 的 memberships。
async function loadTenants() {
  try {
    const me = await api('GET', '/auth/me');
    const d = me.data || me;
    STATE.user = d;
    STATE.canCreateTenant = !!(d.capabilities && d.capabilities.can_create_tenant);
    document.getElementById('btn-create-tenant').classList.toggle('hidden', !STATE.canCreateTenant);

    STATE.tenants = (d.memberships || []).map(m => ({
      id: String(m.tenant_id),
      name: m.tenant_name || `空间 ${m.tenant_id}`,
      role: m.role,
    }));
    // 系统管理员：补全全部部门，便于跨部门切换管理（后端按 X-Tenant-ID 授予临时 Admin）
    if (isSystemAdmin()) {
      try {
        const all = await api('GET', '/tenants/all?page=1&page_size=200');
        const items = (all.data || {}).items || all.data || [];
        const seen = new Set(STATE.tenants.map(t => t.id));
        for (const t of items) {
          const id = String(t.id);
          if (seen.has(id)) continue;
          seen.add(id);
          STATE.tenants.push({ id, name: t.name || `空间 ${id}`, role: '' });
        }
      } catch { /* 无权限时忽略，仅保留已加入部门 */ }
    }
    const sel = document.getElementById('tenant-select');
    sel.innerHTML = '';
    if (STATE.tenants.length === 0) {
      sel.innerHTML = '<option value="">暂无工作空间</option>';
      applyPermissionUI();
      return;
    }
    for (const t of STATE.tenants) {
      const opt = document.createElement('option');
      opt.value = t.id;
      opt.textContent = t.name + (t.role ? `（${roleText(t.role)}）` : '');
      sel.appendChild(opt);
    }
    // 选择上次的或第一个
    if (STATE.currentTenantId && STATE.tenants.some(t => t.id === String(STATE.currentTenantId))) {
      sel.value = STATE.currentTenantId;
    } else {
      STATE.currentTenantId = STATE.tenants[0].id;
      sel.value = STATE.currentTenantId;
      localStorage.setItem('obara_tenant', STATE.currentTenantId);
    }
    await onTenantChanged();
  } catch (err) {
    toast('加载工作空间失败：' + err.message, 'error');
  }
}

async function switchTenant(id) {
  STATE.currentTenantId = id;
  localStorage.setItem('obara_tenant', id);
  await onTenantChanged();
  showPage(STATE.currentPage);
}

async function onTenantChanged() {
  const t = STATE.tenants.find(x => x.id === String(STATE.currentTenantId));
  document.getElementById('members-dept-name').textContent = t ? t.name : '未选择部门';
  const ag = document.getElementById('agents-dept-name');
  if (ag) ag.textContent = t ? t.name : '未选择部门';
  // 角色随部门变化，先刷新管理类入口的可见性
  applyPermissionUI();
  STATE.currentAgentId = '';
  STATE.currentSessionId = '';
  STATE.chatHistory = [];
  resetChatHeader();
  renderChatMessages();
}

// ---------- 页面切换 ----------
function showPage(name) {
  // 越权保护：管理类页面仅部门文档管理员可用
  if (!canAccessPage(name)) {
    toast('仅本部门文档管理员（Owner）可使用「人员 / 智能体 / 文档管理」', 'warning');
    name = 'chat';
  }
  STATE.currentPage = name;
  document.querySelectorAll('.page').forEach(p => p.classList.remove('active'));
  document.getElementById('page-' + name).classList.add('active');
  document.querySelectorAll('.nav-item').forEach(n => {
    n.classList.toggle('active', n.dataset.page === name);
  });
  // 侧边栏折叠时关闭
  if (window.innerWidth <= 768) document.getElementById('sidebar').classList.add('collapsed');
  // 加载对应页面数据
  if (name === 'chat') loadAgentsForChat();
  else if (name === 'departments') loadDepartments();
  else if (name === 'members') loadMembers();
  else if (name === 'agents') loadAgents();
  else if (name === 'documents') loadKbs();
}

function toggleSidebar() {
  document.getElementById('sidebar').classList.toggle('collapsed');
}

// ---------- 问答页 ----------
// 欢迎页推荐问题（点击后自动填入输入框并发送）
const SUGGESTIONS = [
  '这份文档的核心结论是什么？',
  '帮我总结本部门最新的作业标准',
  '这个流程的责任人与完成时限是什么？',
  '有哪些常见问题及对应处理方式？',
];

async function loadAgentsForChat() {
  const list = document.getElementById('agent-list');
  list.innerHTML = '<div class="empty-tip">加载中...</div>';
  try {
    const resp = await api('GET', '/agents');
    const agents = (resp.data || []).map(a => ({ ...a, sharedFrom: '' }));
    // 组织共享给本空间的智能体走另一个接口：/organizations → /organizations/{id}/shared-agents。
    // 只调 /agents 是拿不到的，部门空间因此"加入了共享空间却看不到共享智能体"。
    try {
      const orgResp = await api('GET', '/organizations');
      const orgs = (orgResp.data || {}).organizations || [];
      for (const org of orgs) {
        const r = await api('GET', `/organizations/${org.id}/shared-agents`);
        for (const item of r.data || []) {
          const a = item.agent || item;
          if (!a.id || agents.some(x => x.id === a.id)) continue;
          agents.push({ ...a, sharedFrom: org.name || '共享空间' });
        }
      }
    } catch { /* 未加入任何组织或接口不可用时忽略 */ }

    if (agents.length === 0) {
      list.innerHTML = '<div class="empty-tip">暂无可用智能体<span class="empty-tip-sub">请联系本部门文档管理员创建</span></div>';
      return;
    }
    list.innerHTML = agents.map(a => {
      const desc = (a.description || '暂无描述') + (a.sharedFrom ? `（来自：${a.sharedFrom}）` : '');
      return `
      <div class="agent-item ${a.id === STATE.currentAgentId ? 'active' : ''}" data-id="${a.id}"
           data-name="${escapeHtml(a.name)}" data-desc="${escapeHtml(desc)}" onclick="selectAgent('${a.id}')">
        <div class="agent-item-icon">${escapeHtml((a.name || '智').trim().charAt(0))}</div>
        <div class="agent-item-body">
          <div class="agent-item-name">${escapeHtml(a.name)}${a.sharedFrom ? ' <span class="badge badge-active">共享</span>' : ''}</div>
          <div class="agent-item-desc">${escapeHtml(desc)}</div>
        </div>
      </div>`;
    }).join('');
  } catch (err) {
    list.innerHTML = `<div class="empty-tip">加载失败：${err.message}</div>`;
  }
}

// ---------- 会话头部与快捷提问 ----------
function userInitial() {
  const u = STATE.user || {};
  const n = (u.username || u.name || u.email || '我').trim();
  return n.charAt(0).toUpperCase();
}

function setChatHeader(name, sub) {
  const n = document.getElementById('chat-agent-name');
  const s = document.getElementById('chat-agent-sub');
  const avatar = document.getElementById('chat-agent-avatar');
  if (n) n.textContent = name || '未选择智能体';
  if (s) s.textContent = sub || (name ? '基于本部门知识库作答' : '请从左侧选择一个智能体开始问答');
  if (avatar) avatar.textContent = (name || '智').trim().charAt(0).toUpperCase();
}

function resetChatHeader() { setChatHeader('', ''); }

function selectAgent(id) {
  STATE.currentAgentId = id;
  STATE.currentSessionId = '';   // 换智能体即开启新会话
  const active = document.querySelector(`.agent-item[data-id="${id}"]`);
  document.querySelectorAll('.agent-item').forEach(i => i.classList.toggle('active', i === active));
  setChatHeader(active ? active.dataset.name : '', active ? active.dataset.desc : '');
  STATE.chatHistory = [];
  renderChatMessages();
}

function resetChat() {
  STATE.currentSessionId = '';
  STATE.chatHistory = [];
  renderChatMessages();
  toast('已开启新会话', 'success');
}

function askSuggestion(text) {
  const input = document.getElementById('chat-input');
  if (!input) return;
  input.value = text;
  input.focus();
  if (STATE.currentAgentId) sendMessage();
}

function renderCitations(citations) {
  const list = (citations || []).map(c => (typeof c === 'string' ? c : (c.file_name || c.title || c.source || ''))).filter(Boolean);
  if (!list.length) return '';
  return `<div class="msg-citations"><span class="cite-label">引用来源</span>${
    list.map(c => `<span class="cite-chip" title="${escapeHtml(c)}">${escapeHtml(c)}</span>`).join('')
  }</div>`;
}

function renderChatMessages() {
  const box = document.getElementById('chat-messages');
  if (STATE.chatHistory.length === 0) {
    const hasAgent = !!STATE.currentAgentId;
    box.innerHTML = `<div class="chat-welcome">
      <div class="welcome-mark">💡</div>
      <h2 class="welcome-title">向部门知识库提问</h2>
      <p class="welcome-desc">${
        hasAgent
          ? '回答仅基于本部门已入库文档生成，并附带引用来源便于核对。'
          : '请先在左侧选择一个智能体，回答将基于其绑定的知识库生成。'
      }</p>
      <div class="suggest-grid">
        ${SUGGESTIONS.map(s => `<button class="suggest-card" onclick="askSuggestion('${escapeHtml(s).replace(/'/g, "\\'")}')">${escapeHtml(s)}</button>`).join('')}
      </div>
    </div>`;
    return;
  }
  box.innerHTML = STATE.chatHistory.map((m, i) => {
    if (m.role === 'user') {
      return `<div class="msg msg-user">
        <div class="msg-avatar msg-avatar-user">${escapeHtml(userInitial())}</div>
        <div class="msg-body"><div class="msg-bubble">${escapeHtml(m.content)}</div></div>
      </div>`;
    }
    const failed = String(m.content || '').startsWith('⚠️');
    return `<div class="msg msg-bot${failed ? ' msg-error' : ''}">
      <div class="msg-avatar msg-avatar-bot">AI</div>
      <div class="msg-body">
        <div class="msg-bubble" id="msg-${i}">${escapeHtml(m.content)}</div>
        ${renderCitations(m.citations)}
      </div>
    </div>`;
  }).join('');
  box.scrollTop = box.scrollHeight;
}

async function sendMessage() {
  const input = document.getElementById('chat-input');
  const sendBtn = document.getElementById('btn-send');
  const text = input.value.trim();
  if (!text) return;
  if (!STATE.currentAgentId) { toast('请先选择智能体', 'warning'); return; }
  if (STATE.streaming) return;

  STATE.chatHistory.push({ role: 'user', content: text });
  input.value = '';
  input.style.height = 'auto';
  STATE.streaming = true;
  if (sendBtn) sendBtn.disabled = true;
  renderChatMessages();

  // 添加机器人占位
  const botIdx = STATE.chatHistory.length;
  STATE.chatHistory.push({ role: 'assistant', content: '' });
  renderChatMessages();
  showTyping(botIdx);

  try {
    // 问答接口挂在会话下：POST /sessions 建会话 → POST /knowledge-chat/{session_id}
    if (!STATE.currentSessionId) {
      const sess = await api('POST', '/sessions', { title: text.slice(0, 30) || '新会话' });
      STATE.currentSessionId = (sess.data || {}).id;
      if (!STATE.currentSessionId) throw new Error('创建会话失败');
    }
    await apiStream('POST', `/knowledge-chat/${STATE.currentSessionId}`, {
      query: text,
      agent_id: STATE.currentAgentId,
      agent_enabled: true,
    }, (chunk) => {
      // 解析流式片段：兼容多种字段
      const delta = chunk.content || chunk.delta || chunk.answer || (chunk.data && (chunk.data.content || chunk.data.answer)) || '';
      if (delta) {
        STATE.chatHistory[botIdx].content += delta;
        const el = document.getElementById(`msg-${botIdx}`);
        if (el) el.textContent = STATE.chatHistory[botIdx].content;
        const box = document.getElementById('chat-messages');
        box.scrollTop = box.scrollHeight;
      }
      if (chunk.citations) STATE.chatHistory[botIdx].citations = chunk.citations;
    }, () => {
      finishStream(sendBtn);
      if (!STATE.chatHistory[botIdx].content) {
        STATE.chatHistory[botIdx].content = '未收到回答内容，请检查该智能体是否已绑定对话模型。';
      }
      renderChatMessages();
    }, (err) => { throw err; });
  } catch (err) {
    finishStream(sendBtn);
    STATE.chatHistory[botIdx].content = '⚠️ 回答失败：' + err.message;
    renderChatMessages();
  }
}

function finishStream(sendBtn) {
  STATE.streaming = false;
  const btn = sendBtn || document.getElementById('btn-send');
  if (btn) btn.disabled = false;
}

function showTyping(idx) {
  const el = document.getElementById(`msg-${idx}`);
  if (el) el.innerHTML = '<span class="typing"><span></span><span></span><span></span></span>';
}

// 回车发送
document.getElementById('chat-input').addEventListener('keydown', (e) => {
  if (e.key === 'Enter' && !e.shiftKey) {
    e.preventDefault();
    sendMessage();
  }
  // 自适应高度
  setTimeout(() => {
    e.target.style.height = 'auto';
    e.target.style.height = Math.min(e.target.scrollHeight, 120) + 'px';
  }, 0);
});

// ---------- 部门管理 ----------
async function loadDepartments() {
  const box = document.getElementById('tenant-table');
  box.innerHTML = '加载中...';
  try {
    // 工作空间目录：超管可看全量（/tenants/all），普通成员只看自己加入的部门。
    let tenants = STATE.tenants;
    try {
      const resp = await api('GET', '/tenants/all?page=1&page_size=200');
      const items = (resp.data || {}).items || resp.data || [];
      if (Array.isArray(items) && items.length) {
        tenants = items.map(t => ({ id: String(t.id), name: t.name, role: t.role }));
      }
    } catch { /* 非超管时回退到自己的空间列表 */ }
    if (!tenants.length) {
      box.innerHTML = '<div class="empty-tip">暂无部门</div>';
      return;
    }
    box.innerHTML = `<table>
      <thead><tr><th>部门名称</th><th>ID</th><th>我的角色</th><th>操作</th></tr></thead>
      <tbody>
        ${tenants.map(t => `<tr>
          <td><strong>${escapeHtml(t.name)}</strong></td>
          <td class="muted">${t.id}</td>
          <td>${t.role ? getRoleBadge(t.role) : '<span class="muted">-</span>'}</td>
          <td class="row-actions">
            <button class="btn btn-sm btn-secondary" onclick="enterTenant('${t.id}')">进入</button>
          </td>
        </tr>`).join('')}
      </tbody>
    </table>`;
  } catch (err) {
    box.innerHTML = `<div class="empty-tip">加载失败：${err.message}</div>`;
  }
}

function enterTenant(id) {
  switchTenant(id);
  showPage('chat');
}

function showCreateTenantModal() {
  openModal('新建部门', `
    <div class="form-group">
      <label>部门名称</label>
      <input id="new-tenant-name" placeholder="如：NJG-技术开发三部" />
    </div>
    <div class="form-group">
      <label>描述（可选）</label>
      <textarea id="new-tenant-desc" placeholder="部门工作空间描述"></textarea>
    </div>
  `, async () => {
    const name = document.getElementById('new-tenant-name').value.trim();
    const desc = document.getElementById('new-tenant-desc').value.trim();
    if (!name) { toast('请输入部门名称', 'warning'); return false; }
    try {
      await api('POST', '/tenants', { name, description: desc });
      toast('部门创建成功', 'success');
      closeModal();
      await loadTenants();
      await loadDepartments();
    } catch (err) {
      toast('创建失败：' + err.message, 'error');
      return false;
    }
  });
}

// ---------- 人员管理 ----------
async function loadMembers() {
  const mb = document.getElementById('member-table');
  const ib = document.getElementById('invitation-table');
  mb.innerHTML = '加载中...';
  ib.innerHTML = '加载中...';
  if (!STATE.currentTenantId) { mb.innerHTML = '<div class="empty-tip">请先选择部门</div>'; ib.innerHTML = '<div class="empty-tip">请先选择部门</div>'; return; }
  try {
    const [mResp, iResp] = await Promise.all([
      api('GET', `/tenants/${STATE.currentTenantId}/members?page=1&page_size=100`),
      api('GET', `/tenants/${STATE.currentTenantId}/invitations?page=1&page_size=100`).catch(() => ({ data: {} })),
    ]);
    const members = (mResp.data || {}).members || [];
    // 邀请列表里既有「指定邮箱」的邀请，也有「共享链接」邀请（is_share_link=true）
    const invites = (iResp.data || {}).invitations || [];
    cachedInvites = invites;
    mb.innerHTML = members.length === 0 ? '<div class="empty-tip">暂无成员</div>' : `<table>
      <thead><tr><th>姓名</th><th>邮箱</th><th>角色</th><th>操作</th></tr></thead>
      <tbody>
        ${members.map(m => `<tr>
          <td>${escapeHtml(m.username || m.name || '-')}</td>
          <td>${escapeHtml(m.email || '')}</td>
          <td>${getRoleBadge(m.role)}</td>
          <td class="row-actions">
            <button class="btn btn-sm btn-secondary" onclick="changeMemberRole('${m.user_id}','${m.role}')">改角色</button>
            ${m.role !== 'owner' ? `<button class="btn btn-sm btn-ghost" onclick="removeMember('${m.user_id}')">移除</button>` : ''}
          </td>
        </tr>`).join('')}
      </tbody>
    </table>`;
    ib.innerHTML = invites.length === 0 ? '<div class="empty-tip">暂无待处理邀请</div>' : `<table>
      <thead><tr><th>类型</th><th>对象</th><th>角色</th><th>状态</th><th>操作</th></tr></thead>
      <tbody>
        ${invites.map(inv => `<tr>
          <td>${inv.is_share_link ? '<span class="badge badge-active">共享链接</span>' : '<span class="badge badge-contributor">指定邮箱</span>'}</td>
          <td>${escapeHtml(inv.invitee_email || inv.email || '（任何人可点击链接加入）')}</td>
          <td>${getRoleBadge(inv.role)}</td>
          <td><span class="badge badge-pending">${inv.status || 'pending'}</span></td>
          <td class="row-actions">
            ${inv.invite_url ? `<button class="btn btn-sm btn-secondary" onclick="copyInviteUrl('${inv.id}')">复制链接</button>` : ''}
            <button class="btn btn-sm btn-ghost" onclick="revokeInvite('${inv.id}')">撤销</button>
          </td>
        </tr>`).join('')}
      </tbody>
    </table>`;
  } catch (err) {
    mb.innerHTML = `<div class="empty-tip">加载失败：${err.message}</div>`;
    ib.innerHTML = `<div class="empty-tip">加载失败：${err.message}</div>`;
  }
}

const ROLE_OPTIONS = `
  <option value="contributor">普通成员（Contributor）</option>
  <option value="viewer">只读成员（Viewer）</option>
  <option value="admin">管理员（Admin）</option>
  <option value="owner">文档管理员（Owner）</option>`;

async function changeMemberRole(userId, currentRole) {
  openModal('修改成员角色', `
    <div class="form-group">
      <label>新角色</label>
      <select id="member-role">${ROLE_OPTIONS}</select>
    </div>
  `, async () => {
    const role = document.getElementById('member-role').value;
    try {
      await api('PUT', `/tenants/${STATE.currentTenantId}/members/${userId}`, { role });
      toast('角色已更新', 'success');
      closeModal();
      loadMembers();
    } catch (err) { toast('修改失败：' + err.message, 'error'); return false; }
  });
  document.getElementById('member-role').value = currentRole;
}

let cachedInvites = [];
async function copyInviteUrl(id) {
  const inv = cachedInvites.find(x => String(x.id) === String(id));
  const url = inv && inv.invite_url;
  if (!url) { toast('该邀请没有链接', 'warning'); return; }
  try {
    await navigator.clipboard.writeText(url);
    toast('邀请链接已复制到剪贴板', 'success');
  } catch {
    prompt('请手动复制邀请链接：', url);
  }
}

function showInviteModal() {
  openModal('邀请成员', `
    <div class="form-group">
      <label>邀请方式</label>
      <select id="invite-mode" onchange="document.getElementById('invite-email-row').classList.toggle('hidden', this.value!=='email')">
        <option value="link">生成共享邀请链接（推荐，对方自助注册加入）</option>
        <option value="email">按邮箱邀请已注册账号 / 直接加入</option>
      </select>
    </div>
    <div class="form-group hidden" id="invite-email-row">
      <label>邮箱</label>
      <input id="invite-email" placeholder="成员邮箱" />
      <p class="form-hint">该邮箱必须已注册 WeKnora 账号；未注册请改用共享链接</p>
    </div>
    <div class="form-group">
      <label>角色</label>
      <select id="invite-role">${ROLE_OPTIONS}</select>
    </div>
  `, async () => {
    const role = document.getElementById('invite-role').value;
    const mode = document.getElementById('invite-mode').value;
    if (mode === 'link') {
      try {
        const resp = await api('POST', `/tenants/${STATE.currentTenantId}/invite-links`, { role });
        const url = (resp.data || {}).invite_url;
        closeModal();
        if (url) {
          openModal('邀请链接已生成', `
            <div class="form-group">
              <label>把下面的链接发给要加入的成员（7 天内有效）</label>
              <textarea id="invite-url-box" rows="4">${escapeHtml(url)}</textarea>
            </div>`, () => { closeModal(); loadMembers(); });
          setTimeout(() => {
            const box = document.getElementById('invite-url-box');
            if (box) { box.focus(); box.select(); }
          }, 50);
        } else {
          toast('链接已生成', 'success');
          loadMembers();
        }
      } catch (err) { toast('生成失败：' + err.message, 'error'); return false; }
      return;
    }
    const email = document.getElementById('invite-email').value.trim();
    if (!email) { toast('请输入邮箱', 'warning'); return false; }
    const emails = email.split(/[,，\s]+/).filter(Boolean);
    let ok = 0, fail = 0, lastErr = '';
    for (const e of emails) {
      try {
        // 指定邮箱邀请要求对方已注册；未注册时回退为「直接加入」同样需要账号，
        // 因此统一走 /members 直接加入，已注册即可立即生效。
        await api('POST', `/tenants/${STATE.currentTenantId}/members`, { email: e, role });
        ok++;
      } catch (err) { fail++; lastErr = err.message; }
    }
    toast(`处理完成：成功 ${ok}，失败 ${fail}${fail ? '（' + lastErr + '）' : ''}`, ok ? 'success' : 'error');
    closeModal();
    loadMembers();
  });
}

async function removeMember(userId) {
  if (!confirm('确定移除该成员？')) return;
  try {
    await api('DELETE', `/tenants/${STATE.currentTenantId}/members/${userId}`);
    toast('已移除', 'success');
    loadMembers();
  } catch (err) { toast('移除失败：' + err.message, 'error'); }
}

async function revokeInvite(id) {
  if (!confirm('确定撤销该邀请？')) return;
  try {
    await api('DELETE', `/tenants/${STATE.currentTenantId}/invitations/${id}`);
    toast('已撤销', 'success');
    loadMembers();
  } catch (err) { toast('撤销失败：' + err.message, 'error'); }
}

// ---------- 智能体管理 ----------
async function loadAgents() {
  const box = document.getElementById('agent-table');
  box.innerHTML = '加载中...';
  try {
    const [aResp, kbResp] = await Promise.all([
      api('GET', '/agents'),
      api('GET', '/knowledge-bases').catch(() => ({ data: [] })),
    ]);
    const agents = aResp.data || [];
    const kbs = kbResp.data || [];
    if (agents.length === 0) {
      box.innerHTML = '<div class="empty-tip">暂无智能体</div>';
      return;
    }
    box.innerHTML = `<table>
      <thead><tr><th>名称</th><th>描述</th><th>绑定知识库</th><th>操作</th></tr></thead>
      <tbody>
        ${agents.map(a => {
          const kbIds = a.config?.knowledge_bases || [];
          const kbNames = kbIds.map(id => kbs.find(k => k.id === id)?.name || id).join('、') || '-';
          return `<tr>
            <td><strong>${escapeHtml(a.name)}</strong></td>
            <td>${escapeHtml(a.description || '')}</td>
            <td>${escapeHtml(kbNames)}</td>
            <td class="row-actions">
              <button class="btn btn-sm btn-secondary" onclick="editAgent('${a.id}')">编辑</button>
              ${a.is_builtin ? '' : `<button class="btn btn-sm btn-secondary" onclick="showAgentAssignModal('${a.id}','${escapeHtml(a.name).replace(/'/g, "\\'")}')">分配到部门</button>`}
              <button class="btn btn-sm btn-danger" onclick="deleteAgent('${a.id}')">删除</button>
            </td>
          </tr>`;
        }).join('')}
      </tbody>
    </table>`;
  } catch (err) {
    box.innerHTML = `<div class="empty-tip">加载失败：${err.message}</div>`;
  }
}

let cachedKbs = [];
async function getKbOptions() {
  try {
    const resp = await api('GET', '/knowledge-bases');
    cachedKbs = resp.data || [];
  } catch { cachedKbs = []; }
  return cachedKbs;
}

let cachedModels = [];
async function getModelOptions() {
  try {
    const resp = await api('GET', '/models');
    cachedModels = resp.data || [];
  } catch { cachedModels = []; }
  return cachedModels;
}

function showAgentModal(agent = null) {
  Promise.all([getKbOptions(), getModelOptions()]).then(([kbs, models]) => {
    const kbOptions = kbs.map(k => `<option value="${k.id}">${escapeHtml(k.name)}</option>`).join('');
    const cfg = agent?.config || {};
    const chatModels = models.filter(m => m.type === 'KnowledgeQA');
    const rerankModels = models.filter(m => m.type === 'Rerank');
    const modelOptions = opts => `<option value="">（不指定）</option>` +
      opts.map(m => `<option value="${m.id}">${escapeHtml(m.display_name || m.name)}</option>`).join('');
    openModal(agent ? '编辑智能体' : '新建智能体', `
      <div class="form-group">
        <label>智能体名称</label>
        <input id="agent-name" value="${escapeHtml(agent?.name || '')}" placeholder="如：部门文档问答助手" />
      </div>
      <div class="form-group">
        <label>描述</label>
        <input id="agent-desc" value="${escapeHtml(agent?.description || '')}" placeholder="智能体用途说明" />
      </div>
      <div class="form-group">
        <label>绑定知识库</label>
        <select id="agent-kbs" multiple size="4">
          ${kbOptions}
        </select>
        <p class="form-hint">按住 Ctrl/Cmd 多选；不选则检索本空间全部知识库</p>
      </div>
      <div class="form-group">
        <label>对话模型 <span class="muted">（必选，否则无法回答）</span></label>
        <select id="agent-model">${modelOptions(chatModels)}</select>
        ${chatModels.length ? '' : '<p class="form-hint">本空间还没有对话模型，请联系平台管理员在「模型管理」中注册</p>'}
      </div>
      <div class="form-group">
        <label>重排序模型（可选）</label>
        <select id="agent-rerank">${modelOptions(rerankModels)}</select>
      </div>
      <div class="form-group">
        <label>答复约束提示词（可选）</label>
        <textarea id="agent-prompt" placeholder="如：只基于知识库内容回答，不知道则回复「未找到相关信息」">${escapeHtml(cfg.system_prompt || '')}</textarea>
      </div>
    `, async () => {
      const name = document.getElementById('agent-name').value.trim();
      if (!name) { toast('请输入名称', 'warning'); return false; }
      const desc = document.getElementById('agent-desc').value.trim();
      const kbSelect = document.getElementById('agent-kbs');
      const kbIds = Array.from(kbSelect.selectedOptions).map(o => o.value);
      const prompt = document.getElementById('agent-prompt').value;
      const modelId = document.getElementById('agent-model').value;
      const rerankId = document.getElementById('agent-rerank').value;
      const payload = {
        name, description: desc,
        config: {
          ...cfg,
          agent_mode: cfg.agent_mode || 'quick-answer',
          system_prompt: prompt,
          kb_selection_mode: kbIds.length ? 'selected' : 'all',
          knowledge_bases: kbIds,
          model_id: modelId,
          rerank_model_id: rerankId,
        },
      };
      try {
        if (agent) {
          await api('PUT', `/agents/${agent.id}`, payload);
          toast('已更新', 'success');
        } else {
          await api('POST', '/agents', payload);
          toast('已创建', 'success');
        }
        closeModal();
        loadAgents();
      } catch (err) { toast('保存失败：' + err.message, 'error'); return false; }
    });

    // 回填已保存的配置
    document.getElementById('agent-model').value = cfg.model_id || (agent ? '' : (chatModels[0] ? chatModels[0].id : ''));
    document.getElementById('agent-rerank').value = cfg.rerank_model_id || '';
    const kbSel = document.getElementById('agent-kbs');
    for (const o of kbSel.options) o.selected = (cfg.knowledge_bases || []).includes(o.value);
  });
}

function editAgent(id) {
  api('GET', '/agents').then(resp => {
    const a = (resp.data || []).find(x => x.id === id);
    if (a) showAgentModal(a);
  });
}

async function deleteAgent(id) {
  if (!confirm('确定删除该智能体？')) return;
  try {
    await api('DELETE', `/agents/${id}`);
    toast('已删除', 'success');
    loadAgents();
  } catch (err) { toast('删除失败：' + err.message, 'error'); }
}

// ---------- 跨部门分配（超管） ----------
// 智能体天然属于某个部门；跨部门「分配」通过「共享组织」实现：
//   1) 把智能体所属部门加入共享组织（成员角色 editor/admin）
//   2) 把智能体分享到该组织（POST /agents/{id}/shares）
// 于是组织内的其它部门成员即可在问答页看到并使用该智能体。
let shareCtx = { agentId: '', agentName: '', orgs: [], shares: [], members: [], view: 'orgs', orgId: '', orgName: '' };

async function showAgentAssignModal(agentId, agentName) {
  shareCtx = { agentId, agentName, orgs: [], shares: [], members: [], view: 'orgs', orgId: '', orgName: '' };
  document.getElementById('modal-title').textContent = `分配「${agentName}」到部门`;
  document.getElementById('modal-body').innerHTML = '<div class="empty-tip">加载中...</div>';
  document.getElementById('modal-confirm').classList.add('hidden');
  document.getElementById('modal-overlay').classList.remove('hidden');
  try {
    await reloadShareCtx();
  } catch (err) { toast('加载共享组织失败：' + err.message, 'error'); }
  renderAssignBody();
}

async function reloadShareCtx() {
  const [orgResp, shareResp] = await Promise.all([
    api('GET', '/organizations').catch(() => ({ data: {} })),
    api('GET', `/agents/${shareCtx.agentId}/shares`).catch(() => ({ data: {} })),
  ]);
  shareCtx.orgs = (orgResp.data || {}).organizations || [];
  const s = shareResp.data || {};
  shareCtx.shares = Array.isArray(s) ? s : (s.shares || []);
}

function renderAssignBody() {
  const body = document.getElementById('modal-body');
  if (shareCtx.view === 'members') { renderOrgMembersBody(body); return; }

  const t = STATE.tenants.find(x => x.id === String(STATE.currentTenantId));
  const sharedIds = new Set(shareCtx.shares.map(s => String(s.organization_id)));
  body.innerHTML = `
    <div class="scope-note">
      <span class="scope-note-icon">🏢</span>
      <span>智能体归属部门：<strong>${escapeHtml(t ? t.name : '未知')}</strong>。分配后，所选共享组织内的所有部门成员都能在问答页面看到并使用它。</span>
    </div>

    <h4 class="subtle-title">已分配到（${shareCtx.shares.length}）</h4>
    ${shareCtx.shares.length === 0
      ? '<div class="empty-tip">尚未分配到任何共享组织</div>'
      : shareCtx.shares.map(s => `
        <div class="share-row">
          <div>
            <div class="share-row-name">${escapeHtml(s.organization_name || s.organization_id)}</div>
            <div class="share-row-sub">权限：${escapeHtml(s.permission || '-')}　·　由本部门分享</div>
          </div>
          <button class="btn btn-sm btn-ghost" onclick="unshareAgent('${s.id}')">取消分配</button>
        </div>`).join('')}

    <h4 class="subtle-title">选择共享组织</h4>
    ${shareCtx.orgs.length === 0
      ? '<div class="empty-tip">暂无共享组织，请在下方新建</div>'
      : `<div class="org-picker">${shareCtx.orgs.map(o => `
        <label class="org-item">
          <input type="checkbox" class="org-check" value="${o.id}" ${sharedIds.has(String(o.id)) ? 'checked' : ''} />
          <div class="org-item-body">
            <div class="org-item-name">${escapeHtml(o.name)}</div>
            <div class="org-item-desc">${escapeHtml(o.description || '无描述')} · 已共享智能体 ${o.agent_share_count ?? 0} 个</div>
          </div>
          <button class="btn btn-sm btn-ghost" onclick="event.preventDefault();openOrgMembers('${o.id}','${escapeHtml(o.name).replace(/'/g, "\\'")}')">管理部门</button>
        </label>`).join('')}</div>`}

    <h4 class="subtle-title">新建共享组织</h4>
    <div class="inline-form">
      <input id="new-org-name" placeholder="组织名称，如：全公司共享 / 技术标准共享" />
      <select id="share-permission">
        <option value="editor">编辑者（可共享）</option>
        <option value="admin">管理员</option>
        <option value="viewer">查看者</option>
      </select>
      <button class="btn btn-secondary btn-sm" onclick="createAndShareOrg()">新建并分配</button>
    </div>

    <div class="modal-actions-bar">
      <button class="btn btn-ghost btn-sm" onclick="closeModal()">完成</button>
      <button class="btn btn-primary btn-sm" onclick="applyAgentShares()">保存到所选组织</button>
    </div>
  `;
}

function permValue() {
  const el = document.getElementById('share-permission');
  return el ? el.value : 'editor';
}

async function applyAgentShares() {
  const checked = Array.from(document.querySelectorAll('.org-check:checked')).map(i => i.value);
  if (!checked.length) { toast('请至少勾选一个共享组织', 'warning'); return; }
  let ok = 0;
  for (const orgId of checked) {
    try {
      // 本部门需先成为该组织成员（editor/admin），否则后端拒绝共享
      await ensureOrgMember(orgId, STATE.currentTenantId, 'editor');
      await api('POST', `/agents/${shareCtx.agentId}/shares`, { organization_id: orgId, permission: permValue() });
      ok++;
    } catch (err) {
      toast('分配失败：' + err.message, 'error');
    }
  }
  if (ok) toast(`已分配到 ${ok} 个共享组织`, 'success');
  await reloadShareCtx();
  renderAssignBody();
}

async function createAndShareOrg() {
  const el = document.getElementById('new-org-name');
  const name = el ? el.value.trim() : '';
  if (!name) { toast('请输入共享组织名称', 'warning'); return; }
  try {
    const org = await api('POST', '/organizations', {
      name,
      description: '由 OBARA 知识库问答平台门户创建，用于跨部门分配智能体',
    });
    const orgId = (org.data || {}).id;
    if (!orgId) throw new Error('创建组织未返回 ID');
    await api('POST', `/agents/${shareCtx.agentId}/shares`, { organization_id: orgId, permission: permValue() });
    toast('已新建共享组织并完成分配', 'success');
    await reloadShareCtx();
    renderAssignBody();
  } catch (err) {
    toast('创建失败：' + err.message, 'error');
  }
}

async function unshareAgent(shareId) {
  try {
    await api('DELETE', `/agents/${shareCtx.agentId}/shares/${shareId}`);
    toast('已取消分配', 'success');
    await reloadShareCtx();
    renderAssignBody();
  } catch (err) { toast('取消失败：' + err.message, 'error'); }
}

// 若指定部门还不是组织成员，则以给定角色加入（否则无法共享智能体）
async function ensureOrgMember(orgId, tenantId, role) {
  try {
    const list = await fetchOrgMembers(orgId);
    if (list.some(m => String(m.tenant_id) === String(tenantId))) return;
  } catch { /* 读取失败时仍尝试加入 */ }
  await api('POST', `/organizations/${orgId}/invite`, { tenant_id: Number(tenantId), role });
}

async function fetchOrgMembers(orgId) {
  const resp = await api('GET', `/organizations/${orgId}/members`);
  const d = resp.data || {};
  return Array.isArray(d) ? d : (d.members || []);
}

async function openOrgMembers(orgId, orgName) {
  shareCtx.view = 'members';
  shareCtx.orgId = orgId;
  shareCtx.orgName = orgName;
  document.getElementById('modal-body').innerHTML = '<div class="empty-tip">加载中...</div>';
  try {
    shareCtx.members = await fetchOrgMembers(orgId);
  } catch (err) {
    toast('加载成员失败：' + err.message, 'error');
    shareCtx.members = [];
  }
  renderAssignBody();
}

function backToOrgList() { shareCtx.view = 'orgs'; renderAssignBody(); }

function renderOrgMembersBody(body) {
  const members = shareCtx.members || [];
  const curId = String(STATE.currentTenantId);
  const joined = new Set(members.map(m => String(m.tenant_id)));
  const options = STATE.tenants.filter(x => !joined.has(String(x.id)))
    .map(x => `<option value="${x.id}">${escapeHtml(x.name)}</option>`).join('');
  body.innerHTML = `
    <button class="btn btn-ghost btn-sm" onclick="backToOrgList()">← 返回分配列表</button>
    <h4 class="subtle-title">组织成员（${members.length}）</h4>
    <p class="form-hint">「${escapeHtml(shareCtx.orgName)}」内的部门才能使用分配到该组织的智能体。</p>
    ${members.length === 0
      ? '<div class="empty-tip">暂无成员部门</div>'
      : members.map(m => `
        <div class="member-row">
          <div>
            <div class="member-row-name">${escapeHtml(m.tenant_name || ('空间 ' + m.tenant_id))}${String(m.tenant_id) === curId ? '（本部门）' : ''}</div>
            <div class="member-row-sub">组织角色：${escapeHtml(m.role || '-')}</div>
          </div>
          ${String(m.tenant_id) === curId
            ? '<span class="badge badge-contributor">当前部门</span>'
            : `<button class="btn btn-sm btn-ghost" onclick="removeOrgMember('${m.tenant_id}')">移除</button>`}
        </div>`).join('')}

    <h4 class="subtle-title">添加部门成员</h4>
    ${options
      ? `<div class="inline-form">
          <select id="org-member-dept">${options}</select>
          <select id="org-member-role">
            <option value="editor">编辑者（可共享智能体）</option>
            <option value="admin">管理员</option>
            <option value="viewer">查看者</option>
          </select>
          <button class="btn btn-secondary btn-sm" onclick="addOrgMember()">添加</button>
        </div>`
      : '<div class="empty-tip">当前可见部门均已加入该组织</div>'}
  `;
}

async function addOrgMember() {
  const tenantId = document.getElementById('org-member-dept').value;
  const role = document.getElementById('org-member-role').value;
  try {
    await api('POST', `/organizations/${shareCtx.orgId}/invite`, { tenant_id: Number(tenantId), role });
    toast('已添加部门成员', 'success');
    shareCtx.members = await fetchOrgMembers(shareCtx.orgId);
    renderAssignBody();
  } catch (err) { toast('添加失败：' + err.message, 'error'); }
}

async function removeOrgMember(tenantId) {
  try {
    await api('DELETE', `/organizations/${shareCtx.orgId}/members/${tenantId}`);
    toast('已移除部门成员', 'success');
    shareCtx.members = await fetchOrgMembers(shareCtx.orgId);
    renderAssignBody();
  } catch (err) { toast('移除失败：' + err.message, 'error'); }
}

// ---------- 文档管理 ----------
async function loadKbs() {
  const box = document.getElementById('kb-table');
  box.innerHTML = '加载中...';
  try {
    const resp = await api('GET', '/knowledge-bases');
    const kbs = (resp.data || []).map(k => ({ ...k, sharedFrom: '' }));
    // 组织共享给本空间的知识库走另一个接口：/organizations → /organizations/{id}/shared-knowledge-bases。
    // /knowledge-bases 只返回本空间自建的库，部门空间因此"加入了共享空间却看不到共享库"。
    try {
      const orgResp = await api('GET', '/organizations');
      for (const org of (orgResp.data || {}).organizations || []) {
        const r = await api('GET', `/organizations/${org.id}/shared-knowledge-bases`);
        for (const item of r.data || []) {
          const k = item.knowledge_base || item;
          if (!k.id || kbs.some(x => x.id === k.id)) continue;
          kbs.push({ ...k, sharedFrom: org.name || '共享空间' });
        }
      }
    } catch { /* 未加入任何组织或接口不可用时忽略 */ }

    if (kbs.length === 0) {
      box.innerHTML = '<div class="empty-tip">暂无知识库，请点击右上角新建</div>';
      return;
    }
    box.innerHTML = `<table>
      <thead><tr><th>知识库名称</th><th>描述</th><th>文档数</th><th>操作</th></tr></thead>
      <tbody>
        ${kbs.map(k => `<tr>
          <td><strong>${escapeHtml(k.name)}</strong>${k.sharedFrom ? ' <span class="badge badge-active">共享</span>' : ''}</td>
          <td>${escapeHtml(k.description || '')}${k.sharedFrom ? '（来自：' + escapeHtml(k.sharedFrom) + '，只读）' : ''}</td>
          <td>${k.document_count ?? '-'}</td>
          <td class="row-actions">
            ${k.sharedFrom
              ? '<span class="badge badge-contributor">只读</span>'
              : `<button class="btn btn-sm btn-secondary" onclick="openKbDetail('${k.id}','${escapeHtml(k.name).replace(/'/g,"\\'")}')">管理文档</button>
                 <button class="btn btn-sm btn-danger" onclick="deleteKb('${k.id}')">删除</button>`}
          </td>
        </tr>`).join('')}
      </tbody>
    </table>`;
  } catch (err) {
    box.innerHTML = `<div class="empty-tip">加载失败：${err.message}</div>`;
  }
}

function showKbModal() {
  openModal('新建知识库', `
    <div class="form-group">
      <label>知识库名称</label>
      <input id="kb-name" placeholder="如：部门设计规范库" />
    </div>
    <div class="form-group">
      <label>描述</label>
      <textarea id="kb-desc" placeholder="知识库用途说明"></textarea>
    </div>
  `, async () => {
    const name = document.getElementById('kb-name').value.trim();
    if (!name) { toast('请输入名称', 'warning'); return false; }
    const desc = document.getElementById('kb-desc').value.trim();
    try {
      await api('POST', '/knowledge-bases', {
        name, description: desc, type: 'document',
        chunking_config: { chunk_size: 1000, chunk_overlap: 200 },
      });
      toast('知识库创建成功', 'success');
      closeModal();
      loadKbs();
    } catch (err) { toast('创建失败：' + err.message, 'error'); return false; }
  });
}

async function deleteKb(id) {
  if (!confirm('确定删除该知识库？所有文档将一并删除！')) return;
  try {
    await api('DELETE', `/knowledge-bases/${id}`);
    toast('已删除', 'success');
    loadKbs();
  } catch (err) { toast('删除失败：' + err.message, 'error'); }
}

let currentKbId = '';
async function openKbDetail(id, name) {
  currentKbId = id;
  document.getElementById('kb-detail-title').textContent = `文档列表 — ${name}`;
  document.getElementById('kb-detail').classList.remove('hidden');
  await loadDocuments(id);
}

function closeKbDetail() {
  document.getElementById('kb-detail').classList.add('hidden');
  currentKbId = '';
}

async function loadDocuments(kbId) {
  const box = document.getElementById('doc-table');
  box.innerHTML = '加载中...';
  try {
    const resp = await api('GET', `/knowledge-bases/${kbId}/knowledge`);
    const docs = resp.data || [];
    if (docs.length === 0) {
      box.innerHTML = '<div class="empty-tip">暂无文档，请上传</div>';
      return;
    }
    box.innerHTML = `<table>
      <thead><tr><th>文件名</th><th>状态</th><th>分片数</th><th>操作</th></tr></thead>
      <tbody>
        ${docs.map(d => `<tr>
          <td>${escapeHtml(d.file_name || d.name || '')}</td>
          <td><span class="badge ${d.parse_status === 'completed' ? 'badge-active' : 'badge-pending'}">${d.parse_status || '-'}</span></td>
          <td>${d.chunk_count ?? '-'}</td>
          <td class="row-actions">
            ${d.parse_status !== 'completed' ? `<button class="btn btn-sm btn-secondary" onclick="reparseDoc('${d.id}')">重解析</button>` : ''}
            <button class="btn btn-sm btn-danger" onclick="deleteDoc('${d.id}')">删除</button>
          </td>
        </tr>`).join('')}
      </tbody>
    </table>`;
  } catch (err) {
    box.innerHTML = `<div class="empty-tip">加载失败：${err.message}</div>`;
  }
}

async function uploadDocuments(input) {
  const files = Array.from(input.files);
  if (!files.length) return;
  const form = new FormData();
  for (const f of files) form.append('file', f);
  try {
    toast(`正在上传 ${files.length} 个文件...`, 'info');
    const resp = await fetch(`${API_BASE}/knowledge-bases/${currentKbId}/knowledge/file`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${STATE.token}`, 'X-Tenant-ID': STATE.currentTenantId },
      body: form,
    });
    if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
    toast('上传成功，正在后台解析', 'success');
    input.value = '';
    loadDocuments(currentKbId);
  } catch (err) {
    toast('上传失败：' + err.message, 'error');
  }
}

async function reparseDoc(id) {
  try {
    await api('POST', `/knowledge/${id}/reparse`, {});
    toast('已提交重解析', 'success');
    loadDocuments(currentKbId);
  } catch (err) { toast('操作失败：' + err.message, 'error'); }
}

async function deleteDoc(id) {
  if (!confirm('确定删除该文档？')) return;
  try {
    await api('DELETE', `/knowledge/${id}`);
    toast('已删除', 'success');
    loadDocuments(currentKbId);
  } catch (err) { toast('删除失败：' + err.message, 'error'); }
}

// ---------- 弹窗通用 ----------
let modalConfirmCb = null;
function openModal(title, bodyHtml, onConfirm) {
  document.getElementById('modal-title').textContent = title;
  document.getElementById('modal-body').innerHTML = bodyHtml;
  modalConfirmCb = onConfirm;
  // 部分弹窗（如「分配到部门」）由内部按钮完成操作，无需右下角确认按钮
  document.getElementById('modal-confirm').classList.toggle('hidden', !onConfirm);
  document.getElementById('modal-overlay').classList.remove('hidden');
}
function closeModal(e) {
  if (e && e.target.id !== 'modal-overlay') return;
  document.getElementById('modal-overlay').classList.add('hidden');
  modalConfirmCb = null;
}
document.getElementById('modal-confirm').addEventListener('click', () => {
  if (modalConfirmCb) {
    const ret = modalConfirmCb();
    if (ret && ret.then) ret.catch(err => toast(err.message, 'error'));
  }
});

// ---------- 启动 ----------
// 统一品牌标识
document.title = BRAND;
document.querySelectorAll('.brand-text, .brand-title').forEach(el => { el.textContent = BRAND; });

if (location.pathname === '/register') initRegisterPage();
else initApp();
