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
  chatHistory: [],    // [{role, content, citations}]
  streaming: false,
};

const API_BASE = '/api/v1';

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
    const msg = data.message || data.error || `HTTP ${resp.status}`;
    throw new Error(msg);
  }
  return data;
}

// 流式请求（SSE）
async function apiStream(method, path, body, onChunk, onDone) {
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
      try {
        const obj = JSON.parse(payload);
        onChunk && onChunk(obj);
      } catch { /* 忽略非 JSON 行 */ }
    }
  }
  onDone && onDone();
}

function escapeHtml(s) {
  const div = document.createElement('div');
  div.textContent = s;
  return div.innerHTML;
}

function getRoleBadge(role) {
  const map = { owner: 'badge-owner', admin: 'badge-admin', contributor: 'badge-contributor', viewer: 'badge-viewer' };
  const cls = map[role] || 'badge-viewer';
  return `<span class="badge ${cls}">${role}</span>`;
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
  document.getElementById('app').classList.add('hidden');
  document.getElementById('login-page').classList.remove('hidden');
}

// ---------- 初始化 ----------
async function initApp() {
  if (!STATE.token) {
    document.getElementById('app').classList.add('hidden');
    document.getElementById('login-page').classList.remove('hidden');
    return;
  }
  try {
    const me = await api('GET', '/me');
    STATE.user = me.data || me;
  } catch (err) {
    logout();
    return;
  }
  document.getElementById('login-page').classList.add('hidden');
  document.getElementById('app').classList.remove('hidden');
  document.getElementById('user-name').textContent = STATE.user.name || STATE.user.email || '用户';
  document.getElementById('user-avatar').textContent = (STATE.user.name || STATE.user.email || 'U').charAt(0).toUpperCase();
  await loadTenants();
  showPage(STATE.currentPage);
}

