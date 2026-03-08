$ErrorActionPreference = 'Stop'

$ScriptDir = $PSScriptRoot
$ConfigFile = Join-Path $ScriptDir 'config.env.ps1'
$DefaultContainerName = 'warp'
$DefaultImage = 'caomingjun/warp:latest'
$DefaultPort = '1080'
$DefaultUser = 'admin'
$DefaultPass = 'admin'
$DefaultDataDir = Join-Path $PSScriptRoot 'data'
$DefaultWarpSleep = '10'
$DefaultMirrorPrefix = ''

function Say($msg) { Write-Host $msg }
function Warn($msg) { Write-Host "[warn] $msg" -ForegroundColor Yellow }
function Fail($msg) { throw $msg }
function Prompt-Default($prompt, $defaultValue) {
  $v = Read-Host "$prompt [$defaultValue]"
  if ([string]::IsNullOrWhiteSpace($v)) { return $defaultValue }
  return $v
}
function Prompt-YesNo($prompt, $defaultValue) {
  $v = Read-Host "$prompt [$defaultValue]"
  if ([string]::IsNullOrWhiteSpace($v)) { $v = $defaultValue }
  if ($v -match '^(y|Y|yes|YES)$') { return 'y' }
  return 'n'
}
function Load-Config {
  if (Test-Path $ConfigFile) {
    . $ConfigFile
    Say "[info] 已加载本地配置：$ConfigFile"
  }
}
function Save-Config($savePassword) {
@"
`$CONTAINER_NAME = '$($script:CONTAINER_NAME)'
`$EXTERNAL_PORT = '$($script:EXTERNAL_PORT)'
`$SOCKS_USER = '$($script:SOCKS_USER)'
`$DATA_DIR = '$($script:DATA_DIR)'
`$WARP_SLEEP = '$($script:WARP_SLEEP)'
`$MIRROR_PREFIX = '$($script:MIRROR_PREFIX)'
`$IMAGE = '$($script:IMAGE)'
`$SAVE_PASSWORD = '$savePassword'
"@ | Set-Content -Path $ConfigFile -Encoding UTF8
  if ($savePassword -eq 'y') {
    Add-Content -Path $ConfigFile -Value "`$SOCKS_PASS = '$($script:SOCKS_PASS)'"
  }
  Say "[info] 配置已保存：$ConfigFile"
}
function Ensure-Docker {
  if (Get-Command docker -ErrorAction SilentlyContinue) { return }
  Say '[info] Docker 未检测到，尝试自动安装...'
  if (Get-Command winget -ErrorAction SilentlyContinue) {
    winget install -e --id Docker.DockerDesktop
    Warn 'Docker Desktop 已尝试安装，请手动启动 Docker Desktop 后重新运行本脚本。'
    exit 0
  }
  if (Get-Command choco -ErrorAction SilentlyContinue) {
    choco install docker-desktop -y
    Warn 'Docker Desktop 已尝试安装，请手动启动 Docker Desktop 后重新运行本脚本。'
    exit 0
  }
  Fail '未检测到 winget/choco，无法自动安装 Docker。请先安装 Docker Desktop。'
}
function Ensure-Docker-Running {
  try { docker info | Out-Null } catch { Fail 'Docker 已安装，但 daemon 不可用。请先启动 Docker Desktop。' }
}
function Pull-Image($image, $mirrorPrefix) {
  $candidates = @()
  if (-not [string]::IsNullOrWhiteSpace($mirrorPrefix)) { $candidates += (($mirrorPrefix.TrimEnd('/')) + '/' + $image) }
  $candidates += @("docker.1ms.run/$image", "docker-cf.registry.cyou/$image", $image)
  foreach ($candidate in $candidates) {
    Say "[info] 尝试拉取镜像：$candidate"
    try {
      docker pull $candidate | Out-Null
      Say "[info] 镜像拉取成功：$candidate"
      return $candidate
    } catch {
      Warn "拉取失败：$candidate"
    }
  }
  Fail '所有候选镜像源都拉取失败。'
}
function Wait-Healthy($containerName) {
  Say '[info] 等待容器健康检查通过...'
  for ($i = 0; $i -lt 36; $i++) {
    $status = docker inspect $containerName --format '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}nohealth{{end}}'
    Say "  - $status"
    if ($status -eq 'running|healthy' -or $status -eq 'running|nohealth') { return }
    Start-Sleep -Seconds 5
  }
  docker logs --tail 100 $containerName
  Fail '容器未在预期时间内进入健康状态。'
}
function Proxy-Test($user, $pass, $port) {
  Say '[info] 通过代理做出网测试...'
  curl.exe --max-time 30 --proxy "socks5h://$user`:$pass@127.0.0.1`:$port" https://www.cloudflare.com/cdn-cgi/trace
}

