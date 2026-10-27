# dsh on fnOS — M1 应用骨架

这是飞牛 fnOS 的 fpk 工程目录。**M1 的目标不是"能用 dsh"，而是先把「安装 → 启停 → 桌面入口 → 开机自启」这条链路验证通**，再往里塞运行时。

所以现在 `app/runtime/` 里只有一个占位服务（stub），点开图标会看到一个说明页。`cmd/main` 已经写好了识别逻辑：一旦 `app/runtime/app/node_modules/@deepseek-ai/dsh` 存在，它会自动切成真正的 dsh。

> **规范底本**：官方文档已逐页核实并整理在 [`../docs/FNOS-OFFICIAL-DOCS.md`](../docs/FNOS-OFFICIAL-DOCS.md)。
> 改 `cmd/`、`config/`、`wizard/` 之前先查那份，不要凭记忆——官方站的关键入口是 `https://developer.fnnas.com/llms.txt`，`sitemap.xml` 是 404。

## 三步

```bash
# 0. 从 Windows 传上去（整个目录）
scp -r E:/Project2/dsh-fnos/fpk root@192.168.0.114:/root/dsh-fnos/

# 1. 先自测（30 秒，不需要 root，不占 3080，不碰 /var/apps）
cd /root/dsh-fnos/fpk && bash selftest.sh

# 2. 打包
bash build.sh

# 3. 安装
appcenter-cli install-fpk ./dsh.fpk
```

`selftest.sh` 会伪造一套 `TRIM_*` 环境，在 `/tmp` 里完整跑一遍
`install_init → install_callback → start → status → HTTP → 重复 start → stop → 重复 stop`。
直接装 fpk 失败时你只能看到一个笼统的错误；自测能精确告诉你是哪一步。

## M1 验收清单

装完后按顺序确认，任何一条不过就先别进 M1b：

| # | 动作 | 期望 |
|---|---|---|
| 1 | 应用中心 → 开发工具 → DeepSeek Harness | 出现卡片，图标正常 |
| 2 | 点「安装」 | 向导显示「DeepSeek API Key」和「监听地址」，装完无报错 |
| 3 | 应用中心 → 启动 | 状态变为运行中 |
| 4 | 点应用图标 | 打开 `http://<飞牛地址>:3080/`；full 包首次会看到「配对这台设备」，粘一次令牌后直接进入 dsh |
| 5 | 应用中心 → 停止 | 状态变为已停止；再点启动能起来 |
| 6 | 重启 NAS | 应用自动拉起（若没起，是开机自启没开，去应用设置里确认） |
| 7 | 看日志 | `/var/apps/dsh/var/info.log` 里有 `install_init` / `install_callback` / `start: ok` 记录 |

第 6 条是 M1 最容易被忽略的一条：**fnOS 没有 systemd 集成，开机自启完全靠应用中心的调度器**。如果它不帮你拉起，`cmd/main start` 写得再好也没用——这件事必须在真机上确认。

## 四个已知限制（都是刻意留到后面的）

1. **端口固定 3080，但 3080 上跑的不是 dsh。** `manifest.service_port`、`app/ui/config` 的 `port`、`settings.conf` 三处一致指向 3080，那个端口归**入口跳转器**；dsh 本体内移到 `3080+1`。这样点图标进来的是跳转器，它能带上本次启动的令牌。跳转器只做 `302`，不代理业务流量（见 PLAN §5.1）。
2. **桌面入口的 host 是「浏览器当前地址」，不是 dsh 的绑定地址。** 点图标时系统拼的是 `http://{你访问飞牛用的 host}:3080/`。这台 NAS 有 `192.168.0.109`（无线）和 `192.168.0.114`（OVS）两个地址：**从哪个地址进飞牛桌面，就得让 dsh 绑哪个地址**，否则点图标打不开。默认策略是"自动探测默认路由源地址"，另一个地址访问就会失败。
3. **M1 不捆绑 dsh。** 页面是占位服务，不消耗内存也没有沙箱。
4. **绑定地址默认自动探测**，网络未就绪时 `start` 会等最多 60 秒再报错（对应 PLAN §4.2 第 6 条）。

## 入口怎么进（0.4.0 起）

dsh 每次启动都会 mint 新令牌，且没有「固定令牌」开关，所以入口由一个小跳转服务接管：

| 角色 | 端口 | 作用 |
|---|---|---|
| 入口跳转器 | `service_port`（3080） | 已配对设备直接 `302` 到 dsh；未配对设备看到「粘贴入口令牌」页 |
| dsh 本体 | `service_port + 1`（3081） | 真正的 Web UI，仍然要求令牌 |

首次在新设备打开：`cat /var/apps/dsh/var/dsh-url.txt`（或 `cmd/main url`），把整条地址粘进配对页。
配对成功后下发 180 天的 `dsh_gate` cookie，之后点图标即可直接进入；换浏览器/换设备才需要再来一次。

## 排错

```bash
# 应用日志（安装、启停、失败原因都在这）
tail -n 50 /var/apps/dsh/var/info.log

# 端口有没有被占
ss -ltnp | grep 3080

# 进程还在不在
cat /var/apps/dsh/var/dsh.pid && ps -o pid,pgid,cmd -p "$(awk '{print $1}' /var/apps/dsh/var/dsh.pid)"
```

失败时应用中心弹出的对话框内容来自 `TRIM_TEMP_LOGFILE`，也就是 `cmd/main` 里 `say()` 写进去的那段——它一定同时记进了 `info.log`。

## 目录说明

| 路径 | 作用 |
|---|---|
| `manifest` | 应用元数据。`appname=dsh`、`service_port=3080`、`desktop_applaunchname=dsh.main` |
| `config/privilege` | `run-as: package`，专用用户 `dsh`。**不用 root** |
| `config/resource` | 声明共享目录 `dsh/workspace`，用户可在文件管理里看到 |
| `cmd/main` | 核心。`start\|stop\|status\|restart`，status 返回 0/3 |
| `cmd/install_init` | 架构、磁盘（≥1.5GB）、landlock/bwrap 检查 |
| `cmd/install_callback` | 建 `dsh-home`(700)、写 `settings.conf`(600)、chown 给应用用户 |
| `cmd/upgrade_*` | 停机 → 快照 → 移走旧 runtime → 校验新 runtime → 启动 |
| `cmd/config_*` | 改绑定时停服务、合并配置、重启 |
| `wizard/install` | 收集 API Key、绑定地址 |
| `wizard/config` | 同上，留空表示保持不变 |
| `wizard/uninstall` | 是否删除数据（默认保留） |
| `app/ui/config` | 桌面入口。key 必须 `appname` 前缀 → `dsh.main` |
| `app/runtime/stub/` | M1 占位服务，M1b 后删除 |
| `build.sh` | NAS 上打包。`bash build.sh` 骨架 / `bash build.sh full` 捆绑 dsh |
| `selftest.sh` | 安装前自测，见上文 |

## 下一步（M1b）

```bash
bash build.sh full
```

它会把 `nodejs_v24` 的 node 二进制和 `@deepseek-ai/dsh@0.2.1-rc.3`（版本钉在 `build.sh` 顶部，
可用 `DSH_VERSION=` 覆盖；钉版理由见 PLAN §3.2）装进 `app/runtime/`，产出约 990MB / 6 万+ 文件的包。这一步要验证的是 PLAN §6.1 里那个没答案的问题：**fnOS 能不能顺利装下六万个文件**。

如果 `full` 包安装超时或失败，退路是在 `install_callback` 里解 `app.tar.zst`，而不是让 fnpack 直接打散六万个文件。
