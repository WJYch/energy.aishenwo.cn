#!/bin/bash
# ============================================================
# ECS API 转发服务 v2 - 一键部署（含 API Key 管理后台）
# 在阿里云 ECS (121.40.44.152) 上执行
# ============================================================
# 使用方式：
#   curl -o /tmp/deploy.sh https://energy.aishenwo.cn/tools/ecs_api_deploy.sh
#   bash /tmp/deploy.sh
# 然后访问 http://121.40.44.152/admin/ 管理 API Key
# ============================================================

set -e

echo "=========================================="
echo "电小团 API 转发服务 v2 部署"
echo "含 API Key 管理后台"
echo "=========================================="

# 1. 安装 Python 依赖
echo "[1/6] 安装 Python 环境..."
if ! command -v python3 &> /dev/null; then
    apt-get update && apt-get install -y python3 python3-pip
fi
pip3 install flask gunicorn requests --break-system-packages --user 2>/dev/null || PIP_REQUIRE_VIRTUALENV=false pip3 install flask gunicorn requests --break-system-packages --user

# 2. 创建服务程序
echo "[2/6] 创建 API 服务..."
mkdir -p /opt/dxt-api
cat > /opt/dxt-api/app.py << 'PYEOF'
import os, json, hashlib, secrets, sqlite3, time, datetime
from flask import Flask, request, jsonify, render_template_string
from functools import wraps

app = Flask(__name__)

# ========== 配置 ==========
# 管理员密码（用于登录后台管理页）
ADMIN_PASSWORD = os.environ.get("ADMIN_PASSWORD", "admin123456")
# DeepSeek API
DEEPSEEK_API_KEY = os.environ.get("DEEPSEEK_API_KEY", "")
DEEPSEEK_API_URL = "https://api.deepseek.com/v1/chat/completions"
# UGREEN 模型（二选一）
UGREEN_API_KEY = os.environ.get("UGREEN_API_KEY", "")
UGREEN_API_URL = "http://code.ugreencloud.com:8000/v1/chat/completions"
# ==========================

DB_PATH = "/opt/dxt-api/keys.db"

def get_db():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn

