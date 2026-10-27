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
  passwordComplex: false,   // 后端是否开启复杂密码策略
  // 对话历史（/sessions 由后端按 user_id 过滤，只含本人会话）
  historySessions: [],
  historyActiveId: '',
  historyTotal: 0,
  agentNames: null,         // agent_id -> 智能体名称（会话列表展示用）
  // 文档上传限制（系统管理员可在「文档管理 → 上传限制设置」中调整）
  uploadLimits: { max_files_per_upload: 50, max_file_size_mb: 50, max_total_size_mb: 200 },
  uploadLimitRanges: {},
  uploadLimitLabels: {},
  // 文档文件夹：WeKnora 原生无文件夹概念，门户维护「知识库 → 文件夹树 + 文档归属」
  docFolders: { folders: [], docs: {} },
  docScope: '',             // 当前视图：'' 全部 / ROOT_FOLDER 未分类 / 文件夹 id
  selectedDocs: new Set(),
  allDocs: [],
};

// 前端用该哨兵值表示「未分类（根目录）」，后端以空字符串表示
const ROOT_FOLDER = '__root__';

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
  const h = { 'Content-Type': 'application/json' };
  if (STATE.token) h['Authorization'] = `Bearer ${STATE.token}`;
  if (STATE.currentTenantId) h['X-Tenant-ID'] = STATE.currentTenantId;
  // extra 放最后：允许调用方显式覆盖部门上下文（超管跨部门管理用）
  return { ...h, ...extra };
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
// /auth/me 的返回体为 { data: { user: {...}, memberships: [...], ... } }，
// 顶层取 username / email 会取不到（嵌套在 user 里），统一走这里的取值器。
function currentUser() {
  const u = STATE.user || {};
  if (u.user && (u.user.id || u.user.email)) return u.user;
  return u.user || u;
}
function currentUserName() {
  const u = currentUser();
  return (u.username || u.name || u.email || '用户').trim() || '用户';
}
function currentUserEmail() { return currentUser().email || ''; }
function currentUserId() { return currentUser().id || ''; }
// 部门内的管理类功能（人员 / 智能体 / 文档）仅对下列角色开放，
// 默认只有文档管理员 Owner 可用；如需放开其它角色，在此集合追加即可。
const MANAGE_ROLES = ['owner'];
const MANAGE_PAGES = ['members', 'agents', 'documents'];
// 平台管理页：跨越部门查看他人数据，仅系统管理员可用
const ADMIN_PAGES = ['all-conversations', 'upload-records'];
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

// 系统管理员（超管 / admin）：可跨工作空间管理，也是唯一能提权、重置密码、启停内置智能体的角色
function isSystemAdmin() {
  const u = currentUser();
  return !!(u.is_system_admin || u.can_access_all_tenants);
}
function isDeptManager() { return isSystemAdmin() || MANAGE_ROLES.includes(currentRole()); }
function canAccessPage(page) {
  if (ADMIN_PAGES.includes(page)) return isSystemAdmin();
  if (page === 'builtin-agents') return isSystemAdmin();
  return !MANAGE_PAGES.includes(page) || isDeptManager();
}

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
  // 上传限制设置仅系统管理员可见
  const limitBtn = document.getElementById('btn-upload-limits');
  if (limitBtn) limitBtn.classList.toggle('hidden', !isSystemAdmin());
  const chip = document.getElementById('user-role');
  if (chip) {
    const role = currentRole();
    const sys = isSystemAdmin();
    chip.textContent = sys ? '系统管理员' : (role ? roleText(role) : '未加入部门');
    chip.className = `role-chip ${sys ? 'role-chip-admin' : `role-chip-${role || 'none'}`}`;
  }
  // 内置智能体启停 / 平台管理（全员对话、文档上传记录）仅系统管理员可见
  const isSys = isSystemAdmin();
  const bNav = document.querySelector('.nav-item[data-page="builtin-agents"]');
  if (bNav) bNav.classList.toggle('hidden', !isSys);
  ADMIN_PAGES.forEach(p => {
    const nav = document.querySelector(`.nav-item[data-page="${p}"]`);
    if (nav) nav.classList.toggle('hidden', !isSys);
  });
  const platformGroup = document.getElementById('nav-group-platform');
  if (platformGroup) platformGroup.classList.toggle('hidden', !isSys);
  renderIdentity();
}

// 右上角：显示当前登录人的姓名与邮箱（顶栏 + 账号菜单）
function renderIdentity() {
  const name = currentUserName();
  const email = currentUserEmail();
  const el = document.getElementById('user-name');
  if (el) el.textContent = name;
  const avatar = document.getElementById('user-avatar');
  if (avatar) avatar.textContent = name.charAt(0).toUpperCase();
  const mName = document.getElementById('user-menu-name');
  if (mName) mName.textContent = name;
  const mEmail = document.getElementById('user-menu-email');
  if (mEmail) mEmail.textContent = email || '（未设置邮箱）';
}

// ---------- 账号菜单 ----------
function toggleUserMenu(e) {
  if (e) e.stopPropagation();
  const menu = document.getElementById('user-menu');
  if (menu) menu.classList.toggle('hidden');
}
document.addEventListener('click', (e) => {
  const menu = document.getElementById('user-menu');
  if (!menu || menu.classList.contains('hidden')) return;
  if (e.target.closest('.user-box')) return;
  menu.classList.add('hidden');
});

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
  const ok = await askConfirmBox({
    dialogTitle: '退出登录',
    title: '确定退出当前账号？',
    sub: currentUserEmail() || '',
    notes: ['退出后需要重新输入账号密码才能进入'],
    confirmText: '退出登录',
    danger: false,
    tone: 'info',
  });
  if (!ok) return;
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
  renderIdentity();
  await loadUploadLimits();
  // 密码策略：仅在改密码 / 重置密码前取一次，用于生成合规的随机密码
  try {
    const cfg = await api('GET', '/auth/config');
    STATE.passwordComplex = !!(cfg.complex_password_enabled || (cfg.data || {}).complex_password_enabled);
  } catch { /* 取不到时按基础策略处理 */ }
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
    populateBuiltinDeptSelect();
    populateAuditDeptSelects();
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

// 系统管理员可跨部门启停内置智能体，这里单独维护一个部门下拉
function populateBuiltinDeptSelect() {
  const sel = document.getElementById('builtin-dept-select');
  if (!sel) return;
  const keep = sel.value;
  sel.innerHTML = STATE.tenants.map(t => `<option value="${t.id}">${escapeHtml(t.name)}</option>`).join('');
  if (keep && STATE.tenants.some(t => t.id === keep)) sel.value = keep;
  else sel.value = String(STATE.currentTenantId || (STATE.tenants[0] || {}).id || '');
  if (!sel.value && STATE.tenants[0]) sel.value = STATE.tenants[0].id;
}

