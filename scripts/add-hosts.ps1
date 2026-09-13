<#
.SYNOPSIS
  把被阻断的 GitHub 域名指向自有 ECS（github-sni-relay 客户端侧）。

.DESCRIPTION
  自动备份 hosts -> 写入条目 -> 刷新 DNS 缓存。
  必须以管理员权限运行（脚本会自行检查并提示）。

.PARAMETER RelayIp
  ECS 的公网 IP，例如 203.0.113.10

.PARAMETER Domains
  要指向 ECS 的域名，默认只加被阻断的那几个。
  注意：api.github.com / codeload.github.com / *.githubusercontent.com 通常本来就能直连，
  不要加进来（直连更快）。

.EXAMPLE
  powershell -NoProfile -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','add-hosts.ps1','-RelayIp','203.0.113.10'"
#>
param(
    [Parameter(Mandatory = $true)][string]$RelayIp,
    [string[]]$Domains = @('github.com', 'www.github.com', 'collector.github.com')
)

$ErrorActionPreference = 'Stop'

# --- 管理员检查 ---
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "!! 需要管理员权限：请右键 PowerShell『以管理员身份运行』，或用 Start-Process -Verb RunAs 调用本脚本。" -ForegroundColor Red
    exit 1
}

# --- IP 格式校验（避免把错误的值写进 hosts）---
if ($RelayIp -notmatch '^(\d{1,3}\.){3}\d{1,3}$') {
    Write-Host "!! RelayIp 不是合法的 IPv4 地址：$RelayIp" -ForegroundColor Red
    exit 1
}

$hosts = "$env:SystemRoot\System32\drivers\etc\hosts"
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$backup = "$hosts.bak_$stamp"

Copy-Item $hosts $backup -Force
Write-Host "已备份 hosts -> $backup"

# --- 先清掉本项目之前写过的条目，保证可重复执行 ---
$markerBegin = '# === github-sni-relay BEGIN ==='
$markerEnd   = '# === github-sni-relay END ==='
$lines = Get-Content $hosts | Where-Object {
    $_ -notmatch [regex]::Escape($markerBegin) -and
    $_ -notmatch [regex]::Escape($markerEnd) -and
    $_ -notmatch "^\s*$([regex]::Escape($RelayIp))\s+.*github\.com\s*$"
}

$block = @($markerBegin)
foreach ($d in $Domains) { $block += "$RelayIp $d" }
$block += $markerEnd

($lines + $block) | Set-Content -Path $hosts -Encoding ASCII

ipconfig /flushdns | Out-Null
Write-Host "已写入 $($Domains.Count) 条记录并刷新 DNS。" -ForegroundColor Green

Write-Host "`n验证："
foreach ($d in $Domains) {
    try {
        $r = Resolve-DnsName $d -Type A -ErrorAction Stop |
             Where-Object { $_.IPAddress } | Select-Object -First 1
        Write-Host ("  {0,-28} -> {1}" -f $d, $r.IPAddress)
    } catch {
        Write-Host ("  {0,-28} -> 解析失败" -f $d)
    }
}
