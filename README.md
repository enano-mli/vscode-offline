# vscode-offline

VS Code 离线部署工具集：一个脚本帮你在联网机器上下载、打包 VS Code Server / Windows 安装包 / 插件，然后拿到离线（内网）机器上使用。适合无法直连外网的服务器、隔离开发环境等场景。

核心是 [`vscs.sh`](vscs.sh) —— 一个纯 Bash 脚本，仅依赖 `curl` 或 `wget`。

## 适用范围

- ✅ Linux **glibc ≥ 2.28**（Debian 10+、Ubuntu 18.04+、RHEL 8+ 等），VS Code 客户端 **1.86+** 的新版 server/cli 目录布局
- ✅ CPU 架构：x64 / arm64 / armhf
- ❌ 老系统（CentOS 7 等 glibc 2.17）：VS Code 上限 1.85.2，需用钉版本方案，本脚本不适用
- ❌ musl / Alpine：Remote-SSH 官方没有 musl server

## 快速开始

### 1. 打包 VS Code Server（联网机）

```bash
./vscs.sh download                 # stable 最新版 + x64
./vscs.sh download --arch arm64    # 指定架构
./vscs.sh download --quality insider
./vscs.sh download --commit <40位commit id>   # 钉某个具体版本
```

产物是一个**自解压安装脚本**（内嵌 server + cli 两个 tar），单文件即可拷贝，默认命名：

```
vscode-server-<quality>-<arch>-<commit12>.install.sh
```

### 2. 离线机安装

```bash
bash vscode-server-stable-x64-XXXXXXXXXXXX.install.sh
# 或指定安装根目录：
bash xxx.install.sh --home /custom/VSCODE_HOME
```

默认安装到 `~/.vscode-server/`（insider 为 `~/.vscode-server-insiders/`）。之后用 1.86+ 的 VS Code 客户端 Remote-SSH 连接即可，不会再触发在线下载。

### 3. Windows 安装包（可选）

```bash
./vscs.sh windows                  # 最新 stable x64 用户安装包
./vscs.sh windows --quality insider
```

下载 `VSCodeUserSetup-x64-<版本>.exe`，并做官方 sha256 校验。

### 4. 批量下载插件（可选）

只下载 vsix，离线机上自行安装：

```bash
./vscs.sh extensions ms-vscode.cpptools golang.Go
./vscs.sh extensions -f extensions.txt
```

清单文件格式（`#` 为注释）：

```
publisher.name                # 最新版 + 目标架构（自动 platform 回退）
publisher.name@1.21.2         # 钉版本
publisher.name/linux-x64      # 强制平台
```

已存在且版本匹配的 vsix 自动跳过，损坏的重下；钉的版本落后于最新版时打印警告。离线安装：

```bash
code --install-extension <plugin>.vsix
```

## 版本对应关系

`install.sh` 文件名中的 12 位 commit 前缀即该 server 的版本指纹，可与客户端版本互相核对，例如 `a44adf7f53e0` 对应 stable **1.136.1**。客户端与 server 的 commit 必须一致，Remote-SSH 才能直接使用。

## 目录建议

`.install.sh` / `.exe` / `.vsix` 等产物体积较大，建议加入 `.gitignore`，不要提交到仓库（见 [.gitignore](.gitignore)）。

## License

MIT
