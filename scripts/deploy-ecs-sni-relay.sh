#!/bin/bash
# ============================================================
# github-sni-relay 服务端一键部署
#   在 443 上做 SNI 分流：*.github.com -> github.com:443（TLS 透传）
#   其余域名 -> 本地 http 站点（默认 127.0.0.1:8443）
#
# 用法：
#   bash deploy-ecs-sni-relay.sh                  # 使用默认值
#   LOCAL_HTTPS_PORT=9443 bash deploy-ecs-sni-relay.sh
#   NGINX_CONF_GLOB='/etc/nginx/conf.d/*.conf' bash deploy-ecs-sni-relay.sh
#
# 特性：先备份 /etc/nginx，nginx -t 不通过自动回滚并重载。
# ============================================================
set -euo pipefail

LOCAL_HTTPS_PORT="${LOCAL_HTTPS_PORT:-8443}"
CONF_GLOB="${NGINX_CONF_GLOB:-/etc/nginx/conf.d/*.conf}"
STREAM_DIR="${STREAM_DIR:-/etc/nginx/stream.d}"
NGINX_CONF="${NGINX_CONF:-/etc/nginx/nginx.conf}"
MODULES_INCLUDE='include /usr/share/nginx/modules/*.conf;'
STAMP=$(date +%Y%m%d_%H%M%S)
BAK="/root/nginx-bak-$STAMP"

echo "==> [0] 前置检查"
if ! command -v nginx >/dev/null 2>&1; then
  echo "!! 未找到 nginx，请先安装"; exit 1
fi
if ! nginx -V 2>&1 | grep -q -- '--with-stream'; then
  echo "!! 当前 nginx 未编译 stream 模块，无法使用本方案"; exit 1
fi

echo "==> [1] 备份 /etc/nginx -> $BAK"
mkdir -p "$BAK"
cp -a /etc/nginx/. "$BAK"/

echo "==> [2] 把 http 层 443 让给 stream（改监听为 127.0.0.1:$LOCAL_HTTPS_PORT）"
patched=0
for f in $CONF_GLOB; do
  [ -f "$f" ] || continue
  if grep -qE 'listen\s+(\[::\]:)?443\s+ssl' "$f"; then
    sed -i \
      -e "s/listen 443 ssl/listen 127.0.0.1:${LOCAL_HTTPS_PORT} ssl/g" \
      -e "s/listen \[::\]:443 ssl/listen [::1]:${LOCAL_HTTPS_PORT} ssl/g" "$f"
    echo "    patched $f"; patched=$((patched+1))
  fi
done
echo "    共修改 $patched 个文件"

echo "==> [3] 写入 stream 分流配置"
mkdir -p "$STREAM_DIR"
cat > "$STREAM_DIR/github-sni.conf" <<EOF
# github-sni-relay: 443 SNI 分流
# github 系域名 -> 真实 GitHub（TLS 全程透传，证书为 GitHub 官方证书）
# 其余域名     -> 本地 http 站点 127.0.0.1:${LOCAL_HTTPS_PORT}
stream {
    map \$ssl_preread_server_name \$gh_upstream {
        default                          127.0.0.1:${LOCAL_HTTPS_PORT};
        ~^([a-z0-9_-]+\.)?github\.com\$    github.com:443;
    }

    server {
        listen      443;
        listen      [::]:443;
        ssl_preread on;
        proxy_pass  \$gh_upstream;
        resolver    223.5.5.5 119.29.29.29 valid=300s ipv6=off;
        proxy_connect_timeout 10s;
        proxy_timeout         600s;
    }
}
EOF
echo "    已写入 $STREAM_DIR/github-sni.conf"

echo "==> [4] 在 nginx.conf 顶层引入 stream.d"
if grep -q 'stream\.d' "$NGINX_CONF"; then
  echo "    已存在，跳过"
else
  if grep -qF "$MODULES_INCLUDE" "$NGINX_CONF"; then
    sed -i "s#^${MODULES_INCLUDE}#${MODULES_INCLUDE}\ninclude ${STREAM_DIR}/*.conf;#" "$NGINX_CONF"
  else
    # 兜底：插到 events { 之前
    sed -i "0,/^events\s*{/s//include ${STREAM_DIR}\/*.conf;\n\nevents {/" "$NGINX_CONF"
  fi
  echo "    已引入"
fi

echo "==> [5] nginx -t"
if nginx -t 2>&1; then
  systemctl reload nginx
  echo "==> 完成：已重载 nginx"
  echo "    回滚命令：rm -rf /etc/nginx/* && cp -a $BAK/. /etc/nginx/ && systemctl reload nginx"
else
  echo "!! 语法校验失败，自动回滚"
  rm -rf /etc/nginx/*
  cp -a "$BAK"/. /etc/nginx/
  systemctl reload nginx || true
  echo "!! 已回滚到 $BAK"
  exit 1
fi
