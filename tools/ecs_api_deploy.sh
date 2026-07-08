#!/bin/bash
# ============================================================
# ECS API 转发服务一键部署脚本
# 在阿里云 ECS (121.40.44.152) 上执行
# ============================================================
# 使用方式：在 ECS 上运行本脚本
# ============================================================

set -e

echo "=========================================="
echo "电小团 API 转发服务部署"
echo "=========================================="

# 1. 安装 Python3 + pip（如果还没有）
echo "[1/6] 检查 Python 环境..."
if ! command -v python3 &> /dev/null; then
    apt-get update && apt-get install -y python3 python3-pip
fi

# 2. 安装依赖
echo "[2/6] 安装 Python 依赖..."
pip3 install flask gunicorn requests --break-system-packages 2>/dev/null || pip3 install flask gunicorn requests

# 3. 创建 API 服务程序
echo "[3/6] 创建 API 服务..."
mkdir -p /opt/dxt-api
cat > /opt/dxt-api/app.py << 'PYEOF'
import os
import json
import requests
from flask import Flask, request, jsonify
from functools import wraps

app = Flask(__name__)

# ========== 配置 ==========
# 电小团 API Key（你自己设一个密码串，分发给客户/放在前端）
VALID_API_KEYS = os.environ.get("DXT_API_KEYS", "dxt_test_key_2026").split(",")

# DeepSeek API 配置（用你在 Hermes 后台配的那个 key）
DEEPSEEK_API_KEY = os.environ.get("DEEPSEEK_API_KEY", "")
DEEPSEEK_API_URL = "https://api.deepseek.com/v1/chat/completions"

# 或者用 UGREEN 模型（如果你更想用那个）
UGREEN_API_KEY = os.environ.get("UGREEN_API_KEY", "")
UGREEN_API_URL = "http://code.ugreencloud.com:8000/v1/chat/completions"
# ==========================

def require_api_key(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        data = request.get_json(silent=True) or {}
        api_key = data.get("api_key", "")
        if api_key not in VALID_API_KEYS:
            return jsonify({"error": "API Key 无效", "message": "请提供有效的电小团 API Key"}), 401
        return f(*args, **kwargs)
    return decorated

@app.route("/api/health", methods=["GET"])
def health():
    return jsonify({"status": "ok", "service": "dxt-api-gateway"})

@app.route("/api/chat", methods=["POST"])
@require_api_key
def chat():
    """接收电费联单分析请求，调用 DeepSeek API 分析"""
    data = request.get_json(silent=True) or {}
    message = data.get("message", "")
    session_id = data.get("session_id", "default")

    if not message:
        return jsonify({"error": "message 不能为空"}), 400

    try:
        # 优先用 UGREEN 模型（跟你的 Hermes 同一路）
        if UGREEN_API_KEY:
            resp = requests.post(
                UGREEN_API_URL,
                headers={
                    "Authorization": f"Bearer {UGREEN_API_KEY}",
                    "Content-Type": "application/json"
                },
                json={
                    "model": "gpt-4o-mini",
                    "messages": [{"role": "user", "content": message}],
                    "max_tokens": 4096,
                    "temperature": 0.1
                },
                timeout=120
            )
        else:
            # 否则用 DeepSeek
            resp = requests.post(
                DEEPSEEK_API_URL,
                headers={
                    "Authorization": f"Bearer {DEEPSEEK_API_KEY}",
                    "Content-Type": "application/json"
                },
                json={
                    "model": "deepseek-chat",
                    "messages": [{"role": "user", "content": message}],
                    "max_tokens": 4096,
                    "temperature": 0.1,
                    "stream": False
                },
                timeout=120
            )

        if resp.status_code != 200:
            return jsonify({
                "error": f"上游 API 错误 ({resp.status_code})",
                "message": resp.text[:500]
            }), 502

        result = resp.json()
        response_text = result["choices"][0]["message"]["content"]

        return jsonify({
            "response": response_text,
            "session_id": session_id
        })

    except requests.exceptions.Timeout:
        return jsonify({"error": "上游 API 超时"}), 504
    except Exception as e:
        return jsonify({"error": f"内部错误: {str(e)}"}), 500

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5010)
PYEOF

echo "服务文件已创建: /opt/dxt-api/app.py"

# 4. 配置环境变量
echo "[4/6] 配置环境变量..."
# ！！！重要：你需要修改下面的 Key ！！！
# 把 YOUR_DEEPSEEK_API_KEY 替换成你在 Hermes 后台配的那个 DeepSeek API Key
cat > /opt/dxt-api/.env << 'ENVEOF'
# 电小团 API Key（前端用户输入的那个）
# 可以设置多个，用逗号分隔。默认 key 用于测试
DXT_API_KEYS=dxt_test_key_2026

# DeepSeek API Key（必填，从 DeepSeek 官网获取）
DEEPSEEK_API_KEY=YOUR_DEEPSEEK_API_KEY_HERE

# UGREEN 模型 API Key（二选一，如果不用 DeepSeek 就填这个）
UGREEN_API_KEY=
ENVEOF

echo ""
echo "⚠️  重要：请编辑 /opt/dxt-api/.env 填入你的 DeepSeek API Key！"
echo "   编辑命令: nano /opt/dxt-api/.env"
echo ""

# 5. 配置 systemd 服务
echo "[5/6] 创建 systemd 服务..."
cat > /etc/systemd/system/dxt-api.service << 'SVCEOF'
[Unit]
Description=电小团 API 转发服务
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

# 6. 配置 nginx 反代
echo "[6/6] 配置 nginx 反向代理..."
cat > /etc/nginx/sites-available/dxt-api << 'NGXEOF'
server {
    listen 80;
    server_name 121.40.44.152;

    # 如果需要域名，改成你的域名
    # server_name api.aishenwo.cn;

    client_max_body_size 10m;
    proxy_read_timeout 120s;

    location /api/ {
        proxy_pass http://127.0.0.1:5010;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
NGXEOF

# 启用站点（如果已存在同名站点，先删除旧链接）
rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/dxt-api /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx

echo ""
echo "=========================================="
echo "部署完成！"
echo "=========================================="
echo ""
echo "接下来请执行："
echo "  1. 编辑环境变量: nano /opt/dxt-api/.env"
echo "     - 把 DEEPSEEK_API_KEY 改成你的真实 Key"
echo "     - 可选: 修改 DXT_API_KEYS 为自定义值"
echo ""
echo "  2. 启动服务: systemctl start dxt-api"
echo "     - 开机自启: systemctl enable dxt-api"
echo "     - 查看状态: systemctl status dxt-api"
echo "     - 查看日志: journalctl -u dxt-api -f"
echo ""
echo "  3. 测试: curl http://121.40.44.152/api/health"
echo ""
echo "  4. 测试 AI 分析:"
echo '     curl -X POST http://121.40.44.152/api/chat \'
echo '       -H "Content-Type: application/json" \'
echo '       -d "{\"api_key\":\"dxt_test_key_2026\",\"message\":\"你好\"}"'
echo ""
echo "  5. （可选）配 HTTPS：在 ECS 上装 certbot 申请证书"
echo ""
