# dsh on fnOS — 原生应用（fpk）

把 DeepSeek 开源的 agent harness（dsh）装成飞牛 fnOS 的原生应用：应用中心点图标就进，
不碰 Docker，不需要每次去命令行取启动令牌。

> **规范底本**：官方文档已逐页核实并整理在 [`../docs/FNOS-OFFICIAL-DOCS.md`](../docs/FNOS-OFFICIAL-DOCS.md)。
> 改 `cmd/`、`config/`、`wizard/` 之前先查那份，不要凭记忆——官方站的关键入口是
> `https://developer.fnnas.com/llms.txt`，`sitemap.xml` 是 404。
>
> **遇到问题先看** [`../docs/ISSUES.md`](../docs/ISSUES.md)：平台限制、已修缺陷、待验证项
> 都在那张表里，多半已经踩过。改动过程记在 [`../docs/DEVLOG.md`](../docs/DEVLOG.md)。

## 装 / 升级（全部在飞牛界面里点，不用命令行）

侧载包没有「检查更新」通道，所以升级 = 卸载 + 装新包，数据会保留：

1. 电脑上打开飞牛 **文件管理 → 共享目录 `dsh / workspace`**，先把 `dsh.fpk` 下载下来
   （**一定要在卸载之前下载**：卸载会把共享目录临时改成 `000`）；
2. **应用中心 → dsh → 卸载**，弹窗里选「**保留会话、凭据与设置**」；
3. **应用中心 → 手动安装 → 选择刚下载的 fpk** → 安装；
   - 向导里 API Key 留空 = 沿用旧值（重装不会把已有的 Key 冲掉）；
   - 「入口方式」保持默认「点图标直接进入」；
4. 装完点图标，直接进 dsh。

共享目录里为什么会有一个 fpk：`build.sh` 打完包会顺手复制过去，省掉 scp 之类的步骤。
不想占这份空间就 `DSH_STAGE=0 bash build.sh full`。

## 打包（只有这一步在命令行）

在 NAS 上，源码目录里：

```bash
cd ~/dsh-fnos/fpk
bash selftest.sh          # 30 秒，不需要 root、不占 3080
bash build.sh full        # 捆绑 node + dsh，产出约 990MB 的 dsh.fpk
```

`full` 会把 `nodejs_v24` 的 node 与 `@deepseek-ai/dsh@0.2.1-rc.3` 装进 `app/runtime/`
（版本钉在 `build.sh` 顶部，可用 `DSH_VERSION=` 覆盖，钉版理由见 PLAN §3.2），
打完自动复制到共享目录。`bash build.sh`（不带参数）只打骨架包，用占位服务验证安装链路。

`selftest.sh` 会伪造 `TRIM_*` 环境，在临时目录里跑一遍
`install_init → install_callback → start → status → HTTP → 重复 start → stop → 重复 stop`，
外加入口跳转器的 HTTP 行为（自动跳转、配对、限速）。直接装 fpk 失败时只能看到一个笼统错误，
自测能精确告诉你是哪一步。

## 入口是怎么做的（0.5.0 起：点图标即进）

dsh 每次启动都会 mint 新 token，且没有「固定令牌」开关，所以入口由一个跳转服务接管：

| 角色 | 端口 | 作用 |
|---|---|---|
| 入口跳转器 | `service_port`（3080） | 读本次启动的令牌，直接 `302` 到 `http://<绑定IP>:3081/?token=…` |
| dsh 本体 | `service_port + 1`（3081） | 真正的 Web UI，仍然要求令牌 |

用户侧的体验就是「点图标 → 进去了」。令牌由 `cmd/main` 启动 dsh 后从日志抓取，
写进 `@appdata/launcher.json`（600，只有应用用户可读），跳转器每次请求现读，所以
**重启应用、重启 NAS 之后书签不用改**——令牌会换，跳转器跟着换。

两个模式（应用设置 → 入口方式）：

| 模式 | 行为 | 适用 |
|---|---|---|
| `auto`（默认） | 内网来源直接进；**公网来源仍要求配对** | 家里/公司局域网 |
| `pair` | 新设备第一次要粘一次令牌，之后 180 天直接进 | 想让入口带一道栅栏 |

`auto` 的安全边界说清楚：能访问到 `NAS:3080` 的内网设备，等于能直接操作 dsh
（它带终端与文件工具）。所以**不要把 3080 映射到公网**；真要从外网用，走 VPN/Tailscale，
或把入口方式改成 `pair`。公网来源不会自动放行，**而且只要请求带了
`X-Forwarded-For` / `X-Real-IP` / `Forwarded` 这类代理头，就一律按"来自反代"处理、要求配对**
（否则反代一挂，公网访客会被当成内网）。这两点都写在代码里，不依赖用户记得。

## 排错

