---
name: github-sni-relay
description: Use when GitHub 网页/登录被墙。用自有 ECS 做 443 SNI 透传中转恢复访问。
version: 1.0.0
author: 合尘猫 SavantCat
tags:
  - network
  - github
  - nginx
  - sni
---

# GitHub 主站被墙 → 自有 ECS 443 SNI 透传中转

> 适用场景：`github.com` 网页打不开、登录不了，但 `api.github.com`、`codeload.github.com`、静态资源域名仍然正常。
> 这是**按域名（SNI）定向阻断**，不是全站封 —— 换 IP、改 DNS、装免费加速工具都治不了根。
> 方案：用一台**能访问 GitHub 的自有服务器**做 443 SNI 透传，客户端只改 hosts。

## 一、先诊断，别乱换 IP

```bash
for u in https://github.com/ https://api.github.com/ https://codeload.github.com/ https://github.githubassets.com/; do
  printf "%-40s " "$u"; curl -s -o /dev/null -w "http=%{http_code} ip=%{remote_ip} t=%{time_total}\n" --max-time 8 "$u"
done
```

- `github.com` http=000（超时）+ `api.github.com` 200 → **确认是按域名阻断，不要再试备用 IP**。
- 实测无效的备用 IP：`140.82.112/113/114/116.3`、`20.27.177.113`、`20.200.245.247`、`4.208.26.197`、`20.233.83.145`、`20.205.243.164/165/166`。同一 IP 会一会儿 400 一会儿超时，属间歇性阻断。
- **IPv6 是假线索**：`nslookup -type=AAAA github.com` 得到的 `2606:50c0:800x::154` 是 Fastly 泛播节点，返回 `500 Domain Not Found (Fastly error: unknown domain github.com)`，不是 GitHub 源站。
- **gist.github.com 无解**：解析到污染 IP（`59.24.3.173` 这类），服务端侧同样 000，也无法用 `github.com` 的 IP 套 gist 的 SNI 冒充。**直接放弃这条，不影响登录。**
- 结论：只有「自己找一条能到 GitHub 的通道」才治本。

## 二、先验证服务端能力

```bash
ssh root@<ECS_IP> 'for h in github.com api.github.com codeload.github.com avatars.githubusercontent.com github.githubassets.com x.com chatgpt.com; do printf "%-36s " $h; curl -s -o /dev/null -w "http=%{http_code} t=%{time_total}\n" --max-time 8 https://$h; done'
```

判据：`github.com` 必须 `http=200`。否则这台机器救不了，换一台（境外机房最稳；部分国内机房实测也能通 GitHub）。

**边界**：国内机房到 `x.com` / `chatgpt.com` / `google.com` 全是 000 —— 本方案**只能救 GitHub**，别指望顺带解决其他墙外服务。

## 三、服务端部署

原理：`ssl_preread` 只**读** ClientHello 的 SNI 做选路，**不终止 TLS** —— 证书始终是 GitHub 官方签发（Sectigo / CN=github.com），浏览器零警告，不是中间人。

### 1. 装 stream 模块

`nginx -V` 里有 `--with-stream=dynamic` 但 `.so` 默认不装：

| 系统 | 命令 |
|:---|:---|
| RHEL / CentOS / Alibaba Cloud Linux | `yum install -y nginx-mod-stream` |
| Debian / Ubuntu | `apt install -y libnginx-mod-stream` |

版本必须与 nginx 完全一致。装完确认 `/usr/lib64/nginx/modules/ngx_stream_module.so`（Debian 系在 `/usr/lib/nginx/modules/`）与 `mod-stream.conf` 存在。

### 2. 把 http 层的 443 让给 stream

```bash
sed -i 's/listen 443 ssl http2/listen 127.0.0.1:8443 ssl http2/g; s/listen \[::\]:443 ssl http2/listen [::1]:8443 ssl http2/g' /etc/nginx/conf.d/*.conf
```

只改监听地址，站点逻辑不变。

