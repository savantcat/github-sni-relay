# github-sni-relay

> **国内 GitHub 网页/登录被阻断时，用你自己的 ECS 做 443 SNI 透传中转。**
> 浏览器零证书警告，实测 `github.com` 从「8 秒超时」变成「0.5 秒 200」。

---

## 一、先确认你遇到的是哪一种「打不开」

很多人一上来就满世界找备用 IP，其实先花 10 秒跑一段命令，就能判断该不该折腾：

```bash
for u in https://github.com/ https://api.github.com/ https://codeload.github.com/ https://github.githubassets.com/; do
  printf "%-40s " "$u"
  curl -s -o /dev/null -w "http=%{http_code} ip=%{remote_ip} t=%{time_total}\n" --max-time 8 "$u"
done
```

| 结果 | 结论 |
|:---|:---|
| 全部超时 | 整体不可达，本文方案同样适用（服务端要能出网） |
| **`github.com` 超时，但 `api.` / `codeload.` / `githubassets.` 返回 200 或 404** | ✅ **按域名（SNI）定向阻断 —— 本文方案的标准适用场景** |

如果是第二种，**别再试备用 IP 了**。实测这些地址全军覆没，而且同一个 IP 会一会儿通一会儿断，属于间歇性阻断：

```
140.82.112.3  140.82.113.3  140.82.114.3  140.82.116.3  140.82.121.4
20.27.177.113  20.200.245.247  4.208.26.197  20.233.83.145
20.205.243.164  20.205.243.165  20.205.243.166
```

> **IPv6 是假线索**：`nslookup -type=AAAA github.com` 能查到 `2606:50c0:800x::154`，看起来有 IPv6 出口，但那是 Fastly 的泛播节点，会回一句
> `500 Domain Not Found (Fastly error: unknown domain github.com)` —— 不是 GitHub 源站，别浪费时间。
>
> **改 DNS 也治不了根**：这类阻断发生在 TLS 握手阶段（按 SNI 掐），不是解析阶段。

---

## 二、方案原理：让 TLS 握手原样穿过去

```
浏览器 ──TLS(SNI=github.com)──▶ 你的 ECS:443 ──原样透传──▶ github.com:443
                                     │
                                     └── 其余域名 ──▶ 你自己的网站(127.0.0.1:8443)
```

关键在于：nginx 的 `ssl_preread` 只**读** ClientHello 里的 SNI 用来选路，**不终止 TLS**。
所以证书始终是 GitHub 官方签发的那张（`Sectigo` / `CN=github.com`），浏览器不会弹任何警告 —— 这不是中间人，是一条透明通道。

用你已有的 ECS 当出口，比买机场/挂免费代理更稳：**独享 IP、不限速、不掉线、还能顺手救回 GitHub 的 git 协议。**

### 前置条件

1. 一台能正常访问 `github.com` 的服务器（放在境外最省事；国内机房也有可能通，先验证）
2. 服务器上有 nginx，且 **443 端口是通的**
3. 该服务器的防火墙/安全组放行 443

```bash
# 在服务器上先跑这一句，确认它真的出得去
curl -s -o /dev/null -w "github.com http=%{http_code} t=%{time_total}\n" --max-time 8 https://github.com/
# 期望 http=200；如果是 000，这台机器救不了你，换一台
```

---

## 三、部署（服务端）

### 1. 装 nginx 的 stream 模块

大多数发行版的 nginx 是 `--with-stream=dynamic` 编译的，但模块 `.so` **默认不装**：

```bash
nginx -V 2>&1 | tr ' ' '\n' | grep -E 'with-stream|modules-path'
```

| 系统 | 安装命令 |
|:---|:---|
| RHEL / CentOS / Alibaba Cloud Linux | `yum install -y nginx-mod-stream` |
| Debian / Ubuntu | `apt install -y libnginx-mod-stream` |

> **版本必须与 nginx 完全一致**，否则加载会失败。

安装后确认模块能被加载：

```bash
ls /usr/lib64/nginx/modules/ngx_stream_module.so   # Debian/Ubuntu 在 /usr/lib/nginx/modules/
cat /usr/share/nginx/modules/mod-stream.conf       # 内含 load_module，已被 nginx.conf 自动 include
```

### 2. 把 http 层的 443 让给 stream

443 通常被你自己的站点占着。**一个端口只能有一个监听者**，所以要把 http 的虚拟主机挪到内网端口：

```bash
sed -i 's/listen 443 ssl http2/listen 127.0.0.1:8443 ssl http2/g; \
        s/listen \[::\]:443 ssl http2/listen [::1]:8443 ssl http2/g' /etc/nginx/conf.d/*.conf
```

> 这一步只改监听地址，不改任何站点逻辑 —— 外面访问 443 的体验完全不变。

### 3. 写 SNI 分流配置