```bash
# 应用日志（安装、启停、失败原因都在这）
tail -n 50 /var/apps/dsh/var/info.log

# 入口状态：ready=跳转器有 state，auto=能自动跳，mode=入口模式
# 0.6.0 起 launcher 同时在 127.0.0.1 上监听（平台上就靠这个判断"在跑"），
# 所以下面这条最简单的写法现在也是通的；0.5.0 及以前它会返回空。
curl -s -o /dev/null -w 'loop=%{http_code}\n' http://127.0.0.1:3080/healthz

# 走绑定地址看完整内容（自动探测的是局域网地址，不是 127.0.0.1）
BIND=$(sed -n 's/^DSH_BIND=//p' /var/apps/dsh/etc/settings.conf | head -n1)
case "$BIND" in ''|auto) BIND=$(sed -n 's/.*bind=\([0-9.]*\).*/\1/p' /var/apps/dsh/var/info.log | tail -n1) ;; esac
curl -s "http://${BIND:-127.0.0.1}:3080/healthz"

# 这一轮的令牌（一般不用看，跳转器自己会用）
cat /var/apps/dsh/var/launcher.json

# 端口有没有被占
ss -ltnp | grep 308

# 进程还在不在
cat /var/apps/dsh/var/dsh.pid && ps -o pid,pgid,cmd -p "$(awk '{print $1}' /var/apps/dsh/var/dsh.pid)"
```

失败时应用中心弹出对话框的内容来自 `TRIM_TEMP_LOGFILE`，也就是 `cmd/main` 里 `say()`
写进去的那段——它一定同时记进了 `info.log`。

真机验收用 `probe/` 下的脚本：

```bash
bash ~/dsh-fnos/probe/05-verify-fpk.sh        # 结构 + 入口端到端（自动跳转、配对、限速）
bash ~/dsh-fnos/probe/07-cookie-persistence.sh # 重启后点图标还能不能进
```

两个脚本都只读（`07` 会重启一次应用，约 10 秒不可用），不写系统目录。

## 目录说明

| 路径 | 作用 |
|---|---|
| `manifest` | 应用元数据。`appname=dsh`、`service_port=3080`、`desktop_applaunchname=dsh.main` |
| `config/privilege` | `run-as: package`，专用用户 `dsh`。**不用 root** |
| `config/resource` | 声明共享目录 `dsh/workspace`，用户可在文件管理里看到 |
| `cmd/main` | 核心。`start\|stop\|status\|restart\|url`，status 返回 0/1/3 |
| `cmd/install_init` | 架构、磁盘（≥1.5GB）、landlock/bwrap 检查 |
| `cmd/install_callback` | 建 `dsh-home`(700)、写 `settings.conf`(600)、chown 给应用用户 |
| `cmd/config_callback` | 改设置：合并配置 → stop → start（入口模式是启动参数） |
| `cmd/uninstall_callback` | 认 `purge`；默认保留共享目录里的 `.dsh-home` |
| `wizard/install` | 收集 API Key、绑定地址、入口方式 |
| `wizard/config` | 同上，留空/「保持不变」= 不改 |
| `wizard/uninstall` | 是否删除数据（默认保留） |
| `app/ui/config` | 桌面入口。key 必须 `appname` 前缀 → `dsh.main` |
| `app/runtime/launcher/` | 入口跳转器（纯 node 内建模块，无依赖） |
| `app/runtime/stub/` | 骨架包的占位服务 |
| `build.sh` | NAS 上打包。`bash build.sh` 骨架 / `bash build.sh full` 捆绑 dsh |
| `selftest.sh` | 安装前自测，见上文 |

## 已知限制

1. **桌面入口的 host 是「浏览器当前地址」，不是 dsh 的绑定地址。** 点图标时系统拼的是
   `http://{你访问飞牛用的 host}:3080/`。这台 NAS 有 `192.168.0.109`（无线）和
   `192.168.0.114`（OVS）两个地址：**从哪个地址进飞牛桌面，就得让 dsh 绑哪个地址**，
   否则点图标打不开。默认策略是「自动探测默认路由源地址」。
2. **端口固定 3080**（跳转器），dsh 在 3081。改端口要先卸载重装（`manifest` 与桌面入口都写死了）。
3. **升级只能卸载重装**：fnOS 的 `appcenter-cli install-fpk` 对已装应用只回一句
   `is installed`，没有 force/upgrade 参数；界面上也没有「重新安装」。数据不丢是因为
   会话与凭据放在共享目录（见 PLAN §2.8）。
4. **绑定地址默认自动探测**，网络未就绪时 `start` 会等最多 60 秒再报错（PLAN §4.2 第 6 条）。

上面四条是使用者会碰到的；平台侧的硬限制（`install-fpk` 静默跳过、`uninstall` 只能走界面、
缺陷 10237、卸载会清空 `@appdata` 等）与已修缺陷的根因，统一记在
[`../docs/ISSUES.md`](../docs/ISSUES.md)。