Say '=== WARP 一键安装器（Windows） ==='
Load-Config
Ensure-Docker
Ensure-Docker-Running

$script:CONTAINER_NAME = Prompt-Default '容器名' $(if ($CONTAINER_NAME) { $CONTAINER_NAME } else { $DefaultContainerName })
$script:EXTERNAL_PORT = Prompt-Default '对外端口' $(if ($EXTERNAL_PORT) { $EXTERNAL_PORT } else { $DefaultPort })
$script:SOCKS_USER = Prompt-Default 'SOCKS5 用户名' $(if ($SOCKS_USER) { $SOCKS_USER } else { $DefaultUser })
$script:SOCKS_PASS = Prompt-Default 'SOCKS5 密码' $(if ($SOCKS_PASS) { $SOCKS_PASS } else { $DefaultPass })
$script:DATA_DIR = Prompt-Default '数据目录' $(if ($DATA_DIR) { $DATA_DIR } else { $DefaultDataDir })
$script:WARP_SLEEP = Prompt-Default 'WARP_SLEEP' $(if ($WARP_SLEEP) { $WARP_SLEEP } else { $DefaultWarpSleep })
$script:MIRROR_PREFIX = Prompt-Default '镜像加速前缀（可留空，例如 docker.1ms.run）' $(if ($MIRROR_PREFIX) { $MIRROR_PREFIX } else { $DefaultMirrorPrefix })
$savePassword = Prompt-YesNo '是否把密码保存到本地配置文件' $(if ($SAVE_PASSWORD) { $SAVE_PASSWORD } else { 'n' })

New-Item -ItemType Directory -Force -Path $script:DATA_DIR | Out-Null
$script:IMAGE = Pull-Image $DefaultImage $script:MIRROR_PREFIX

$existing = docker ps -a --format '{{.Names}}' | Where-Object { $_ -eq $script:CONTAINER_NAME }
if ($existing) {
  Warn "发现已存在容器：$($script:CONTAINER_NAME)，准备重建。"
  docker rm -f $script:CONTAINER_NAME | Out-Null
}

Say "[info] 启动容器：$($script:CONTAINER_NAME)"
docker run -d `
  --name $script:CONTAINER_NAME `
  --privileged `
  --cap-add NET_ADMIN `
  --cap-add AUDIT_WRITE `
  --cap-add MKNOD `
  --device-cgroup-rule 'c 10:200 rwm' `
  --sysctl net.ipv4.conf.all.src_valid_mark=1 `
  --sysctl net.ipv6.conf.all.disable_ipv6=0 `
  --security-opt label=disable `
  --restart always `
  -p "$($script:EXTERNAL_PORT):1080" `
  -e "WARP_SLEEP=$($script:WARP_SLEEP)" `
  -e "GOST_ARGS=-L socks5://$($script:SOCKS_USER)`:$($script:SOCKS_PASS)@:1080" `
  -v "${script:DATA_DIR}:/var/lib/cloudflare-warp" `
  $script:IMAGE | Out-Null

Wait-Healthy $script:CONTAINER_NAME
Proxy-Test $script:SOCKS_USER $script:SOCKS_PASS $script:EXTERNAL_PORT
Save-Config $savePassword

Write-Host ''
Write-Host '[done] 安装完成'
Write-Host "**协议**：socks5"
Write-Host "**地址**：127.0.0.1:$($script:EXTERNAL_PORT)"
Write-Host "**用户名**：$($script:SOCKS_USER)"
Write-Host "**密码**：$($script:SOCKS_PASS)"
Write-Host "**容器名**：$($script:CONTAINER_NAME)"
Write-Host "**数据目录**：$($script:DATA_DIR)"
Write-Host "**配置文件**：$ConfigFile"
