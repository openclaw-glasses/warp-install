# warp-install

跨平台一键搭建 Cloudflare WARP SOCKS5 代理的安装项目。

## 目标

- 支持 **Linux / macOS / Windows**
- 支持 **交互式安装**
- 用户可自行选择：
  - 端口
  - 用户名
  - 密码
- 自动检测 Docker
- 尽可能帮助安装 Docker
- 尽可能处理镜像拉取过慢问题
- 最终一键拉起一个可用的 WARP 代理

## 当前结构

- `install.sh`：Linux / macOS 安装脚本
- `install.ps1`：Windows PowerShell 安装脚本
- `uninstall.sh`：Linux / macOS 卸载脚本
- `uninstall.ps1`：Windows PowerShell 卸载脚本
- `compose.yaml`：Compose 模板
- `config.env`：Linux/macOS 安装后生成的本地配置文件
- `config.env.ps1`：Windows 安装后生成的本地配置文件

## 默认行为

脚本会交互式询问：

- 容器名
- 对外端口
- SOCKS5 用户名
- SOCKS5 密码
- 数据目录
- 是否使用镜像加速前缀
- 是否保存密码到本地配置文件

默认示例值：

- 端口：`1080`
- 用户名：`admin`
- 密码：`admin`
- 容器名：`warp`

## 运行方式

### Linux / macOS

```bash
chmod +x ./install.sh ./uninstall.sh
./install.sh
```

### Windows PowerShell

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

## 持久化说明

安装完成后，脚本会把常用参数保存到本地配置文件：

- 容器名
- 对外端口
- 用户名
- 数据目录
- WARP_SLEEP
- 镜像前缀
- 实际成功使用的镜像地址

密码默认**不建议落盘**，但用户可以选择保存。

这样后续重装、升级、卸载时，脚本可以直接复用原配置。

## 兼容性说明

### Linux

- 优先支持已安装 Docker 的环境
- 若未安装 Docker，会尝试使用系统包管理器进行安装：
  - apt
  - dnf
  - yum
  - zypper
  - pacman

### macOS

- 若已安装 Docker Desktop，可直接使用
- 若未安装，会尝试使用 `brew install --cask docker`
- 安装后通常仍需要用户手动启动 Docker Desktop 一次

### Windows

- 若已安装 Docker Desktop，可直接使用
- 若未安装，会尝试：
  - `winget install Docker.DockerDesktop`
  - 或 `choco install docker-desktop -y`
- 安装后通常需要用户手动启动 Docker Desktop

## 镜像加速策略

脚本不是强依赖某一个 Docker daemon 镜像源，而是采用更稳的策略：

默认内置拉取优先级：

1. 如果用户提供镜像前缀，则先尝试：
   - `<prefix>/caomingjun/warp:latest`
2. 再尝试：
   - `docker.1ms.run/caomingjun/warp:latest`
3. 再尝试：
   - `docker-cf.registry.cyou/caomingjun/warp:latest`
4. 最后回退：
   - `caomingjun/warp:latest`

其中：
- `docker.1ms.run`：实测可用，且 `latest` digest 与 Docker Hub 上游一致
- `docker-cf.registry.cyou`：实测可用，且 `latest` digest 与 Docker Hub 上游一致

这样在不同机器上兼容性更强，也避免直接改坏系统 Docker 配置。

## 卸载

### Linux / macOS

```bash
./uninstall.sh
```

### Windows PowerShell

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
```

卸载脚本会：
- 删除容器
- 可选删除数据目录（删除后会丢失 WARP 注册状态）

## Compose

也可以使用 `compose.yaml`：

```bash
docker compose up -d
```

但如果你希望交互式选择参数、自动检测 Docker、自动镜像 fallback，还是更推荐 `install.sh / install.ps1`。

## 生产建议

- 不要使用默认的 `admin/admin`
- 生产环境请改成强密码
- 若对公网开放，请再加一层防火墙/IP 限制

## 运行结果

安装成功后，脚本会自动：

- 启动容器
- 等待健康检查
- 通过代理访问 `https://www.cloudflare.com/cdn-cgi/trace`
- 输出可直接复制的连接信息

## 后续可继续增强

- Docker 安装逻辑再工业化
- 多镜像源测速与智能选择
- 升级脚本
- GUI 包装器