### 3. 写 stream 分流配置

`/etc/nginx/stream.d/github-sni.conf` —— **整个文件必须包在 `stream { }` 里**（nginx.conf 是在 main 上下文 include 它的）：

```nginx
stream {
    map $ssl_preread_server_name $gh_upstream {
        default                          127.0.0.1:8443;
        ~^([a-z0-9_-]+\.)?github\.com$    github.com:443;
    }
    server {
        listen      443;
        listen      [::]:443;
        ssl_preread on;
        proxy_pass  $gh_upstream;
        resolver    223.5.5.5 119.29.29.29 valid=300s ipv6=off;   # 变量 proxy_pass 必须有 resolver
        proxy_connect_timeout 10s;
        proxy_timeout         600s;
    }
}
```

再在 nginx.conf 顶层（`include /usr/share/nginx/modules/*.conf;` 之后）加：

```nginx
include /etc/nginx/stream.d/*.conf;
```

### 4. 校验 + 重载（务必带备份回滚）

```bash
cp -a /etc/nginx /root/nginx-bak-$(date +%Y%m%d_%H%M%S)
nginx -t && systemctl reload nginx
```

现成脚本 `scripts/deploy-ecs-sni-relay.sh` 已含备份与 `nginx -t` 失败自动回滚。

## 四、客户端 hosts

只加**被阻断的那几个**；`api.github.com` / `codeload` / `avatars` / `github.githubassets.com` 本来就通，别动（直连更快）。

```
<ECS_IP> github.com
<ECS_IP> www.github.com
<ECS_IP> collector.github.com
```

Windows 需管理员；PowerShell 写 hosts 必须用 `-Encoding ASCII`（不能带 BOM/UTF-16），写完 `ipconfig /flushdns`。现成脚本 `scripts/add-hosts.ps1`。

## 五、验收（三条都要过）

```bash
curl -s -o /dev/null -w "/ http=%{http_code} ip=%{remote_ip} t=%{time_total}\n" --max-time 15 https://github.com/
curl -s -o /dev/null -w "/login http=%{http_code}\n" --max-time 15 https://github.com/login
echo | openssl s_client -connect <ECS_IP>:443 -servername github.com 2>/dev/null | openssl x509 -noout -subject -issuer
curl -s -o /dev/null -w "POST %{http_code}\n" -X POST -d "login=x&password=x" https://github.com/session   # 期望 422
```

达标线：`/` 与 `/login` = 200、`remote_ip=<ECS_IP>`、t ≈ 0.5s、连测 3/3 稳定；证书 `subject=CN=github.com`、`issuer=Sectigo`；POST 返回 422（GitHub 正常 CSRF 拒绝，证明请求到达源站）。

**别忘验收自己的站点**：`curl --resolve <你的域名>:443:<ECS_IP> https://<你的域名>/` 应为 200。

## 六、坑

- `nginx: [emerg] "map" directive is not allowed here` → 忘了 `stream { }` 包裹。
- 用了变量 `proxy_pass $var` 却没写 `resolver` → 启动报 no resolver defined。
- 别把 `api.github.com` 加进 hosts，它本来就通，绕过去只是更慢。
- `github.com/signup` 返回 403 属正常（GitHub 对部分地区出口的注册风控），不影响登录。
- 免费加速工具（Watt Toolkit 类）网页登录常救不回；公共镜像站（fastgit / cnpmjs）2022 年前后已陆续关停，网上教程多为过期信息；改 DNS 无效（阻断在 TLS 阶段）。

## 七、部署脚本

| 文件 | 用途 |
|:---|:---|
| `scripts/deploy-ecs-sni-relay.sh` | 服务端一键部署，带备份 + 自动回滚；支持 `LOCAL_HTTPS_PORT` / `NGINX_CONF_GLOB` 环境变量 |
| `scripts/add-hosts.ps1` | Windows 客户端写入 hosts，自动备份 + 刷 DNS + 回读验证 |