创建 `/etc/nginx/stream.d/github-sni.conf`：

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

        # 用了变量 proxy_pass 就必须有 resolver，否则启动直接报错
        resolver    223.5.5.5 119.29.29.29 valid=300s ipv6=off;

        proxy_connect_timeout 10s;
        proxy_timeout         600s;
    }
}
```

再在 `nginx.conf` 的**顶层**（跟着 `include /usr/share/nginx/modules/*.conf;` 那行之后）加一句：

```nginx
include /etc/nginx/stream.d/*.conf;
```

> ⚠️ 最容易踩的坑：`stream { }` 这层花括号**不能少**。因为 `nginx.conf` 是在 main 上下文里 include 你的文件的，光写 `map` 会直接报
> `nginx: [emerg] "map" directive is not allowed here`。

### 4. 校验 + 重载（失败自动回滚）

```bash
cp -a /etc/nginx /root/nginx-bak-$(date +%Y%m%d_%H%M%S)   # 先备份
nginx -t && systemctl reload nginx
```

仓库里的 `scripts/deploy-ecs-sni-relay.sh` 把上面这些步骤串好了，**并且带自动回滚**（`nginx -t` 不通过就自动还原配置并重载）：

```bash
scp scripts/deploy-ecs-sni-relay.sh root@<ECS_IP>:/root/
ssh root@<ECS_IP> 'bash /root/deploy-ecs-sni-relay.sh'
```

---

## 四、部署（客户端）

只需要把**被阻断的那几个域名**指到 ECS。其他域名本来就通，别动 —— 直连更快。

**Windows**（`C:\Windows\System32\drivers\etc\hosts`，需要管理员）：

```
<ECS_IP> github.com
<ECS_IP> www.github.com
<ECS_IP> collector.github.com
```

`scripts/add-hosts.ps1` 会自动备份 + 写入 + 刷新 DNS（会弹一次 UAC，点「是」即可）：

```powershell
powershell -NoProfile -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','add-hosts.ps1','-RelayIp','<ECS_IP>'"
```

**macOS / Linux**：

```bash
echo "<ECS_IP> github.com" | sudo tee -a /etc/hosts
```

最后刷新一下 DNS 缓存：

```bash
ipconfig /flushdns                    # Windows
sudo dscacheutil -flushcache          # macOS
sudo systemd-resolve --flush-caches   # Linux
```

---

## 五、验收：怎么算「真的成了」

```bash
# 1) 主站与登录页
for u in https://github.com/ https://github.com/login; do
  printf "%-30s " "$u"
  curl -s -o /dev/null -w "http=%{http_code} ip=%{remote_ip} t=%{time_total}\n" --max-time 15 "$u"
done
# 期望：http=200，ip=<ECS_IP>，t≈0.5s

# 2) 证书必须还是 GitHub 官方的（证明是透传，不是中间人）
echo | openssl s_client -connect <ECS_IP>:443 -servername github.com 2>/dev/null \
  | openssl x509 -noout -subject -issuer
# 期望：subject=CN=github.com   issuer=... Sectigo ...

# 3) POST 通道（登录提交走这条路）
curl -s -o /dev/null -w "POST %{http_code}\n" --max-time 15 \
  -X POST -d "login=x&password=x" https://github.com/session
# 期望：422 —— 这是 GitHub 正常的 CSRF 拒绝，说明请求确实到达了源站
```

顺手确认自己的站点没被改坏：

```bash
curl -s -o /dev/null -w "site http=%{http_code}\n" --resolve your-domain.com:443:<ECS_IP> https://your-domain.com/
```

---

## 六、已知边界（先说清，不画饼）

- **只能救 GitHub。** `x.com` / `chatgpt.com` / `google.com` 这些在国内机房里同样是超时，本文方案对它们无效 —— 上这些必须另找海外出口。
- **`gist.github.com` 救不回来。** 它被解析到污染 IP，服务端侧也同样不通，且无法用 github.com 的 IP 套 SNI 冒充。**但不影响登录和日常使用。**
- **`github.com/signup` 返回 403 是正常的** —— 属于 GitHub 对不同地区出口的注册风控，不影响登录。
- **需要 443 端口空闲或愿意让位。** 如果 ECS 上有别的服务占了 443，先确认能挪走。
- 本方案是给**自有服务器**做自用通道，请遵守你所在地与云服务商的相关规定。

---

## 七、为什么不用那些「一键加速」

| 路子 | 实际情况 |
|:---|:---|
| 公共镜像站（fastgit / cnpmjs 等） | ❌ 2022 年前后陆续关停，网上教程多为过期信息 |
| 改 DNS（223.5.5.5 等） | ❌ 这类阻断发生在 TLS 阶段，改解析没用 |
| 免费加速工具 | ⚠️ 时好时坏，网页登录常救不回；部分项目已归档弃坑 |
| **自有 ECS + SNI 透传** | ✅ 独享、稳定、免费（你本来就有这台机器），HTTPS 证书还是官方的 |

---

## 八、文件说明

```
.
├── SKILL.md                      # 给 AI Agent 用的技能文件（Claude / Hermes 等可直接加载）
├── scripts/
│   ├── deploy-ecs-sni-relay.sh   # 服务端一键部署，带备份与自动回滚
│   └── add-hosts.ps1             # Windows 客户端 hosts 写入（自动备份 + 刷 DNS）
└── LICENSE
```

## License

MIT