def init_db():
    conn = get_db()
    conn.execute("""
        CREATE TABLE IF NOT EXISTS api_keys (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            key TEXT UNIQUE NOT NULL,
            name TEXT DEFAULT '',
            type TEXT NOT NULL DEFAULT 'trial',    -- trial / monthly / custom
            status TEXT NOT NULL DEFAULT 'active',  -- active / expired / disabled
            max_uses INTEGER DEFAULT 1,             -- -1 = unlimited
            used_count INTEGER DEFAULT 0,
            created_at TEXT DEFAULT (datetime('now','localtime')),
            expires_at TEXT DEFAULT NULL,
            last_used_at TEXT DEFAULT NULL,
            note TEXT DEFAULT ''
        )
    """)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS usage_log (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            key TEXT NOT NULL,
            ip TEXT DEFAULT '',
            action TEXT DEFAULT 'chat',
            created_at TEXT DEFAULT (datetime('now','localtime'))
        )
    """)
    conn.commit()
    conn.close()

init_db()

# ========== API Key 校验 ==========
def check_key(api_key):
    conn = get_db()
    row = conn.execute("SELECT * FROM api_keys WHERE key = ?", (api_key,)).fetchone()
    conn.close()
    if not row:
        return None, "API Key 不存在"
    if row["status"] != "active":
        return None, f"API Key 状态: {row['status']}"
    if row["max_uses"] != -1 and row["used_count"] >= row["max_uses"]:
        return None, f"API Key 使用次数已用完 ({row['used_count']}/{row['max_uses']})"
    if row["expires_at"]:
        exp = datetime.datetime.strptime(row["expires_at"], "%Y-%m-%d %H:%M:%S")
        if exp < datetime.datetime.now():
            return None, f"API Key 已过期 ({row['expires_at']})"
    return dict(row), None

def use_key(api_key, ip=""):
    conn = get_db()
    conn.execute("UPDATE api_keys SET used_count = used_count + 1, last_used_at = datetime('now','localtime') WHERE key = ?", (api_key,))
    conn.execute("INSERT INTO usage_log (key, ip) VALUES (?, ?)", (api_key, ip))
    conn.commit()
    conn.close()

# ========== API 端点 ==========
@app.route("/api/health", methods=["GET"])
def health():
    return jsonify({"status": "ok", "service": "dxt-api-gateway-v2"})

@app.route("/api/chat", methods=["POST"])
def chat():
    data = request.get_json(silent=True) or {}
    api_key = data.get("api_key", "")
    message = data.get("message", "")
    session_id = data.get("session_id", "default")
    client_ip = request.remote_addr or ""

    if not api_key:
        return jsonify({"error": "缺少 api_key"}), 401
    if not message:
        return jsonify({"error": "message 不能为空"}), 400

    # 验证 Key
    key_info, err = check_key(api_key)
    if err:
        return jsonify({"error": err}), 403

    try:
        if UGREEN_API_KEY:
            resp = requests.post(
                UGREEN_API_URL,
                headers={"Authorization": f"Bearer {UGREEN_API_KEY}", "Content-Type": "application/json"},
                json={"model": "gpt-4o-mini", "messages": [{"role": "user", "content": message}], "max_tokens": 4096, "temperature": 0.1},
                timeout=120
            )
        else:
            resp = requests.post(
                DEEPSEEK_API_URL,
                headers={"Authorization": f"Bearer {DEEPSEEK_API_KEY}", "Content-Type": "application/json"},
                json={"model": "deepseek-chat", "messages": [{"role": "user", "content": message}], "max_tokens": 4096, "temperature": 0.1, "stream": False},
                timeout=120
            )

        if resp.status_code != 200:
            return jsonify({"error": f"上游 API 错误 ({resp.status_code})", "message": resp.text[:500]}), 502

        # 扣减次数
        use_key(api_key, client_ip)

        result = resp.json()
        response_text = result["choices"][0]["message"]["content"]
        return jsonify({"response": response_text, "session_id": session_id})

    except requests.exceptions.Timeout:
        return jsonify({"error": "上游 API 超时"}), 504
    except Exception as e:
        return jsonify({"error": f"内部错误: {str(e)}"}), 500

# ========== 管理后台 ==========
ADMIN_HTML = r'''
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>电小团 API Key 管理</title>
<style>
* { margin:0; padding:0; box-sizing:border-box; }
body { font-family:'PingFang SC','Microsoft YaHei',sans-serif; background:#f5f7fa; color:#333; }
.header { background:linear-gradient(135deg,#1a1a2e,#16213e); color:#fff; padding:20px 24px; }
.header h1 { font-size:20px; font-weight:700; }
.header p { font-size:13px; color:#8899bb; margin-top:4px; }
.container { max-width:1100px; margin:0 auto; padding:20px; }
.card { background:#fff; border-radius:12px; padding:20px; margin-bottom:16px; box-shadow:0 2px 8px rgba(0,0,0,0.06); }
.card h3 { font-size:15px; font-weight:600; margin-bottom:12px; padding-bottom:8px; border-bottom:1px solid #eee; }
.row { display:flex; gap:10px; align-items:end; flex-wrap:wrap; margin-bottom:10px; }
.field { display:flex; flex-direction:column; gap:4px; }
.field label { font-size:12px; color:#8899bb; font-weight:500; }
.field input, .field select { padding:8px 12px; border:1px solid #ddd; border-radius:6px; font-size:13px; }
.field input:focus, .field select:focus { outline:none; border-color:#5E8B7E; }
.btn { padding:8px 20px; border:none; border-radius:8px; font-size:13px; font-weight:600; cursor:pointer; }
.btn-primary { background:#5E8B7E; color:#fff; }
.btn-primary:hover { background:#4D7569; }
.btn-danger { background:#ef4444; color:#fff; }
.btn-sm { padding:4px 12px; font-size:12px; }
table { width:100%; border-collapse:collapse; font-size:13px; }
th { text-align:left; padding:8px 6px; color:#8899bb; font-weight:500; font-size:11px; border-bottom:2px solid #eee; }
td { padding:8px 6px; border-bottom:1px solid #f0f0f0; }
.status-badge { display:inline-block; padding:2px 8px; border-radius:4px; font-size:11px; font-weight:600; }
.active { background:#e8f5e9; color:#2e7d32; }
.expired { background:#fbe9e7; color:#c62828; }
.disabled { background:#f5f5f5; color:#888; }
.trial { background:#e3f2fd; color:#1565c0; }
.monthly { background:#f3e5f5; color:#7b1fa2; }
.custom { background:#fff3e0; color:#e65100; }
.key-text { font-family:monospace; font-size:12px; background:#f5f5f5; padding:2px 6px; border-radius:3px; word-break:break-all; }
.copy-btn { cursor:pointer; color:#5E8B7E; font-size:12px; }
.copy-btn:hover { text-decoration:underline; }
.alert { padding:10px 14px; border-radius:8px; font-size:13px; margin-bottom:10px; display:none; }
.alert-success { background:#e8f5e9; color:#2e7d32; display:block; }
.alert-error { background:#fbe9e7; color:#c62828; display:block; }
.login-box { max-width:360px; margin:80px auto; }
.login-box .card { text-align:center; }
.login-box input { width:100%; margin-bottom:12px; }
</style>
</head>
<body>
<div id="app">
  <!-- 登录页 -->
  <div id="loginPage" class="container" v-if="!loggedIn">
    <div class="login-box">
      <div class="card" style="padding:32px;">
        <h2 style="font-size:18px;margin-bottom:16px;">🔑 电小团 API 管理</h2>
        <input type="password" v-model="password" placeholder="管理员密码" style="width:100%;padding:10px 14px;border:1px solid #ddd;border-radius:8px;font-size:14px;margin-bottom:12px;">
        <button class="btn btn-primary" style="width:100%;padding:10px;" @click="login">登录</button>
        <p v-if="loginError" style="color:#ef4444;font-size:13px;margin-top:8px;">{{ loginError }}</p>
      </div>
    </div>
  </div>

  <!-- 管理页 -->
  <div v-if="loggedIn">
    <div class="header">
      <h1>🔑 电小团 API Key 管理后台</h1>
      <p>总 Key 数: {{ keys.length }} | 今日调用: {{ todayStats.used }} 次 | 活跃 Key: {{ todayStats.active }}</p>
    </div>
    <div class="container">
      <div v-if="alertMsg" :class="['alert', alertType === 'success' ? 'alert-success' : 'alert-error']">{{ alertMsg }}</div>

      <!-- 生成 Key -->
      <div class="card">
        <h3>➕ 生成新 API Key</h3>
        <div class="row">
          <div class="field">
            <label>客户名称/备注</label>
            <input type="text" v-model="newKey.name" placeholder="如：张总/演示">
          </div>
          <div class="field">
            <label>类型</label>
            <select v-model="newKey.type">
              <option value="trial">体验卡（1次）</option>
              <option value="monthly">月卡（无限次）</option>
              <option value="custom">自定义</option>
            </select>
          </div>
          <div v-if="newKey.type === 'custom'" class="field">
            <label>可用次数（-1=无限）</label>
            <input type="number" v-model.number="newKey.maxUses" min="-1" style="width:100px;">
          </div>
          <div v-if="newKey.type === 'monthly' || newKey.type === 'custom'" class="field">
            <label>过期时间</label>
            <input type="date" v-model="newKey.expires">
          </div>
          <div class="field" style="justify-content:end;">
            <button class="btn btn-primary" @click="generateKey">生成 Key</button>
          </div>
        </div>
        <div v-if="generatedKey" style="margin-top:10px;padding:10px;background:#f0fdf4;border-radius:8px;font-size:14px;">
          已生成：<code style="font-size:16px;font-weight:700;color:#5E8B7E;">{{ generatedKey }}</code>
          <span class="copy-btn" @click="copyKey(generatedKey)" style="margin-left:10px;">📋 复制</span>
        </div>
      </div>

      <!-- Key 列表 -->
      <div class="card">
        <h3>📋 API Key 列表</h3>
        <div style="overflow-x:auto;">
          <table>
            <thead>
              <tr>
                <th>API Key</th>
                <th>备注</th>
                <th>类型</th>
                <th>状态</th>
                <th>使用</th>
                <th>过期</th>
                <th>最近使用</th>
                <th>操作</th>
              </tr>
            </thead>
            <tbody>
              <tr v-for="k in keys" :key="k.key">
                <td><span class="key-text">{{ k.key }}</span> <span class="copy-btn" @click="copyKey(k.key)">📋</span></td>
                <td>{{ k.name || '-' }}</td>
                <td><span :class="['status-badge', k.type]">{{ {'trial':'体验卡','monthly':'月卡','custom':'自定义'}[k.type] }}</span></td>
                <td><span :class="['status-badge', k.status]">{{ {'active':'正常','expired':'已过期','disabled':'已禁用'}[k.status] }}</span></td>
                <td>{{ k.used_count }}{{ k.max_uses === -1 ? '/∞' : '/'+k.max_uses }}</td>
                <td>{{ k.expires_at ? k.expires_at.slice(0,10) : '永久' }}</td>
                <td style="font-size:11px;color:#8899bb;">{{ k.last_used_at || '-' }}</td>
                <td>
                  <button v-if="k.status === 'active'" class="btn btn-sm btn-danger" @click="disableKey(k.key)">禁用</button>
                  <button v-else class="btn btn-sm btn-primary" @click="enableKey(k.key)">启用</button>
                  <button class="btn btn-sm btn-danger" style="margin-left:4px;" @click="deleteKey(k.key)">删除</button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>
  </div>
</div>

<script src="https://unpkg.com/vue@3/dist/vue.global.prod.js"></script>
<script>
const { createApp, ref, onMounted } = Vue;
createApp({
  setup() {
    const loggedIn = ref(false);
    const password = ref('');
    const loginError = ref('');
    const keys = ref([]);
    const alertMsg = ref('');
    const alertType = ref('success');
    const generatedKey = ref('');
    const newKey = ref({ name: '', type: 'trial', maxUses: 1, expires: '' });
    const todayStats = ref({ used: 0, active: 0 });

    function flash(msg, type='success') { alertMsg.value = msg; alertType.value = type; setTimeout(() => alertMsg.value='', 3000); }

    async function api(path, data) {
      const r = await fetch(path, { method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify(data || {}) });
      return await r.json();
    }

    async function login() {
      const res = await api('/admin/api/login', { password: password.value });
      if (res.success) { loggedIn.value = true; loadKeys(); }
      else { loginError.value = res.message; }
    }

    async function loadKeys() {
      const res = await api('/admin/api/keys', { action: 'list' });
      if (res.success) { keys.value = res.keys; todayStats.value = res.stats; }
    }

    async function generateKey() {
      const res = await api('/admin/api/keys', {
        action: 'create',
        name: newKey.value.name,
        type: newKey.value.type,
        max_uses: newKey.value.type === 'trial' ? 1 : (newKey.value.type === 'monthly' ? -1 : newKey.value.maxUses),
        expires_at: newKey.value.expires || null
      });
      if (res.success) {
        generatedKey.value = res.key;
        flash('Key 生成成功！');
        loadKeys();
      } else {
        flash(res.message, 'error');
      }
    }

    async function disableKey(key) {
      if (!confirm(`确定禁用此 Key？`)) return;
      await api('/admin/api/keys', { action: 'disable', key });
      flash('已禁用');
      loadKeys();
    }
    async function enableKey(key) {
      await api('/admin/api/keys', { action: 'enable', key });
      flash('已启用');
      loadKeys();
    }
    async function deleteKey(key) {
      if (!confirm(`确定删除此 Key？操作不可恢复`)) return;
      await api('/admin/api/keys', { action: 'delete', key });
      flash('已删除');
      loadKeys();
    }

    function copyKey(key) {
      navigator.clipboard.writeText(key).then(() => flash('已复制到剪贴板'));
    }

    return { loggedIn, password, loginError, keys, alertMsg, alertType, generatedKey, newKey, todayStats,
             login, loadKeys, generateKey, disableKey, enableKey, deleteKey, copyKey, flash };
  }
}).mount('#app');
</script>
</body>
</html>
'''

@app.route("/admin/", methods=["GET"])
def admin_page():
    return render_template_string(ADMIN_HTML)

@app.route("/admin/api/login", methods=["POST"])
def admin_login():
    data = request.get_json(silent=True) or {}
    if data.get("password") == ADMIN_PASSWORD:
        return jsonify({"success": True})
    return jsonify({"success": False, "message": "密码错误"}), 401

@app.route("/admin/api/keys", methods=["POST"])
def admin_keys():
    data = request.get_json(silent=True) or {}
    action = data.get("action", "")
    conn = get_db()

    if action == "list":
        rows = conn.execute("SELECT * FROM api_keys ORDER BY id DESC LIMIT 100").fetchall()
        keys_list = [dict(r) for r in rows]
        # 今日统计
        today = datetime.date.today().strftime("%Y-%m-%d")
        used = conn.execute("SELECT COUNT(*) as c FROM usage_log WHERE created_at >= ?", (today,)).fetchone()["c"]
        active = conn.execute("SELECT COUNT(*) as c FROM api_keys WHERE status='active'").fetchone()["c"]
        conn.close()
        return jsonify({"success": True, "keys": keys_list, "stats": {"used": used, "active": active}})

    elif action == "create":
        name = data.get("name", "")
        key_type = data.get("type", "trial")
        max_uses = data.get("max_uses", 1)
        expires_at = data.get("expires_at")
        if expires_at:
            expires_at += " 23:59:59"
        new_key = "dxt_" + secrets.token_hex(12)
        try:
            conn.execute(
                "INSERT INTO api_keys (key, name, type, max_uses, expires_at) VALUES (?, ?, ?, ?, ?)",
                (new_key, name, key_type, max_uses, expires_at)
            )
            conn.commit()
            conn.close()
            return jsonify({"success": True, "key": new_key})
        except Exception as e:
            conn.close()
            return jsonify({"success": False, "message": str(e)})

    elif action == "disable":
        conn.execute("UPDATE api_keys SET status='disabled' WHERE key=?", (data.get("key"),))
        conn.commit(); conn.close()
        return jsonify({"success": True})

    elif action == "enable":
        conn.execute("UPDATE api_keys SET status='active' WHERE key=?", (data.get("key"),))
        conn.commit(); conn.close()
        return jsonify({"success": True})

    elif action == "delete":
        conn.execute("DELETE FROM api_keys WHERE key=?", (data.get("key"),))
        conn.commit(); conn.close()
        return jsonify({"success": True})

    return jsonify({"success": False, "message": "未知操作"}), 400

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5010, debug=True)
PYEOF

echo "服务文件已创建: /opt/dxt-api/app.py"

# 3. 环境变量
echo "[3/6] 配置环境变量..."
cat > /opt/dxt-api/.env << 'ENVEOF'
# 管理员密码（登录后台用）
ADMIN_PASSWORD=admin123456

# DeepSeek API Key（必填）
DEEPSEEK_API_KEY=YOUR_DEEPSEEK_API_KEY_HERE

# UGREEN 模型（二选一）
UGREEN_API_KEY=
ENVEOF

echo ""
echo "⚠️  重要：请编辑 /opt/dxt-api/.env 填入 DeepSeek API Key！"
echo "   编辑命令: nano /opt/dxt-api/.env"
echo "   管理后台地址: http://121.40.44.152/admin/"
echo "   管理员密码: admin123456（可在 .env 中修改）"
echo ""

# 4. systemd 服务
echo "[4/6] 创建 systemd 服务..."
cat > /etc/systemd/system/dxt-api.service << 'SVCEOF'
[Unit]
Description=电小团 API 转发服务 v2
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/dxt-api
EnvironmentFile=/opt/dxt-api/.env
ExecStart=/usr/local/bin/gunicorn -w 2 -b 0.0.0.0:5010 app:app --timeout 120
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVCEOF
systemctl daemon-reload

# 5. nginx 反代
echo "[5/6] 配置 nginx..."
cat > /etc/nginx/sites-available/dxt-api << 'NGXEOF'
server {
    listen 80;
    server_name 121.40.44.152;
    client_max_body_size 10m;
    proxy_read_timeout 120s;
    location / {
        proxy_pass http://127.0.0.1:5010;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
NGXEOF
rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/dxt-api /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx

# 6. 启动
echo "[6/6] 启动服务..."
systemctl start dxt-api
systemctl enable dxt-api

echo ""
echo "=========================================="
echo "部署完成！"
echo "=========================================="
echo ""
echo "  ➤ 管理后台: http://121.40.44.152/admin/"
echo "  ➤ 管理员密码: admin123456"
echo "  ➤ API 端点: http://121.40.44.152/api/chat"
echo ""
echo "  请先编辑 .env 填入 DeepSeek API Key:"
echo "    nano /opt/dxt-api/.env"
echo "    systemctl restart dxt-api"
echo ""
echo "  测试:"
echo '    curl -X POST http://121.40.44.152/api/chat \'
echo '      -H "Content-Type: application/json" \'
echo '      -d "{\"api_key\":\"dxt_test_key_2026\",\"message\":\"你好\"}"'
echo ""
echo "  （注意：新系统没有 dxt_test_key_2026 了，"
echo "   需要在后台先生成一个 Key）"
echo ""
