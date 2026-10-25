# AgentBridge Dist

AgentBridge 的 Linux 二进制分发仓库。新服务器无需克隆源码仓库：下载本仓库的 `manage.sh`，即可自动获取 GitHub Releases 中的最新预编译程序，并完成配置、启动、停止、日志查看和更新。

- 管理脚本：<https://github.com/suwei8/agent-bridge-dist/blob/main/manage.sh>
- 最新 Release：<https://github.com/suwei8/agent-bridge-dist/releases/latest>
- 管理脚本原始下载地址：<https://raw.githubusercontent.com/suwei8/agent-bridge-dist/main/manage.sh>

## 1. 系统要求

- Ubuntu / Debian Linux（脚本使用 `apt-get` 和 `dpkg` 安装、检查依赖）。
- 支持的目标架构为 x86_64/amd64 和 ARM64/aarch64。
- 普通 Linux 用户账号，并具有 `sudo` 权限。
- 能访问 `github.com`、`raw.githubusercontent.com` 和 `api.github.com`。
- 根分区和 `/tmp` 各至少有 512 MB 可用空间；部署脚本会检查磁盘空间。
- 需要接收 Telegram 通知时，准备自己的 Telegram Bot Token 和 Chat ID。

建议以普通用户运行 AgentBridge。不要为了方便而把整个服务作为 root 运行。

## 2. 干净环境安装

以下命令适用于新建的 Ubuntu / Debian 服务器。先安装基础依赖，再下载管理脚本：

~~~bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl python3 python3-dev

mkdir -p "$HOME/agent-bridge"
cd "$HOME/agent-bridge"

curl -fL --retry 3 --connect-timeout 10 \
  -o manage.sh \
  https://raw.githubusercontent.com/suwei8/agent-bridge-dist/main/manage.sh

# 先检查语法，再执行
bash -n manage.sh
chmod 700 manage.sh
~~~

如果 `bash -n manage.sh` 没有输出且退出码为 0，表示语法检查通过。若下载失败，不要执行不完整的文件；先检查网络和下载地址。

## 3. 部署程序

### 3.1 配置 Telegram 接收者

首次部署会交互式询问 `TELEGRAM_BOT_TOKEN`，并生成当前目录下的 `.env` 配置文件。

**请在启动前确认 `TELEGRAM_CHAT_ID` 是你自己的接收者 ID。** 当前管理脚本包含内置的默认 Chat ID；如果不想使用该默认接收者，请在部署前设置自己的 ID：

~~~bash
cd "$HOME/agent-bridge"
export TELEGRAM_CHAT_ID="替换为你自己的TelegramChatID"
./manage.sh deploy
~~~

执行后，按提示输入自己的 Telegram Bot Token。也可以先执行部署，再编辑 `.env`，但必须在启动程序前完成检查：

~~~bash
nano .env
~~~

至少检查以下配置项：

- `TELEGRAM_BOT_TOKEN`：自己的 Bot Token，不要公开或提交到 GitHub。
- `TELEGRAM_CHAT_ID`：自己的 Chat ID，不要保留不希望使用的默认接收者。
- `CLI_CWD`：AgentBridge 执行 CLI 工作的目录。脚本默认值为 `/home/sw/dev_root/`；新服务器若使用其他目录，请改成实际存在、且当前运行用户有权限访问的目录。
- `DEFAULT_CLI_PROFILE`：默认 CLI 配置。脚本默认值为 `devin_cli`；所选 CLI 必须已经安装并能在该用户的 PATH 中运行。

保存后收紧配置文件权限：

~~~bash
chmod 600 .env
~~~

### 3.2 下载并启动

部署命令会检查磁盘空间、检查或安装脚本所需依赖、查询最新 Release、按机器架构下载预编译二进制，并在存在对应校验文件时验证 SHA-256。部署完成后，**首次部署不会自动启动程序**，需要单独启动：

~~~bash
cd "$HOME/agent-bridge"
./manage.sh start
~~~

也可以运行不带参数的管理菜单：

~~~bash
./manage.sh
~~~

然后根据菜单选择部署、启动、停止、重启、查看日志、更新或切换 CLI 模式。

## 4. 常用管理命令

请在保存了 `manage.sh` 的安装目录中执行：