// 平台管理的部门筛选项：系统管理员可看全部部门，默认「全部部门」
function populateAuditDeptSelects() {
  const options = STATE.tenants
    .map(t => `<option value="${t.id}">${escapeHtml(t.name)}</option>`).join('');
  for (const id of ['conv-dept-select', 'upload-dept-select']) {
    const sel = document.getElementById(id);
    if (!sel) continue;
    const keep = sel.value;
    sel.innerHTML = `<option value="">全部部门</option>${options}`;
    sel.value = keep && STATE.tenants.some(t => t.id === keep) ? keep : '';
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
  const hd = document.getElementById('history-dept-name');
  if (hd) hd.textContent = t ? t.name : '未选择部门';
  // 会话归属于部门，切换部门后历史列表需重新加载
  STATE.historySessions = [];
  STATE.historyActiveId = '';
  STATE.historyTotal = 0;
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
  // 越权保护：管理类页面仅部门文档管理员可用；内置智能体启停仅系统管理员可用
  if (!canAccessPage(name)) {
    if (ADMIN_PAGES.includes(name)) toast('仅系统管理员可查看「全员对话 / 文档上传记录」', 'warning');
    else if (name === 'builtin-agents') toast('仅系统管理员可管理内置智能体启停', 'warning');
    else toast('仅本部门文档管理员（Owner）可使用「人员 / 智能体 / 文档管理」', 'warning');
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
  else if (name === 'history') loadHistory();
  else if (name === 'departments') loadDepartments();
  else if (name === 'members') loadMembers();
  else if (name === 'agents') loadAgents();
  else if (name === 'builtin-agents') loadBuiltinAgents();
  else if (name === 'documents') loadKbs();
  else if (name === 'all-conversations') loadConversations();
  else if (name === 'upload-records') loadUploadRecords();
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

    // 被本部门停用的内置智能体不出现在问答页（代理层已打 disabled_in_tenant 标记）
    const usable = agents.filter(a => !a.disabled_in_tenant);
    if (usable.length === 0) {
      list.innerHTML = '<div class="empty-tip">暂无可用智能体<span class="empty-tip-sub">请联系本部门文档管理员创建或启用内置智能体</span></div>';
      return;
    }
    list.innerHTML = usable.map(a => {
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

// ---------- 对话历史（仅本人） ----------
// GET /sessions 由后端按 user_id 过滤，天然只返回当前登录人的会话
const HISTORY_PAGE_SIZE = 100;
let historySearchTimer = null;

// 会话里只带 agent_id，展示时补成智能体名称
async function loadAgentNameMap() {
  if (STATE.agentNames) return STATE.agentNames;
  const map = {};
  try {
    const resp = await api('GET', '/agents');
    for (const a of resp.data || []) if (a.id) map[a.id] = a.name || a.id;
  } catch { /* 取不到就退回显示原始 ID */ }
  try {
    const orgResp = await api('GET', '/organizations');
    for (const org of (orgResp.data || {}).organizations || []) {
      const r = await api('GET', `/organizations/${org.id}/shared-agents`);
      for (const item of r.data || []) {
        const a = item.agent || item;
        if (a && a.id && !map[a.id]) map[a.id] = a.name || a.id;
      }
    }
  } catch { /* 未加入组织时忽略 */ }
  map['builtin-quick-answer'] = map['builtin-quick-answer'] || '快速问答';
  STATE.agentNames = map;
  return map;
}

function agentNameOf(session) {
  const id = ((session.last_request_state || {}).agent_id) || session.agent_id || '';
  if (!id) return '';
  return (STATE.agentNames || {})[id] || id;
}

// 时间展示：今天显示时刻，今年显示 月-日 时:分，更早显示完整日期
function formatTime(iso) {
  if (!iso) return '';
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return String(iso).slice(0, 16).replace('T', ' ');
  const now = new Date();
  const pad = n => String(n).padStart(2, '0');
  const hm = `${pad(d.getHours())}:${pad(d.getMinutes())}`;
  if (d.toDateString() === now.toDateString()) return `今天 ${hm}`;
  if (d.getFullYear() === now.getFullYear()) return `${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${hm}`;
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${hm}`;
}

function onHistorySearch(value) {
  clearTimeout(historySearchTimer);
  historySearchTimer = setTimeout(() => loadHistory(value.trim()), 300);
}

async function loadHistory(keyword = '') {
  const listBox = document.getElementById('history-list');
  const countEl = document.getElementById('history-count');
  if (listBox) listBox.innerHTML = '<div class="empty-tip">加载中...</div>';
  try {
    await loadAgentNameMap();
    const query = keyword ? `&keyword=${encodeURIComponent(keyword)}` : '';
    const resp = await api('GET', `/sessions?page=1&page_size=${HISTORY_PAGE_SIZE}${query}`);
    STATE.historySessions = resp.data || [];
    STATE.historyTotal = resp.total ?? (resp.data || []).length;
    renderHistoryList();
    if (countEl) countEl.textContent = `共 ${STATE.historyTotal} 个会话`;
  } catch (err) {
    if (listBox) listBox.innerHTML = `<div class="empty-tip">加载失败：${escapeHtml(err.message)}</div>`;
    if (countEl) countEl.textContent = '加载失败';
  }
}

function renderHistoryList() {
  const box = document.getElementById('history-list');
  if (!box) return;
  const list = STATE.historySessions || [];
  if (list.length === 0) {
    box.innerHTML = '<div class="empty-tip">暂无对话记录<span class="empty-tip-sub">去「智能问答」提问后，会话会自动出现在这里</span></div>';
    return;
  }
  box.innerHTML = list.map(s => {
    const active = s.id === STATE.historyActiveId;
    const title = s.title || '未命名会话';
    const agent = agentNameOf(s);
    return `
      <div class="history-item${active ? ' active' : ''}" data-id="${s.id}" onclick="openHistorySession('${s.id}')">
        <div class="history-item-top">
          <span class="history-item-title">${escapeHtml(title)}</span>
          <button class="history-del" title="删除该会话"
                  onclick="event.stopPropagation();deleteHistorySession('${s.id}')">
            <svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M18 6 6 18M6 6l12 12"/></svg>
          </button>
        </div>
        <div class="history-item-meta">
          <span class="history-time">${escapeHtml(formatTime(s.updated_at || s.created_at))}</span>
          ${agent ? `<span class="history-agent">${escapeHtml(agent)}</span>` : ''}
        </div>
      </div>`;
  }).join('');
}

async function openHistorySession(id) {
  const detail = document.getElementById('history-detail');
  STATE.historyActiveId = id;
  renderHistoryList();
  const session = (STATE.historySessions || []).find(s => s.id === id) || {};
  detail.innerHTML = '<div class="empty-tip">加载中...</div>';
  try {
    const resp = await api('GET', `/messages/${id}/load?limit=200`);
    const msgs = (resp.data || []).filter(m => m.role === 'user' || m.role === 'assistant');
    const agent = agentNameOf(session);
    detail.innerHTML = `
      <div class="history-detail-head">
        <div class="history-detail-title">
          <h3>${escapeHtml(session.title || '未命名会话')}</h3>
          <p>${escapeHtml(formatTime(session.created_at))}${agent ? ' · 智能体：' + escapeHtml(agent) : ''} · 共 ${msgs.length} 条消息</p>
        </div>
        <button class="btn btn-danger btn-sm" onclick="deleteHistorySession('${id}')">删除会话</button>
      </div>
      <div class="history-messages">
        ${msgs.length === 0
          ? '<div class="empty-tip">该会话暂无消息</div>'
          : msgs.map(m => renderHistoryMessage(m)).join('')}
      </div>`;
  } catch (err) {
    detail.innerHTML = `<div class="empty-tip">加载失败：${escapeHtml(err.message)}</div>`;
  }
}

function renderHistoryMessage(m) {
  const time = formatTime(m.created_at);
  if (m.role === 'user') {
    return `<div class="msg msg-user">
      <div class="msg-avatar msg-avatar-user">${escapeHtml(userInitial())}</div>
      <div class="msg-body">
        <div class="msg-bubble">${escapeHtml(m.content || '')}</div>
        <span class="history-msg-time">${escapeHtml(time)}</span>
      </div>
    </div>`;
  }
  const refs = (m.knowledge_references || []).map(r => r.file_name || r.title || r.source || '').filter(Boolean);
  return `<div class="msg msg-bot">
    <div class="msg-avatar msg-avatar-bot">AI</div>
    <div class="msg-body">
      <div class="msg-bubble">${escapeHtml(m.content || '')}</div>
      ${refs.length ? `<div class="msg-citations"><span class="cite-label">引用来源</span>${
        refs.map(c => `<span class="cite-chip" title="${escapeHtml(c)}">${escapeHtml(c)}</span>`).join('')
      }</div>` : ''}
      <span class="history-msg-time">${escapeHtml(time)}</span>
    </div>
  </div>`;
}

async function deleteHistorySession(id) {
  const session = (STATE.historySessions || []).find(s => s.id === id) || {};
  const name = session.title || '未命名会话';
  const ok = await askConfirmBox({
    dialogTitle: '删除会话',
    title: `确定删除会话「${name}」？`,
    notes: ['该会话的全部消息将一并删除', '删除后不可恢复'],
    confirmText: '删除会话',
  });
  if (!ok) return;
  try {
    await api('DELETE', `/sessions/${id}`);
    if (STATE.historyActiveId === id) {
      STATE.historyActiveId = '';
      document.getElementById('history-detail').innerHTML = `
        <div class="history-empty">
          <div class="history-empty-mark">💬</div>
          <p class="history-empty-title">选择左侧会话查看完整对话</p>
          <p class="history-empty-desc">这里只会展示你本人发起的问答记录，可随时删除不再需要的会话。</p>
        </div>`;
    }
    toast('会话已删除', 'success');
    await loadHistory((document.getElementById('history-keyword') || {}).value || '');
  } catch (err) {
    toast('删除失败：' + err.message, 'error');
  }
}

async function deleteAllSessions() {
  const total = STATE.historyTotal || 0;
  if (!total) { toast('当前没有可删除的会话', 'warning'); return; }
  const ok = await askConfirmBox({
    dialogTitle: '清空全部会话',
    title: `确定清空全部 ${total} 个会话？`,
    notes: ['所有对话记录将被永久删除', '该操作不可恢复，请谨慎操作'],
    confirmText: '全部清空',
  });
  if (!ok) return;
  try {
    await api('POST', '/sessions/batch', { delete_all: true });
    STATE.historyActiveId = '';
    document.getElementById('history-detail').innerHTML = `
      <div class="history-empty">
        <div class="history-empty-mark">🗑️</div>
        <p class="history-empty-title">已清空全部对话历史</p>
        <p class="history-empty-desc">新的问答会重新出现在这里。</p>
      </div>`;
    toast('已清空全部会话', 'success');
    await loadHistory();
  } catch (err) {
    toast('清空失败：' + err.message, 'error');
  }
}

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
    // 平台超管默认就是所有部门的管理员（数据侧由 ensure-admin-all-departments.sh 保证）
    const sysAdmin = isSystemAdmin();
    box.innerHTML = `<table>
      <thead><tr><th>部门名称</th><th>ID</th><th>我的角色</th><th>操作</th></tr></thead>
      <tbody>
        ${tenants.map(t => `<tr>
          <td><strong>${escapeHtml(t.name)}</strong></td>
          <td class="muted">${t.id}</td>
          <td>${sysAdmin
            ? '<span class="badge badge-owner">系统管理员（全部部门）</span>'
            : (t.role ? getRoleBadge(t.role) : '<span class="muted">-</span>')}</td>
          <td class="row-actions">
            <button class="btn btn-sm btn-secondary" onclick="enterTenant('${t.id}')">进入</button>
          </td>
        </tr>`).join('')}
      </tbody>
    </table>
    ${sysAdmin ? '<p class="form-hint">平台管理员默认拥有所有部门的管理员权限（部门空间的 owner），无需逐个指派。</p>' : ''}`;
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
            ${isSystemAdmin()
              ? `<button class="btn btn-sm btn-secondary" onclick="changeMemberEmail('${m.user_id}','${escapeHtml(m.email || '')}')">改邮箱</button>
                 <button class="btn btn-sm btn-secondary" onclick="resetMemberPassword('${m.user_id}','${escapeHtml(m.email || '')}','${escapeHtml(m.username || m.name || '').replace(/'/g, "\\'")}')">重置密码</button>`
              : ''}
            ${m.role !== 'owner' ? `<button class="btn btn-sm btn-ghost" onclick="removeMember('${m.user_id}','${escapeHtml(m.username || m.name || '').replace(/'/g, "\\'")}','${escapeHtml(m.email || '')}')">移除</button>` : ''}
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
            <button class="btn btn-sm btn-ghost" onclick="revokeInvite('${inv.id}','${escapeHtml(inv.is_share_link ? '共享邀请链接（任何人可点击加入）' : (inv.invitee_email || inv.email || '')).replace(/'/g, "\\'")}')">撤销</button>
          </td>
        </tr>`).join('')}
      </tbody>
    </table>`;
  } catch (err) {
    mb.innerHTML = `<div class="empty-tip">加载失败：${err.message}</div>`;
    ib.innerHTML = `<div class="empty-tip">加载失败：${err.message}</div>`;
  }
}

const ROLE_OPTION_CONTRIBUTOR = '<option value="contributor">普通成员（Contributor）</option>';
const ROLE_OPTION_VIEWER = '<option value="viewer">只读成员（Viewer）</option>';
const ROLE_OPTION_ADMIN = '<option value="admin">管理员（Admin）</option>';
const ROLE_OPTION_OWNER = '<option value="owner">文档管理员（Owner）</option>';

// 管理员 / 文档管理员只能由系统管理员授予；部门文档管理员只能指派普通角色。
// 代理层（portal/server.py）会二次拦截，前端只是不放选项。
function roleOptionsHtml() {
  if (isSystemAdmin()) {
    return ROLE_OPTION_CONTRIBUTOR + ROLE_OPTION_VIEWER + ROLE_OPTION_ADMIN + ROLE_OPTION_OWNER;
  }
  return ROLE_OPTION_CONTRIBUTOR + ROLE_OPTION_VIEWER;
}
function roleLimitHint() {
  return isSystemAdmin() ? '' : '<p class="form-hint">管理员（Admin）与文档管理员（Owner）仅系统管理员可设置</p>';
}

async function changeMemberRole(userId, currentRole) {
  openModal('修改成员角色', `
    <div class="form-group">
      <label>新角色</label>
      <select id="member-role">${roleOptionsHtml()}</select>
      ${roleLimitHint()}
    </div>
  `, async () => {
    const role = document.getElementById('member-role').value;
    // 管理员 / 文档管理员本人的角色调整只能由系统管理员执行，避免部门管理员误操作降级
    if (!isSystemAdmin() && ['owner', 'admin'].includes(String(currentRole))) {
      toast('管理员 / 文档管理员的角色调整仅系统管理员可操作', 'error');
      return false;
    }
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
    openResultModal({
      dialogTitle: '邀请链接',
      tone: 'link',
      title: '请手动复制邀请链接',
      code: url,
      hint: '把链接发给要加入的成员，7 天内有效。',
    });
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
      <select id="invite-role">${roleOptionsHtml()}</select>
      ${roleLimitHint()}
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
          openResultModal({
            dialogTitle: '邀请链接已生成',
            tone: 'link',
            title: '把链接发给要加入的成员',
            sub: '7 天内有效，对方点击后自助注册加入本部门',
            code: url,
            confirmText: '完成',
            onConfirm: () => { closeModal(); loadMembers(); },
          });
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

// ---------- 登录邮箱修改 / 密码重置 ----------
// 修改登录邮箱：本人可改自己，系统管理员可改任何人（WeKnora 原生无此 API，由门户 /portal/users/email 落库）
function showMyEmailModal() {
  const menu = document.getElementById('user-menu');
  if (menu) menu.classList.add('hidden');
  openModal('修改我的登录邮箱', `
    <div class="form-group">
      <label>当前邮箱</label>
      <input id="my-email-old" value="${escapeHtml(currentUserEmail())}" disabled />
    </div>
    <div class="form-group">
      <label>新邮箱（登录账号）</label>
      <input type="email" id="my-email-new" placeholder="请输入新的登录邮箱" />
      <p class="form-hint">修改后当前会话会失效，需用新邮箱重新登录</p>
    </div>
  `, async () => {
    const email = document.getElementById('my-email-new').value.trim();
    if (!email) { toast('请输入新邮箱', 'warning'); return false; }
    try {
      await updateUserEmail(currentUserId(), email);
    } catch (err) { toast('修改失败：' + err.message, 'error'); return false; }
    closeModal();
    toast('邮箱已更新，请重新登录', 'success');
    localStorage.removeItem('obara_token');
    STATE.token = '';
    STATE.user = null;
    showLoginOnly();
  });
}

async function changeMemberEmail(userId, oldEmail) {
  openModal('修改成员登录邮箱', `
    <div class="form-group">
      <label>当前邮箱</label>
      <input value="${escapeHtml(oldEmail)}" disabled />
    </div>
    <div class="form-group">
      <label>新邮箱（登录账号）</label>
      <input type="email" id="member-email-new" placeholder="请输入新的登录邮箱" />
      <p class="form-hint">该成员的全部会话会被撤销，下次需用新邮箱登录</p>
    </div>
  `, async () => {
    const email = document.getElementById('member-email-new').value.trim();
    if (!email) { toast('请输入新邮箱', 'warning'); return false; }
    try {
      await updateUserEmail(userId, email);
      toast('登录邮箱已更新', 'success');
      closeModal();
      loadMembers();
    } catch (err) { toast('修改失败：' + err.message, 'error'); return false; }
  });
}

async function updateUserEmail(userId, email) {
  if (!userId) throw new Error('未取到用户 ID');
  await api('POST', '/portal/users/email', { user_id: userId, email: email.trim().toLowerCase() });
}

// 随机密码：基础策略要求 8-32 位且含字母与数字；开启复杂策略时还须含大小写与特殊字符
function randomPassword() {
  const upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ';
  const lower = 'abcdefghijkmnopqrstuvwxyz';
  const digits = '23456789';
  const special = '!@#$%^&*';
  const pick = (s) => s[Math.floor(Math.random() * s.length)];
  let pwd = pick(upper) + pick(lower) + pick(digits);
  if (STATE.passwordComplex) pwd += pick(special);
  const pool = upper + lower + digits + (STATE.passwordComplex ? special : '');
  const len = STATE.passwordComplex ? 16 : 12;
  while (pwd.length < len) pwd += pick(pool);
  // 打乱，避免固定前缀
  return pwd.split('').sort(() => Math.random() - 0.5).join('');
}

// 系统管理员随机重置成员密码（后端 /system/admin/users/reset-password 接口，仅超管可用）
async function resetMemberPassword(userId, email, username) {
  if (!email) { toast('该成员没有登录邮箱，无法重置密码', 'warning'); return; }
  const who = username || email;
  const ok = await askConfirmBox({
    dialogTitle: '重置成员密码',
    title: `为「${who}」重置登录密码？`,
    sub: email,
    notes: [
      '系统将随机生成一个符合密码策略的新密码',
      '该成员的全部会话会被撤销，需使用新密码重新登录',
      '新密码仅显示这一次，请立即复制并安全通知本人',
    ],
    confirmText: '确认重置',
  });
  if (!ok) return;
  const pwd = randomPassword();
  try {
    await api('POST', '/system/admin/users/reset-password', { email, new_password: pwd });
    openResultModal({
      dialogTitle: '密码已重置',
      title: '新密码已生成',
      sub: `${who} · ${email}`,
      code: pwd,
      hint: '此密码只显示一次，请立即复制并安全通知本人；对方会话已全部撤销，需重新登录。',
      confirmText: '复制并关闭',
      onConfirm: () => { copyText(pwd); closeModal(); },
    });
  } catch (err) { toast('重置失败：' + err.message, 'error'); }
}

async function copyText(text) {
  try {
    await navigator.clipboard.writeText(text);
    toast('已复制到剪贴板', 'success');
  } catch {
    // 浏览器拒绝剪贴板权限时，用统一弹窗兜底（替代原生 prompt）
    openResultModal({
      dialogTitle: '请手动复制',
      tone: 'info',
      title: '当前环境不支持自动复制',
      code: text,
      hint: '请手动选中上方内容完成复制。',
    });
  }
}

// 自助改密码（后端 /auth/change-password：需旧密码，成功后会话被撤销）
function showMyPasswordModal() {
  const menu = document.getElementById('user-menu');
  if (menu) menu.classList.add('hidden');
  openModal('修改我的密码', `
    <div class="form-group">
      <label>当前密码</label>
      <input type="password" id="pwd-old" autocomplete="current-password" />
    </div>
    <div class="form-group">
      <label>新密码</label>
      <input type="password" id="pwd-new" autocomplete="new-password" />
      <p class="form-hint">${STATE.passwordComplex
        ? '8-32 位，须含大写、小写、数字与特殊字符'
        : '8-32 位，须含字母与数字'}</p>
    </div>
  `, async () => {
    const oldPwd = document.getElementById('pwd-old').value;
    const newPwd = document.getElementById('pwd-new').value;
    if (!oldPwd || !newPwd) { toast('请填写完整', 'warning'); return false; }
    try {
      await api('POST', '/auth/change-password', { old_password: oldPwd, new_password: newPwd });
      toast('密码已修改，请重新登录', 'success');
      closeModal();
      localStorage.removeItem('obara_token');
      STATE.token = '';
      STATE.user = null;
      showLoginOnly();
    } catch (err) { toast('修改失败：' + err.message, 'error'); return false; }
  });
}

async function removeMember(userId, username, email) {
  const ok = await askConfirmBox({
    dialogTitle: '移除成员',
    title: username ? `确定将「${username}」移出本部门？` : '确定移除该成员？',
    sub: email || '',
    notes: ['该成员将失去本部门知识库与智能体的访问权限', '其在本部门的角色与配置会一并清除'],
    confirmText: '移除成员',
  });
  if (!ok) return;
  try {
    await api('DELETE', `/tenants/${STATE.currentTenantId}/members/${userId}`);
    toast('已移除', 'success');
    loadMembers();
  } catch (err) { toast('移除失败：' + err.message, 'error'); }
}

async function revokeInvite(id, target) {
  const ok = await askConfirmBox({
    dialogTitle: '撤销邀请',
    title: '确定撤销该邀请？',
    sub: target || '',
    notes: ['邀请链接 / 邀请记录将立即失效', '对方无法再通过该邀请加入本部门'],
    confirmText: '撤销邀请',
  });
  if (!ok) return;
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
            <td><strong>${escapeHtml(a.name)}</strong>${
              a.is_builtin
                ? ' <span class="badge badge-contributor">内置</span>'
                : ''
            }${a.disabled_in_tenant ? ' <span class="badge badge-viewer">本部门已停用</span>' : ''}</td>
            <td>${escapeHtml(a.description || '')}</td>
            <td>${escapeHtml(kbNames)}</td>
            <td class="row-actions">
              <button class="btn btn-sm btn-secondary" onclick="editAgent('${a.id}')">编辑</button>
              ${a.is_builtin ? '' : `<button class="btn btn-sm btn-secondary" onclick="showAgentAssignModal('${a.id}','${escapeHtml(a.name).replace(/'/g, "\\'")}')">分配到部门</button>`}
              <button class="btn btn-sm btn-danger" onclick="deleteAgent('${a.id}','${escapeHtml(a.name).replace(/'/g, "\\'")}')">删除</button>
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

async function deleteAgent(id, name) {
  const ok = await askConfirmBox({
    dialogTitle: '删除智能体',
    title: name ? `确定删除智能体「${name}」？` : '确定删除该智能体？',
    notes: ['该智能体及其配置将被删除', '已分享给其它部门的访问会同时失效，且不可恢复'],
    confirmText: '删除智能体',
  });
  if (!ok) return;
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

// ---------- 内置智能体按部门启停（仅系统管理员） ----------
// 状态由门户持久化的 data/builtin-agent-toggles.json 维护，
// 代理层会把本部门停用的条目标记 disabled_in_tenant，问答页自动不显示、也禁止向其提问。
async function loadBuiltinAgents() {
  const box = document.getElementById('builtin-agent-table');
  if (!box) return;
  const sel = document.getElementById('builtin-dept-select');
  const deptId = (sel && sel.value) || STATE.currentTenantId;
  if (!deptId) { box.innerHTML = '<div class="empty-tip">请先选择部门</div>'; return; }
  box.innerHTML = '加载中...';
  try {
    const resp = await api('GET', '/agents', null, { headers: { 'X-Tenant-ID': String(deptId) } });
    const agents = (resp.data || []).filter(a => a.is_builtin);
    if (agents.length === 0) {
      box.innerHTML = '<div class="empty-tip">该部门暂无内置智能体</div>';
      return;
    }
    box.innerHTML = `<table>
      <thead><tr><th>智能体</th><th>说明</th><th>本部门状态</th><th>操作</th></tr></thead>
      <tbody>
        ${agents.map(a => {
          const off = !!a.disabled_in_tenant;
          const id = escapeHtml(a.id);
          return `<tr>
            <td><strong>${escapeHtml(a.name)}</strong><div class="muted">${id}</div></td>
            <td>${escapeHtml(a.description || '系统内置智能体')}</td>
            <td>${off
              ? '<span class="badge badge-viewer">已禁用</span>'
              : '<span class="badge badge-active">已启用</span>'}</td>
            <td class="row-actions">
              <button class="btn btn-sm ${off ? 'btn-secondary' : 'btn-danger'}"
                      onclick="toggleBuiltinAgent('${id}', ${off ? 'true' : 'false'})">${off ? '启用' : '禁用'}</button>
            </td>
          </tr>`;
        }).join('')}
      </tbody>
    </table>`;
  } catch (err) {
    box.innerHTML = `<div class="empty-tip">加载失败：${err.message}</div>`;
  }
}

async function toggleBuiltinAgent(agentId, enable) {
  const sel = document.getElementById('builtin-dept-select');
  const deptId = (sel && sel.value) || STATE.currentTenantId;
  try {
    await api('POST', '/portal/builtin-agents', {
      tenant_id: String(deptId), agent_id: agentId, enabled: !!enable,
    });
    toast(enable ? '已在本部门启用该内置智能体' : '已在本部门禁用该内置智能体', 'success');
    await loadBuiltinAgents();
  } catch (err) { toast('操作失败：' + err.message, 'error'); }
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
                 <button class="btn btn-sm btn-danger" onclick="deleteKb('${k.id}','${escapeHtml(k.name).replace(/'/g, "\\'")}')">删除</button>`}
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

async function deleteKb(id, name) {
  const ok = await askConfirmBox({
    dialogTitle: '删除知识库',
    title: name ? `确定删除知识库「${name}」？` : '确定删除该知识库？',
    notes: ['库内所有文档及其解析分片、向量数据将一并删除', '引用了该库的智能体将不再能检索到这些内容，且不可恢复'],
    confirmText: '删除知识库',
  });
  if (!ok) return;
  try {
    await api('DELETE', `/knowledge-bases/${id}`);
    toast('已删除', 'success');
    loadKbs();
  } catch (err) { toast('删除失败：' + err.message, 'error'); }
}

let currentKbId = '';
async function openKbDetail(id, name) {
  currentKbId = id;
  STATE.docScope = '';
  STATE.selectedDocs = new Set();
  STATE.allDocs = [];
  STATE.docFolders = { folders: [], docs: {} };
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
    STATE.allDocs = resp.data || [];
    await loadDocFolders(kbId);
    renderFolderPane();
    renderDocTable();
    pruneDocFolders(STATE.allDocs.map(d => String(d.id)));
  } catch (err) {
    box.innerHTML = `<div class="empty-tip">加载失败：${err.message}</div>`;
  }
}

// ---------- 上传限制（仅系统管理员可改，取值受后端区间约束） ----------
async function loadUploadLimits() {
  try {
    const resp = await api('GET', '/portal/upload-limits');
    const d = resp.data || {};
    STATE.uploadLimits = { ...STATE.uploadLimits, ...(d.limits || {}) };
    if (d.ranges) STATE.uploadLimitRanges = d.ranges;
    if (d.labels) STATE.uploadLimitLabels = d.labels;
  } catch { /* 取不到时沿用前端默认值 */ }
  renderUploadLimitHint();
}

function renderUploadLimitHint() {
  const el = document.getElementById('upload-limit-hint');
  if (!el) return;
  const l = STATE.uploadLimits;
  el.textContent = `单次上传最多 ${l.max_files_per_upload} 个文件，单个文件不超过 ${l.max_file_size_mb} MB，合计不超过 ${l.max_total_size_mb} MB`;
}

function limitRange(key) { return STATE.uploadLimitRanges[key] || { min: 1, max: 999 }; }

function showUploadLimitModal() {
  if (!isSystemAdmin()) { toast('仅系统管理员可修改上传限制', 'warning'); return; }
  const l = STATE.uploadLimits;
  const field = (key, label, unit) => {
    const r = limitRange(key);
    return `<div class="form-group">
      <label>${label}（${unit}）</label>
      <input type="number" id="limit-${key}" value="${l[key]}" min="${r.min}" max="${r.max}" step="1" />
      <p class="form-hint">可设置范围：${r.min} ~ ${r.max}</p>
    </div>`;
  };
  openModal('上传限制设置', `
    <div class="scope-note">
      <span class="scope-note-icon">⚙️</span>
      <span>限制对所有部门的文档上传生效；超出区间的值无法保存，避免误配置导致上传不可用或资源被大文件占满。</span>
    </div>
    ${field('max_files_per_upload', '单次上传文件数量上限', '个')}
    ${field('max_file_size_mb', '单个文件大小上限', 'MB')}
    ${field('max_total_size_mb', '单次上传合计大小上限', 'MB')}
  `, async () => {
    const payload = {};
    for (const key of ['max_files_per_upload', 'max_file_size_mb', 'max_total_size_mb']) {
      const value = Number(document.getElementById('limit-' + key).value);
      const r = limitRange(key);
      if (!Number.isInteger(value) || value < r.min || value > r.max) {
        toast(`${STATE.uploadLimitLabels[key] || key}需在 ${r.min} ~ ${r.max} 之间`, 'warning');
        return false;
      }
      payload[key] = value;
    }
    if (payload.max_total_size_mb < payload.max_file_size_mb) {
      toast('单次上传合计上限不能小于单个文件大小上限', 'warning');
      return false;
    }
    try {
      const resp = await api('POST', '/portal/upload-limits', payload);
      STATE.uploadLimits = { ...STATE.uploadLimits, ...((resp.data || {}).limits || payload) };
      renderUploadLimitHint();
      toast('上传限制已更新', 'success');
      closeModal();
    } catch (err) { toast('保存失败：' + err.message, 'error'); return false; }
  });
}

function formatBytes(bytes) {
  if (bytes >= 1024 * 1024) return (bytes / 1024 / 1024).toFixed(1) + ' MB';
  if (bytes >= 1024) return (bytes / 1024).toFixed(1) + ' KB';
  return bytes + ' B';
}

// 上传前的本地校验（代理层还有一道同样的校验，防止绕过前端）
function validateUpload(files) {
  const l = STATE.uploadLimits;
  if (files.length > l.max_files_per_upload) {
    return `最多一次上传 ${l.max_files_per_upload} 个文件，当前选择了 ${files.length} 个`;
  }
  const tooBig = files.find(f => f.size > l.max_file_size_mb * 1024 * 1024);
  if (tooBig) {
    return `文件「${tooBig.name}」${formatBytes(tooBig.size)}，超过单文件上限 ${l.max_file_size_mb} MB`;
  }
  const total = files.reduce((s, f) => s + f.size, 0);
  if (total > l.max_total_size_mb * 1024 * 1024) {
    return `本次合计 ${formatBytes(total)}，超过单次上传上限 ${l.max_total_size_mb} MB`;
  }
  return '';
}

async function postUploadFiles(files) {
  // 分批提交：单个请求过大容易超时，也让进度提示更清楚
  const CHUNK = 20;
  for (let i = 0; i < files.length; i += CHUNK) {
    const form = new FormData();
    for (const f of files.slice(i, i + CHUNK)) form.append('file', f);
    const resp = await fetch(`${API_BASE}/knowledge-bases/${currentKbId}/knowledge/file`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${STATE.token}`, 'X-Tenant-ID': STATE.currentTenantId },
      body: form,
    });
    if (!resp.ok) {
      let msg = `HTTP ${resp.status}`;
      try {
        const j = await resp.json();
        msg = (j.error && j.error.message) || j.message || msg;
      } catch { /* 非 JSON 错误体时用状态码兜底 */ }
      throw new Error(msg);
    }
  }
}

// 上传后把文档归入对应文件夹（按文件名匹配新出现的文档）
async function assignDocsToFolders(files, pathOf) {
  const paths = [...new Set(files.map(pathOf).filter(Boolean))];
  if (!paths.length) { renderFolderPane(); renderDocTable(); return; }
  let mapping = {};
  try {
    const resp = await api('POST', '/portal/doc-folders', { kb_id: currentKbId, action: 'ensure_paths', paths });
    mapping = (resp.data || {}).paths || {};
  } catch (err) {
    toast('自动创建文件夹失败：' + err.message, 'error');
    return;
  }
  const docs = STATE.docFolders.docs || {};
  const taken = new Set();
  const groups = {};
  for (const f of files) {
    const folderId = mapping[pathOf(f)];
    if (!folderId) continue;
    const doc = STATE.allDocs.find(d => !taken.has(String(d.id)) && !(String(d.id) in docs) && docName(d) === f.name)
      || STATE.allDocs.find(d => !taken.has(String(d.id)) && docName(d) === f.name);
    if (!doc) continue;
    taken.add(String(doc.id));
    if (!groups[folderId]) groups[folderId] = [];
    groups[folderId].push(String(doc.id));
  }
  for (const folderId of Object.keys(groups)) {
    try {
      await writeDocFolders({ action: 'move_docs', doc_ids: groups[folderId], folder_id: folderId });
    } catch (err) { toast('归入文件夹失败：' + err.message, 'error'); }
  }
  renderFolderPane();
  renderDocTable();
}

async function uploadDocuments(input) {
  const files = Array.from(input.files || []);
  input.value = '';
  if (!files.length || !currentKbId) return;
  const err = validateUpload(files);
  if (err) { toast(err, 'error'); return; }
  toast(`正在上传 ${files.length} 个文件...`, 'info');
  try {
    await postUploadFiles(files);
    toast('上传成功，正在后台解析', 'success');
  } catch (err) {
    toast('上传失败：' + err.message, 'error');
  }
  await loadDocuments(currentKbId);
}

// 整文件夹上传：按浏览器给出的相对路径自动建立同名文件夹并把文档归入其中
async function uploadFolder(input) {
  const files = Array.from(input.files || []);
  input.value = '';
  if (!files.length || !currentKbId) return;
  const pathOf = (f) => {
    const rel = String(f.webkitRelativePath || '').replace(/\\/g, '/');
    const idx = rel.lastIndexOf('/');
    return idx > 0 ? rel.slice(0, idx) : '';
  };
  const err = validateUpload(files);
  if (err) { toast(err, 'error'); return; }
  toast(`正在上传文件夹内 ${files.length} 个文件...`, 'info');
  try {
    await postUploadFiles(files);
    toast('上传成功，正在后台解析', 'success');
  } catch (err) {
    toast('上传失败：' + err.message, 'error');
  }
  await loadDocuments(currentKbId);
  await assignDocsToFolders(files, pathOf);
}

// ---------- 文档文件夹 ----------
async function loadDocFolders(kbId) {
  try {
    const resp = await api('GET', `/portal/doc-folders?kb_id=${encodeURIComponent(kbId)}`);
    const d = resp.data || {};
    STATE.docFolders = { folders: d.folders || [], docs: d.docs || {} };
  } catch { STATE.docFolders = { folders: [], docs: {} }; }
}

async function writeDocFolders(payload) {
  const resp = await api('POST', '/portal/doc-folders', { kb_id: currentKbId, ...payload });
  const d = resp.data || {};
  if (d.folders) STATE.docFolders = { folders: d.folders, docs: d.docs || {} };
  return d;
}

// 清理已删除文档留下的归属记录
async function pruneDocFolders(docIds) {
  try { await writeDocFolders({ action: 'prune', doc_ids: docIds }); } catch { /* 无权限时忽略 */ }
}

function docName(d) { return d.file_name || d.name || ''; }
function folderById(id) { return (STATE.docFolders.folders || []).find(f => f.id === id); }
function folderPathText(id) {
  const f = folderById(id);
  return f ? (f.path || f.name) : '';
}
// 「+ 新建文件夹」默认建在当前文件夹下；在「全部 / 未分类」视图时建到根目录
function currentFolderId() { return STATE.docScope === ROOT_FOLDER ? '' : STATE.docScope; }

function visibleDocs() {
  const docs = STATE.docFolders.docs || {};
  const scope = STATE.docScope;
  if (scope === '') return STATE.allDocs;
  const target = scope === ROOT_FOLDER ? '' : scope;
  return STATE.allDocs.filter(d => (docs[String(d.id)] || '') === target);
}

function renderFolderPane() {
  const box = document.getElementById('folder-tree');
  if (!box) return;
  const folders = STATE.docFolders.folders || [];
  const docs = STATE.docFolders.docs || {};
  const countOf = (folderId) => STATE.allDocs.filter(d => (docs[String(d.id)] || '') === folderId).length;
  const node = (f, depth) => {
    const children = folders.filter(x => (x.parent_id || '') === f.id);
    return `<div class="folder-item ${STATE.docScope === f.id ? 'active' : ''}"
                 style="padding-left:${10 + depth * 14}px" onclick="selectFolder('${f.id}')">
      <span class="folder-icon">📁</span>
      <span class="folder-name" title="${escapeHtml(f.path || f.name)}">${escapeHtml(f.name)}</span>
      <span class="folder-count">${countOf(f.id)}</span>
      <span class="folder-ops">
        <button class="icon-btn" title="新建子文件夹" onclick="event.stopPropagation();showCreateFolderModal('${f.id}')">＋</button>
        <button class="icon-btn" title="重命名" onclick="event.stopPropagation();renameFolder('${f.id}')">✎</button>
        <button class="icon-btn" title="删除文件夹" onclick="event.stopPropagation();deleteFolder('${f.id}')">🗑</button>
      </span>
    </div>` + children.map(c => node(c, depth + 1)).join('');
  };
  box.innerHTML = `
    <div class="folder-item ${STATE.docScope === '' ? 'active' : ''}" onclick="selectFolder('')">
      <span class="folder-icon">🗂</span>
      <span class="folder-name">全部文档</span>
      <span class="folder-count">${STATE.allDocs.length}</span>
    </div>
    <div class="folder-item ${STATE.docScope === ROOT_FOLDER ? 'active' : ''}" onclick="selectFolder('${ROOT_FOLDER}')">
      <span class="folder-icon">📄</span>
      <span class="folder-name">未分类</span>
      <span class="folder-count">${countOf('')}</span>
    </div>
    ${folders.filter(f => !f.parent_id).map(f => node(f, 0)).join('')}
  `;
}

function selectFolder(id) {
  STATE.docScope = id || '';
  STATE.selectedDocs = new Set();
  renderFolderPane();
  renderDocTable();
}

function folderOptionHtml(selected) {
  const folders = STATE.docFolders.folders || [];
  const walk = (parent, depth) => folders.filter(f => (f.parent_id || '') === parent).map(f =>
    `<option value="${f.id}" ${f.id === selected ? 'selected' : ''}>${'　'.repeat(depth)}${escapeHtml(f.path || f.name)}</option>`
    + walk(f.id, depth + 1)).join('');
  return `<option value="${ROOT_FOLDER}" ${selected === ROOT_FOLDER ? 'selected' : ''}>未分类（根目录）</option>` + walk('', 0);
}

function showCreateFolderModal(parentId) {
  openModal('新建文件夹', `
    <div class="form-group">
      <label>文件夹名称</label>
      <input id="folder-name" placeholder="如：作业标准" />
      <p class="form-hint">${parentId ? '将创建在所选文件夹下' : '将创建在根目录'}</p>
    </div>
  `, async () => {
    const name = document.getElementById('folder-name').value.trim();
    if (!name) { toast('请输入文件夹名称', 'warning'); return false; }
    try {
      await writeDocFolders({ action: 'create', name, parent_id: parentId === ROOT_FOLDER ? '' : (parentId || '') });
      toast('文件夹已创建', 'success');
      closeModal();
      renderFolderPane();
    } catch (err) { toast('创建失败：' + err.message, 'error'); return false; }
  });
}

function renameFolder(id) {
  const f = folderById(id);
  if (!f) return;
  openModal('重命名文件夹', `
    <div class="form-group">
      <label>文件夹名称</label>
      <input id="folder-name" value="${escapeHtml(f.name)}" />
    </div>
  `, async () => {
    const name = document.getElementById('folder-name').value.trim();
    if (!name) { toast('请输入文件夹名称', 'warning'); return false; }
    try {
      await writeDocFolders({ action: 'rename', id, name });
      toast('已重命名', 'success');
      closeModal();
      renderFolderPane();
      renderDocTable();
    } catch (err) { toast('重命名失败：' + err.message, 'error'); return false; }
  });
}

async function deleteFolder(id) {
  const f = folderById(id);
  if (!f) return;
  const ok = await askConfirmBox({
    dialogTitle: '删除文件夹',
    title: `确定删除文件夹「${f.path || f.name}」及其子文件夹？`,
    notes: ['文件夹内的文档会保留，并移动到「未分类」'],
    confirmText: '删除文件夹',
  });
  if (!ok) return;
  try {
    await writeDocFolders({ action: 'delete', id });
    if (STATE.docScope === id) STATE.docScope = '';
    toast('文件夹已删除', 'success');
    renderFolderPane();
    renderDocTable();
  } catch (err) { toast('删除失败：' + err.message, 'error'); }
}

function toggleDocSelect(id, checked) {
  if (checked) STATE.selectedDocs.add(String(id));
  else STATE.selectedDocs.delete(String(id));
  renderDocTable();
}

function toggleSelectAll(checked) {
  const ids = visibleDocs().map(d => String(d.id));
  if (checked) ids.forEach(id => STATE.selectedDocs.add(id));
  else ids.forEach(id => STATE.selectedDocs.delete(id));
  renderDocTable();
}

async function moveSelectedDocs() {
  const ids = Array.from(STATE.selectedDocs);
  if (!ids.length) { toast('请先勾选要移动的文档', 'warning'); return; }
  showMoveDocsModal(ids);
}

function moveDoc(id) { showMoveDocsModal([String(id)]); }

function showMoveDocsModal(ids) {
  openModal(`移动 ${ids.length} 个文档`, `
    <div class="form-group">
      <label>目标文件夹</label>
      <select id="move-target">${folderOptionHtml('')}</select>
      <p class="form-hint">选择「未分类」即把文档移出文件夹</p>
    </div>
  `, async () => {
    const target = document.getElementById('move-target').value;
    try {
      await writeDocFolders({
        action: 'move_docs',
        doc_ids: ids.map(String),
        folder_id: target === ROOT_FOLDER ? '' : target,
      });
      toast(`已移动 ${ids.length} 个文档`, 'success');
      STATE.selectedDocs = new Set();
      closeModal();
      renderFolderPane();
      renderDocTable();
    } catch (err) { toast('移动失败：' + err.message, 'error'); return false; }
  });
}

function renderDocTable() {
  const box = document.getElementById('doc-table');
  if (!box) return;
  const docs = STATE.docFolders.docs || {};
  const list = visibleDocs();

  const label = document.getElementById('doc-scope-label');
  if (label) {
    label.textContent = STATE.docScope === '' ? '全部文档'
      : (STATE.docScope === ROOT_FOLDER ? '未分类' : (folderPathText(STATE.docScope) || '文件夹'));
  }
  const countEl = document.getElementById('doc-selected-count');
  if (countEl) countEl.textContent = STATE.selectedDocs.size ? `已选 ${STATE.selectedDocs.size} 个` : '';
  const moveBtn = document.getElementById('btn-move-docs');
  if (moveBtn) moveBtn.disabled = STATE.selectedDocs.size === 0;

  if (list.length === 0) {
    box.innerHTML = `<div class="empty-tip">${STATE.allDocs.length ? '该文件夹下暂无文档' : '暂无文档，请上传'}
      <span class="empty-tip-sub">支持上传单个 / 多个文档，或整文件夹上传</span></div>`;
    return;
  }
  const allChecked = list.every(d => STATE.selectedDocs.has(String(d.id)));
  box.innerHTML = `<table>
    <thead><tr>
      <th class="col-check"><input type="checkbox" ${allChecked ? 'checked' : ''} onchange="toggleSelectAll(this.checked)" title="全选本页" /></th>
      <th>文件名</th><th>所在文件夹</th><th>状态</th><th>分片数</th><th>操作</th>
    </tr></thead>
    <tbody>
      ${list.map(d => {
        const id = String(d.id);
        const folderId = docs[id] || '';
        return `<tr>
          <td class="col-check"><input type="checkbox" ${STATE.selectedDocs.has(id) ? 'checked' : ''} onchange="toggleDocSelect('${id}', this.checked)" /></td>
          <td>${escapeHtml(docName(d))}</td>
          <td>${folderId
            ? `<span class="folder-tag">📁 ${escapeHtml(folderPathText(folderId) || '未知文件夹')}</span>`
            : '<span class="muted">未分类</span>'}</td>
          <td><span class="badge ${d.parse_status === 'completed' ? 'badge-active' : 'badge-pending'}">${d.parse_status || '-'}</span></td>
          <td>${d.chunk_count ?? '-'}</td>
          <td class="row-actions">
            ${d.parse_status !== 'completed' ? `<button class="btn btn-sm btn-secondary" onclick="reparseDoc('${d.id}')">重解析</button>` : ''}
            <button class="btn btn-sm btn-secondary" onclick="moveDoc('${d.id}')">移动到</button>
            <button class="btn btn-sm btn-danger" onclick="deleteDoc('${d.id}','${escapeHtml(d.file_name || d.name || '').replace(/'/g, "\\'")}')">删除</button>
          </td>
        </tr>`;
      }).join('')}
    </tbody>
  </table>`;
}

async function reparseDoc(id) {
  try {
    await api('POST', `/knowledge/${id}/reparse`, {});
    toast('已提交重解析', 'success');
    loadDocuments(currentKbId);
  } catch (err) { toast('操作失败：' + err.message, 'error'); }
}

async function deleteDoc(id, name) {
  const ok = await askConfirmBox({
    dialogTitle: '删除文档',
    title: name ? `确定删除文档「${name}」？` : '确定删除该文档？',
    notes: ['文档及其解析分片将从知识库中移除', '删除后需要重新上传并重新解析，且不可恢复'],
    confirmText: '删除文档',
  });
  if (!ok) return;
  try {
    await api('DELETE', `/knowledge/${id}`);
    STATE.selectedDocs.delete(String(id));
    toast('已删除', 'success');
    await loadDocuments(currentKbId);
  } catch (err) { toast('删除失败：' + err.message, 'error'); }
}

// ---------- 平台管理：全员对话 / 文档上传记录（仅系统管理员） ----------
const AUDIT_PAGE_SIZE = 20;
// 两个页面的筛选翻页状态（切出再切回时保留）
const AUDIT_STATE = {
  conv: { page: 1, total: 0, userId: '', userName: '' },
  upload: { page: 1, total: 0, userId: '', userName: '' },
};
let auditSearchTimer = null;

// 表格里的 onclick 参数：名字可能带引号，转义后再拼进 JS 字符串字面量
function jsStr(s) {
  return escapeHtml(s == null ? '' : String(s)).replace(/\\/g, '\\\\').replace(/'/g, "\\'");
}

function onAuditSearch(kind) {
  clearTimeout(auditSearchTimer);
  auditSearchTimer = setTimeout(() => {
    if (kind === 'conv') loadConversations(1);
    else loadUploadRecords(1);
  }, 300);
}

// 把「只看该成员」做成可撤销的筛选项
function setAuditUserFilter(kind, userId, userName) {
  const st = AUDIT_STATE[kind];
  st.userId = userId || '';
  st.userName = userId ? (userName || '未知用户') : '';
  const el = document.getElementById(`${kind}-user-filter`);
  if (el) {
    el.innerHTML = st.userId
      ? `<span class="filter-chip">只看该成员：${escapeHtml(st.userName)}<button class="icon-btn" title="取消筛选" onclick="setAuditUserFilter('${kind}','')">✕</button></span>`
      : '';
  }
  // 返回 Promise 便于调用方等待刷新完成
  if (kind === 'conv') return loadConversations(1);
  return loadUploadRecords(1);
}

function auditParams(kind, page) {
  const st = AUDIT_STATE[kind];
  const params = new URLSearchParams({
    page: String(page),
    page_size: String(AUDIT_PAGE_SIZE),
    tenant_id: (document.getElementById(`${kind}-dept-select`) || {}).value || '',
  });
  const kw = ((document.getElementById(`${kind}-keyword`) || {}).value || '').trim();
  if (kw) params.set('keyword', kw);
  if (st.userId) params.set('user_id', st.userId);
  return params;
}

function renderAuditStats(elId, parts) {
  const el = document.getElementById(elId);
  if (!el) return;
  el.innerHTML = parts.map(([label, value]) => `${label} <strong>${value}</strong>`).join('　·　');
}

function renderAuditPager(elId, page, total, fnName) {
  const el = document.getElementById(elId);
  if (!el) return;
  if (!total) { el.innerHTML = ''; return; }
  const pages = Math.max(1, Math.ceil(total / AUDIT_PAGE_SIZE));
  el.innerHTML = `
    <button class="btn btn-sm btn-ghost" ${page <= 1 ? 'disabled' : ''} onclick="${fnName}(${page - 1})">上一页</button>
    <span class="pager-info">第 ${page} / ${pages} 页 · 共 ${total} 条</span>
    <button class="btn btn-sm btn-ghost" ${page >= pages ? 'disabled' : ''} onclick="${fnName}(${page + 1})">下一页</button>`;
}

// ---------- 全员对话 ----------
async function loadConversations(page = 1) {
  const box = document.getElementById('conv-table');
  if (!box || !isSystemAdmin()) return;
  const st = AUDIT_STATE.conv;
  st.page = page;
  box.innerHTML = '<div class="empty-tip">加载中...</div>';
  document.getElementById('conv-pager').innerHTML = '';
  try {
    const resp = await api('GET', `/portal/admin/conversations?${auditParams('conv', page).toString()}`);
    const d = resp.data || {};
    const items = d.items || [];
    st.total = d.total || 0;
    renderConversationRows(items);
    renderAuditStats('conv-stats', [
      ['会话', st.total],
      ['成员', (d.stats || {}).users ?? '-'],
      ['部门', (d.stats || {}).tenants ?? '-'],
    ]);
    renderAuditPager('conv-pager', page, st.total, 'loadConversations');
  } catch (err) {
    box.innerHTML = `<div class="empty-tip">加载失败：${escapeHtml(err.message)}</div>`;
  }
}

function renderConversationRows(items) {
  const box = document.getElementById('conv-table');
  if (!items.length) {
    box.innerHTML = '<div class="empty-tip">暂无会话<span class="empty-tip-sub">调整部门或关键词后再试</span></div>';
    return;
  }
  box.innerHTML = `<table>
    <thead><tr><th>会话标题</th><th>成员</th><th>部门</th><th>消息</th><th>最近更新</th><th>操作</th></tr></thead>
    <tbody>
      ${items.map(s => `<tr>
        <td><strong>${escapeHtml(s.title)}</strong></td>
        <td>${escapeHtml(s.user_name)}<div class="muted">${escapeHtml(s.user_email)}</div></td>
        <td>${escapeHtml(s.tenant_name)}</td>
        <td>${s.message_count ?? '-'}</td>
        <td>${escapeHtml(formatTime(s.updated_at || s.created_at))}</td>
        <td class="row-actions">
          <button class="btn btn-sm btn-secondary" onclick="openConversationAudit('${s.id}')">查看对话</button>
          ${s.user_id ? `<button class="btn btn-sm btn-ghost" onclick="setAuditUserFilter('conv','${jsStr(s.user_id)}','${jsStr(s.user_name)}')">只看该成员</button>` : ''}
          <button class="btn btn-sm btn-danger" onclick="deleteConversationAudit('${s.id}','${jsStr(s.title)}')">删除</button>
        </td>
      </tr>`).join('')}
    </tbody>
  </table>`;
}

async function openConversationAudit(sessionId) {
  openModal('会话详情', '<div class="empty-tip">加载中...</div>', null, { size: 'lg' });
  let data;
  try {
    data = (await api('GET', `/portal/admin/conversations/${sessionId}/messages`)).data || {};
  } catch (err) {
    openModal('会话详情', `<div class="empty-tip">加载失败：${escapeHtml(err.message)}</div>`,
      () => closeModal(), { confirmText: '关闭', size: 'lg' });
    return;
  }
  const s = data.session || {};
  const msgs = data.messages || [];
  const body = `
    <div class="audit-head">
      <p class="audit-head-title">${escapeHtml(s.title || '未命名会话')}</p>
      <p class="form-hint">${escapeHtml(s.user_name || '未知用户')}${s.user_email ? ' · ' + escapeHtml(s.user_email) : ''}
        · ${escapeHtml(s.tenant_name || '')} · 创建于 ${escapeHtml(formatTime(s.created_at))} · 共 ${msgs.length} 条消息</p>
    </div>
    <div class="history-messages">
      ${msgs.length === 0
        ? '<div class="empty-tip">该会话暂无消息</div>'
        : msgs.map(m => renderAuditMessage(m, s)).join('')}
    </div>`;
  openModal('会话详情', body, () => deleteConversationAudit(sessionId, s.title || '未命名会话'),
    { danger: true, confirmText: '删除会话', size: 'lg' });
}

function renderAuditMessage(m, session) {
  const time = escapeHtml(formatTime(m.created_at));
  const body = escapeHtml(m.content || '')
    + (m.truncated ? '<span class="muted"> …（内容过长已截断）</span>' : '');
  const refs = (m.knowledge_references || [])
    .map(r => r.file_name || r.title || r.source || '').filter(Boolean);
  const citations = refs.length
    ? `<div class="msg-citations"><span class="cite-label">引用来源</span>${
      refs.map(c => `<span class="cite-chip" title="${escapeHtml(c)}">${escapeHtml(c)}</span>`).join('')}</div>`
    : '';
  if (m.role === 'user') {
    const initial = escapeHtml(((session || {}).user_name || '用').trim().charAt(0).toUpperCase());
    return `<div class="msg msg-user">
      <div class="msg-avatar msg-avatar-user">${initial}</div>
      <div class="msg-body">
        <div class="msg-bubble">${body}</div>
        <span class="history-msg-time">${time}</span>
      </div>
    </div>`;
  }
  return `<div class="msg msg-bot">
    <div class="msg-avatar msg-avatar-bot">AI</div>
    <div class="msg-body">
      <div class="msg-bubble">${body}</div>
      ${citations}
      <span class="history-msg-time">${time}</span>
    </div>
  </div>`;
}

async function deleteConversationAudit(sessionId, title) {
  const ok = await askConfirmBox({
    dialogTitle: '删除会话',
    title: `确定删除会话「${title || '未命名会话'}」？`,
    sub: '该会话属于其它成员，删除后其本人也看不到这段对话',
    notes: ['会话的全部消息将一并删除', '删除后不可恢复'],
    confirmText: '删除会话',
  });
  if (!ok) return;
  try {
    await api('POST', '/portal/admin/conversations', { action: 'delete', session_id: sessionId });
    toast('会话已删除', 'success');
    closeModal();
    await loadConversations(AUDIT_STATE.conv.page);
  } catch (err) {
    toast('删除失败：' + err.message, 'error');
  }
}

// ---------- 文档上传记录 ----------
async function loadUploadRecords(page = 1) {
  const box = document.getElementById('upload-table');
  if (!box || !isSystemAdmin()) return;
  const st = AUDIT_STATE.upload;
  st.page = page;
  box.innerHTML = '<div class="empty-tip">加载中...</div>';
  document.getElementById('upload-pager').innerHTML = '';
  try {
    const resp = await api('GET', `/portal/admin/uploads?${auditParams('upload', page).toString()}`);
    const d = resp.data || {};
    const items = d.items || [];
    st.total = d.total || 0;
    renderUploadRows(items);
    const totalSize = Number((d.stats || {}).total_size || 0);
    renderAuditStats('upload-stats', [
      ['上传记录', st.total],
      ['上传人', (d.stats || {}).uploaders ?? '-'],
      ['占用', totalSize ? formatBytes(totalSize) : '0 B'],
    ]);
    renderAuditPager('upload-pager', page, st.total, 'loadUploadRecords');
  } catch (err) {
    box.innerHTML = `<div class="empty-tip">加载失败：${escapeHtml(err.message)}</div>`;
  }
}

function uploadStatusBadge(r) {
  if (r.removed) return '<span class="badge badge-viewer">记录已失效</span>';
  if (r.deleted) return '<span class="badge badge-viewer">已删除</span>';
  return r.parse_status === 'completed'
    ? '<span class="badge badge-active">解析完成</span>'
    : `<span class="badge badge-pending">${escapeHtml(r.parse_status || '未知状态')}</span>`;
}

function renderUploadRows(items) {
  const box = document.getElementById('upload-table');
  if (!items.length) {
    box.innerHTML = '<div class="empty-tip">暂无上传记录<span class="empty-tip-sub">成员上传文档后会自动出现在这里</span></div>';
    return;
  }
  box.innerHTML = `<table>
    <thead><tr><th>文件</th><th>上传人</th><th>部门</th><th>知识库</th><th>大小</th><th>状态</th><th>上传时间</th><th>操作</th></tr></thead>
    <tbody>
      ${items.map(r => `<tr>
        <td><strong>${escapeHtml(r.file_name || '未知文件')}</strong>${
          r.file_type ? `<span class="badge badge-contributor">${escapeHtml(r.file_type)}</span>` : ''}</td>
        <td>${escapeHtml(r.user_name)}${r.user_role ? ` ${getRoleBadge(r.user_role)}` : ''}
          <div class="muted">${escapeHtml(r.user_email)}</div></td>
        <td>${escapeHtml(r.tenant_name)}</td>
        <td>${escapeHtml(r.kb_name) || '<span class="muted">-</span>'}</td>
        <td>${r.file_size ? formatBytes(Number(r.file_size)) : '-'}</td>
        <td>${uploadStatusBadge(r)}</td>
        <td>${escapeHtml(formatTime(r.created_at))}</td>
        <td class="row-actions">
          ${r.user_id ? `<button class="btn btn-sm btn-ghost" onclick="setAuditUserFilter('upload','${jsStr(r.user_id)}','${jsStr(r.user_name)}')">只看该成员</button>` : ''}
          ${(!r.removed && !r.deleted && r.parse_status !== 'completed')
            ? `<button class="btn btn-sm btn-secondary" onclick="reparseDocAsAdmin('${r.knowledge_id}','${r.tenant_id}')">重解析</button>` : ''}
          ${(r.removed || r.deleted)
            ? '<span class="muted">已不存在</span>'
            : `<button class="btn btn-sm btn-danger" onclick="deleteDocAsAdmin('${r.knowledge_id}','${jsStr(r.file_name)}','${r.tenant_id}')">删除文档</button>`}
        </td>
      </tr>`).join('')}
    </tbody>
  </table>`;
}

// 管理他人上传的文档：以该文档所属部门的权限调用原生接口（超管在其中具备 Admin）
async function deleteDocAsAdmin(docId, name, tenantId) {
  const ok = await askConfirmBox({
    dialogTitle: '删除文档',
    title: `确定删除文档「${name || '未知文件'}」？`,
    notes: ['文档及其解析分片将从所属部门的知识库中移除', '删除后需要重新上传并重新解析，且不可恢复'],
    confirmText: '删除文档',
  });
  if (!ok) return;
  try {
    await api('DELETE', `/knowledge/${docId}`, null, { headers: { 'X-Tenant-ID': String(tenantId) } });
    toast('删除任务已提交，稍后生效', 'success');
    await loadUploadRecords(AUDIT_STATE.upload.page);
  } catch (err) {
    toast('删除失败：' + err.message, 'error');
  }
}

async function reparseDocAsAdmin(docId, tenantId) {
  try {
    await api('POST', `/knowledge/${docId}/reparse`, {}, { headers: { 'X-Tenant-ID': String(tenantId) } });
    toast('已提交重解析，稍后可在列表中查看状态', 'success');
    await loadUploadRecords(AUDIT_STATE.upload.page);
  } catch (err) {
    toast('重解析失败：' + err.message, 'error');
  }
}

// ---------- 弹窗通用 ----------
let modalConfirmCb = null;
let modalCloseCb = null;   // 弹窗被关闭时的回调（用于把确认框 Promise 化）
function openModal(title, bodyHtml, onConfirm, opts) {
  const o = opts || {};
  const modal = document.querySelector('#modal-overlay .modal');
  const sizeCls = o.size === 'sm' ? ' modal-sm' : (o.size === 'lg' ? ' modal-lg' : '');
  modal.className = 'modal' + sizeCls;
  document.getElementById('modal-title').textContent = title;
  document.getElementById('modal-body').innerHTML = bodyHtml;
  modalConfirmCb = onConfirm;
  const confirmBtn = document.getElementById('modal-confirm');
  const cancelBtn = document.getElementById('modal-cancel');
  confirmBtn.textContent = o.confirmText || '确认';
  confirmBtn.className = 'btn ' + (o.danger ? 'btn-danger' : 'btn-primary');
  cancelBtn.textContent = o.cancelText || '取消';
  // 部分弹窗（如「分配到部门」）由内部按钮完成操作，无需右下角确认按钮
  confirmBtn.classList.toggle('hidden', !onConfirm);
  document.getElementById('modal-overlay').classList.remove('hidden');
}
function closeModal(e) {
  if (e && e.target.id !== 'modal-overlay') return;
  document.getElementById('modal-overlay').classList.add('hidden');
  modalConfirmCb = null;
  const cb = modalCloseCb; modalCloseCb = null;
  if (cb) cb(false);
}

// 用统一的居中弹窗替代浏览器原生 confirm（原生 confirm 贴在窗口顶部，样式也无法定制）
function askConfirm(opts) {
  return new Promise(resolve => {
    let settled = false;
    const settle = (val) => {
      if (settled) return;
      settled = true;
      modalCloseCb = null;
      closeModal();
      resolve(val);
    };
    modalCloseCb = () => settle(false);
    openModal(opts.title, opts.bodyHtml, () => settle(true), {
      confirmText: opts.confirmText,
      cancelText: opts.cancelText,
      danger: !!opts.danger,
      size: opts.size || 'sm',
    });
  });
}

// ============================================================
// 全站统一的两类弹窗：确认框（confirm）与结果 / 可复制内容框（result）
// 所有危险操作、提示类弹窗都走这两个函数，保证式样一致
// ============================================================
const MODAL_ICONS = {
  danger: '<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 6h18"/><path d="M8 6V4h8v2"/><path d="M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6"/><path d="M10 11v6"/><path d="M14 11v6"/></svg>',
  warning: '<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0Z"/><path d="M12 9v4"/><path d="M12 17h.01"/></svg>',
  info: '<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9"/><path d="M12 16v-4"/><path d="M12 8h.01"/></svg>',
  success: '<svg viewBox="0 0 24 24" width="24" height="24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M20 6 9 17l-5-5"/></svg>',
  link: '<svg viewBox="0 0 24 24" width="24" height="24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M10 13a5 5 0 0 0 7.5.5l3-3a5 5 0 0 0-7-7l-1.5 1.5"/><path d="M14 11a5 5 0 0 0-7.5-.5l-3 3a5 5 0 0 0 7 7l1.5-1.5"/></svg>',
};
function safeText(s) { return escapeHtml(s == null ? '' : String(s)); }

// 确认框正文：圆形图标 + 主标题 + 副标题 + 说明要点
function confirmBodyHtml(o) {
  const tone = o.tone || 'warning';
  return `
    <div class="confirm-box">
      <span class="confirm-icon confirm-icon-${tone}">${MODAL_ICONS[tone] || MODAL_ICONS.warning}</span>
      <div class="confirm-copy">
        <p class="confirm-title">${safeText(o.title)}</p>
        ${o.sub ? `<p class="confirm-sub">${safeText(o.sub)}</p>` : ''}
      </div>
    </div>
    ${(o.notes && o.notes.length)
      ? `<ul class="confirm-notes">${o.notes.map(n => `<li>${safeText(n)}</li>`).join('')}</ul>`
      : ''}`;
}

// 统一的确认弹窗：danger=true（默认）时确认按钮为红色
function askConfirmBox(opts) {
  const danger = opts.danger !== false;
  return askConfirm({
    title: opts.dialogTitle || '操作确认',
    danger,
    confirmText: opts.confirmText || '确认',
    cancelText: opts.cancelText || '取消',
    bodyHtml: confirmBodyHtml({
      tone: opts.tone || (danger ? 'danger' : 'info'),
      title: opts.title, sub: opts.sub, notes: opts.notes,
    }),
  });
}

// 结果 / 可复制内容弹窗正文（重置密码结果、邀请链接、手动复制兜底等）
function resultBodyHtml(o) {
  const tone = o.tone || 'success';
  return `
    <div class="result-box">
      <span class="result-icon result-icon-${tone}">${MODAL_ICONS[tone] || MODAL_ICONS.success}</span>
      <p class="result-title">${safeText(o.title)}</p>
      ${o.sub ? `<p class="result-sub">${safeText(o.sub)}</p>` : ''}
      <div class="copy-box">
        <code id="result-copy-box">${safeText(o.code)}</code>
        <button class="btn btn-sm btn-secondary" onclick="copyText(document.getElementById('result-copy-box').textContent)">复制</button>
      </div>
      ${o.hint ? `<p class="form-hint">${safeText(o.hint)}</p>` : ''}
    </div>`;
}
function openResultModal(opts) {
  openModal(opts.dialogTitle, resultBodyHtml(opts), opts.onConfirm || (() => closeModal()), {
    confirmText: opts.confirmText || '关闭',
    size: opts.size || 'sm',
  });
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