// ---------- 工作空间切换 ----------
async function loadTenants() {
  try {
    const resp = await api('GET', '/tenants');
    STATE.tenants = resp.data || [];
    const sel = document.getElementById('tenant-select');
    sel.innerHTML = '';
    if (STATE.tenants.length === 0) {
      sel.innerHTML = '<option value="">暂无工作空间</option>';
      return;
    }
    for (const t of STATE.tenants) {
      const opt = document.createElement('option');
      opt.value = t.id;
      opt.textContent = t.name;
      sel.appendChild(opt);
    }
    // 选择上次的或第一个
    if (STATE.currentTenantId && STATE.tenants.some(t => t.id === STATE.currentTenantId)) {
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
  const t = STATE.tenants.find(x => x.id === STATE.currentTenantId);
  if (t) document.getElementById('members-dept-name').textContent = t.name;
  STATE.currentAgentId = '';
  STATE.chatHistory = [];
  renderChatMessages();
}

// ---------- 页面切换 ----------
function showPage(name) {
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
async function loadAgentsForChat() {
  const list = document.getElementById('agent-list');
  list.innerHTML = '<div class="empty-tip">加载中...</div>';
  try {
    const resp = await api('GET', '/agents');
    const agents = resp.data || [];
    if (agents.length === 0) {
      list.innerHTML = '<div class="empty-tip">暂无智能体，请先在「智能体管理」中创建</div>';
      return;
    }
    list.innerHTML = agents.map(a => `
      <div class="agent-item ${a.id === STATE.currentAgentId ? 'active' : ''}" onclick="selectAgent('${a.id}')">
        <div class="agent-item-name">${escapeHtml(a.name)}</div>
        <div class="agent-item-desc">${escapeHtml(a.description || '')}</div>
      </div>
    `).join('');
  } catch (err) {
    list.innerHTML = `<div class="empty-tip">加载失败：${err.message}</div>`;
  }
}

function selectAgent(id) {
  STATE.currentAgentId = id;
  const agent = (STATE.tenants.length && STATE.currentAgentId) ? null : null;
  // 从列表中找名称
  const items = document.querySelectorAll('.agent-item');
  items.forEach(i => i.classList.remove('active'));
  const active = document.querySelector(`.agent-item[onclick*="'${id}'"]`);
  if (active) active.classList.add('active');
  const name = active ? active.querySelector('.agent-item-name').textContent : '智能体';
  document.querySelector('.chat-agent-name').textContent = name;
  STATE.chatHistory = [];
  renderChatMessages();
}

function renderChatMessages() {
  const box = document.getElementById('chat-messages');
  if (STATE.chatHistory.length === 0) {
    box.innerHTML = `<div class="chat-placeholder">
      <div class="chat-placeholder-icon">💡</div>
      <p>选择左侧智能体，开始向部门知识库提问</p>
    </div>`;
    return;
  }
  box.innerHTML = STATE.chatHistory.map((m, i) => {
    if (m.role === 'user') {
      return `<div class="msg msg-user"><div class="msg-bubble">${escapeHtml(m.content)}</div></div>`;
    } else {
      const cites = m.citations && m.citations.length
        ? `<div class="msg-citations">📚 引用：${m.citations.map((c, j) => `<a href="#" onclick="event.preventDefault()">${escapeHtml(c)}</a>`).join('，')}</div>`
        : '';
      return `<div class="msg msg-bot"><div class="msg-bubble" id="msg-${i}">${escapeHtml(m.content)}</div>${cites}</div>`;
    }
  }).join('');
  box.scrollTop = box.scrollHeight;
}

async function sendMessage() {
  const input = document.getElementById('chat-input');
  const text = input.value.trim();
  if (!text) return;
  if (!STATE.currentAgentId) { toast('请先选择智能体', 'warning'); return; }
  if (STATE.streaming) return;

  STATE.chatHistory.push({ role: 'user', content: text });
  input.value = '';
  input.style.height = 'auto';
  STATE.streaming = true;
  renderChatMessages();

  // 添加机器人占位
  const botIdx = STATE.chatHistory.length;
  STATE.chatHistory.push({ role: 'assistant', content: '' });
  renderChatMessages();
  showTyping(botIdx);

  try {
    await apiStream('POST', '/knowledge-chat', {
      agent_id: STATE.currentAgentId,
      query: text,
      stream: true,
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
      STATE.streaming = false;
      renderChatMessages();
    });
  } catch (err) {
    STATE.streaming = false;
    STATE.chatHistory[botIdx].content = '⚠️ 回答失败：' + err.message;
    renderChatMessages();
  }
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
    const resp = await api('GET', '/tenants');
    const tenants = resp.data || [];
    if (tenants.length === 0) {
      box.innerHTML = '<div class="empty-tip">暂无部门</div>';
      return;
    }
    box.innerHTML = `<table>
      <thead><tr><th>部门名称</th><th>ID</th><th>操作</th></tr></thead>
      <tbody>
        ${tenants.map(t => `<tr>
          <td><strong>${escapeHtml(t.name)}</strong></td>
          <td class="muted">${t.id}</td>
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
      api('GET', `/tenants/${STATE.currentTenantId}/members`),
      api('GET', `/tenants/${STATE.currentTenantId}/invitations`),
    ]);
    const members = mResp.data || [];
    const invites = iResp.data || [];
    mb.innerHTML = members.length === 0 ? '<div class="empty-tip">暂无成员</div>' : `<table>
      <thead><tr><th>姓名</th><th>邮箱</th><th>角色</th><th>操作</th></tr></thead>
      <tbody>
        ${members.map(m => `<tr>
          <td>${escapeHtml(m.name || m.user_name || '-')}</td>
          <td>${escapeHtml(m.email || '')}</td>
          <td>${getRoleBadge(m.role)}</td>
          <td class="row-actions">
            ${m.role !== 'owner' ? `<button class="btn btn-sm btn-ghost" onclick="removeMember('${m.user_id || m.id}')">移除</button>` : ''}
          </td>
        </tr>`).join('')}
      </tbody>
    </table>`;
    ib.innerHTML = invites.length === 0 ? '<div class="empty-tip">暂无待处理邀请</div>' : `<table>
      <thead><tr><th>邮箱</th><th>角色</th><th>状态</th><th>操作</th></tr></thead>
      <tbody>
        ${invites.map(inv => `<tr>
          <td>${escapeHtml(inv.email || '')}</td>
          <td>${getRoleBadge(inv.role)}</td>
          <td><span class="badge badge-pending">${inv.status || 'pending'}</span></td>
          <td class="row-actions">
            ${inv.invite_url ? `<a class="btn btn-sm btn-secondary" href="${inv.invite_url}" target="_blank">复制链接</a>` : ''}
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

function showInviteModal() {
  openModal('邀请成员', `
    <div class="form-group">
      <label>邮箱</label>
      <input id="invite-email" placeholder="成员邮箱" />
      <p class="form-hint">多个邮箱用逗号分隔</p>
    </div>
    <div class="form-group">
      <label>角色</label>
      <select id="invite-role">
        <option value="contributor">普通成员（Contributor）</option>
        <option value="viewer">只读成员（Viewer）</option>
        <option value="admin">管理员（Admin）</option>
        <option value="owner">所有者（Owner）</option>
      </select>
    </div>
  `, async () => {
    const email = document.getElementById('invite-email').value.trim();
    const role = document.getElementById('invite-role').value;
    if (!email) { toast('请输入邮箱', 'warning'); return false; }
    const emails = email.split(/[,，\s]+/).filter(Boolean);
    let ok = 0, fail = 0;
    for (const e of emails) {
      try {
        await api('POST', `/tenants/${STATE.currentTenantId}/invitations`, { email: e, role });
        ok++;
      } catch (err) { fail++; }
    }
    toast(`邀请完成：成功 ${ok}，失败 ${fail}`, ok ? 'success' : 'error');
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

function showAgentModal(agent = null) {
  getKbOptions().then(kbs => {
    const kbOptions = kbs.map(k => `<option value="${k.id}">${escapeHtml(k.name)}</option>`).join('');
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
        <p class="form-hint">按住 Ctrl/Cmd 多选</p>
      </div>
      <div class="form-group">
        <label>答复约束提示词（可选）</label>
        <textarea id="agent-prompt" placeholder="如：只基于知识库内容回答，不知道则回复"未找到相关信息"">${escapeHtml(agent?.config?.system_prompt || '')}</textarea>
      </div>
    `, async () => {
      const name = document.getElementById('agent-name').value.trim();
      if (!name) { toast('请输入名称', 'warning'); return false; }
      const desc = document.getElementById('agent-desc').value.trim();
      const kbSelect = document.getElementById('agent-kbs');
      const kbIds = Array.from(kbSelect.selectedOptions).map(o => o.value);
      const prompt = document.getElementById('agent-prompt').value;
      const payload = {
        name, description: desc,
        config: {
          agent_mode: 'quick-answer',
          system_prompt: prompt,
          kb_selection_mode: 'selected',
          knowledge_bases: kbIds,
          ...(agent?.config || {}),
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

// ---------- 文档管理 ----------
async function loadKbs() {
  const box = document.getElementById('kb-table');
  box.innerHTML = '加载中...';
  try {
    const resp = await api('GET', '/knowledge-bases');
    const kbs = resp.data || [];
    if (kbs.length === 0) {
      box.innerHTML = '<div class="empty-tip">暂无知识库，请点击右上角新建</div>';
      return;
    }
    box.innerHTML = `<table>
      <thead><tr><th>知识库名称</th><th>描述</th><th>文档数</th><th>操作</th></tr></thead>
      <tbody>
        ${kbs.map(k => `<tr>
          <td><strong>${escapeHtml(k.name)}</strong></td>
          <td>${escapeHtml(k.description || '')}</td>
          <td>${k.document_count ?? '-'}</td>
          <td class="row-actions">
            <button class="btn btn-sm btn-secondary" onclick="openKbDetail('${k.id}','${escapeHtml(k.name).replace(/'/g,"\\'")}')">管理文档</button>
            <button class="btn btn-sm btn-danger" onclick="deleteKb('${k.id}')">删除</button>
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
initApp();