| 命令 | 作用 |
| --- | --- |
| `./manage.sh deploy` | 下载并部署最新版本，必要时创建或补充 `.env` |
| `./manage.sh start` | 启动程序 |
| `./manage.sh stop` | 停止程序 |
| `./manage.sh restart` | 重启程序 |
| `./manage.sh logs` | 实时查看日志；按 Ctrl+C 只退出日志查看 |
| `./manage.sh update` | 更新管理脚本和程序，然后尝试启动 |
| `./manage.sh switch_mode` | 交互式切换默认 CLI 档位 |
| `./manage.sh refresh_script` | 从 GitHub 刷新管理脚本 |

程序和运行文件默认保存在管理脚本所在目录，包括二进制文件、`.env`、`app.log`、`app.pid` 和版本标记文件。请保留该目录，不要只移动或删除 `manage.sh`。

查看最近日志：

~~~bash
tail -n 100 app.log
~~~

确认 PID 文件中的进程是否存在：

~~~bash
if [ -f app.pid ]; then
  ps -p "$(cat app.pid)" -o pid=,args=
else
  echo "未找到 app.pid"
fi
~~~

## 5. GitHub Token 是否必需？

通常不需要。该分发仓库和 Releases 是公开的，脚本可以匿名查询公开 Release 并下载资产。只有在 GitHub API 匿名请求被限流等情况下，才考虑提供有适当读取权限的 `GITHUB_TOKEN`。最新版 `manage.sh` 遇到带 Token 的 HTTP 错误时，会尝试匿名访问公开资源；旧版脚本如果因失效 Token 报 HTTP 401，可先备份并移走 `.agentbridge-github.env`，再更新管理脚本。

不要把 Token 写入公开文件、命令截图或提交到仓库。若使用 Token，请优先通过当前 shell 的环境变量传入，并在使用后按需取消：

~~~bash
export GITHUB_TOKEN="你的GitHub读取Token"
./manage.sh deploy
unset GITHUB_TOKEN
~~~

不要为了下载公开发布资产而提供不必要的写入权限。

## 6. 架构与 CLI 注意事项

- `uname -m` 输出 `x86_64` 时，脚本选择 `agent-bridge-linux-amd64`。
- 其他架构会被脚本归到 `agent-bridge` 资产；目前只应按 x86_64/amd64 或 ARM64/aarch64 环境使用，不要假定其他架构也受支持。
- AgentBridge 会调用配置中指定的 CLI。请提前安装并验证你打算使用的 CLI（例如 Devin、OpenCode、Codex、Claude、Cline 或 Kilo），并确认服务运行用户可以执行它。
- 默认工作目录是 `/home/sw/dev_root/`，请按实际服务器路径修改 `.env`。
- 脚本默认写入 `CLI_EXEC_MODE=YOLO`。这可能允许 CLI 在没有逐步确认的情况下执行操作；请先了解所选 CLI 对该模式的具体含义。建议在隔离、低权限的专用账号或测试环境中使用，不要在含有生产密钥或敏感数据的环境中盲目启用自动执行。

## 7. 故障排查

### 下载管理脚本失败

检查服务器是否能访问原始文件地址：

~~~bash
curl -fL --retry 3 \
  -o manage.sh \
  https://raw.githubusercontent.com/suwei8/agent-bridge-dist/main/manage.sh
~~~

### 部署时报磁盘空间不足

~~~bash
df -h / /tmp
~~~

先释放空间，再重新运行部署命令。

### 找不到最新 Release 或下载失败

检查 GitHub 网络连通性、API 是否被限流，以及目标架构是否有对应的 Release 资产。公开仓库一般不需要 Token。

### 程序启动失败

~~~bash
tail -n 200 app.log
cat .env
~~~

检查 `.env` 是否存在、Telegram 配置是否正确、`CLI_CWD` 是否有效，以及所选 CLI 是否已安装并能由当前用户执行。分享日志前请先删除 Token、密钥及其他敏感信息。

## 8. 重启后自动启动

`manage.sh start` 会在后台启动程序，但当前脚本本身**不会创建 systemd 服务，也不会自动配置开机启动**。如果需要开机自动启动，请另外配置并测试 systemd 服务；不要假设仅执行一次 `start` 就能在服务器重启后自动恢复。
