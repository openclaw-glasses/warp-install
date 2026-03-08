$ErrorActionPreference = 'Stop'
$ScriptDir = $PSScriptRoot
$ConfigFile = Join-Path $ScriptDir 'config.env.ps1'
$ContainerName = 'warp'
$DataDir = Join-Path $ScriptDir 'data'
if (Test-Path $ConfigFile) { . $ConfigFile }
$removeData = Read-Host '是否删除数据目录（会丢失 WARP 注册状态） [n]'
if ([string]::IsNullOrWhiteSpace($removeData)) { $removeData = 'n' }
$existing = docker ps -a --format '{{.Names}}' | Where-Object { $_ -eq $ContainerName }
if ($existing) {
  docker rm -f $ContainerName | Out-Null
  Write-Host "[done] 已删除容器：$ContainerName"
} else {
  Write-Host "[info] 未发现容器：$ContainerName"
}
if ($removeData -match '^(y|Y|yes|YES)$' -and (Test-Path $DataDir)) {
  Remove-Item -Recurse -Force $DataDir
  Write-Host "[done] 已删除数据目录：$DataDir"
}
