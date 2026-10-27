# 开发记录

按时间顺序记「做了什么、为什么这么做、怎么验证的」。只记决策与结果，不贴大段代码——
代码在 git 里，踩坑的根因在 [ISSUES.md](ISSUES.md)。

**记录口径**：2026-10-27 建仓之前的回合发生在当天白天，没有 git 提交可查，依据是当时的
真机输出与 [PLAN.md](../PLAN.md) §2 的事实核查章节；建仓之后的记录按提交号索引。

环境：飞牛 fnOS（主机名 `FNOS`，11.7GB 内存 / 8 核，网卡 `192.168.0.109` 无线、
`192.168.0.114` OVS）；开发机 Windows + Git Bash；仓库 `http://192.168.0.114:3000/T366/dsh-fnos`。

---

## 阶段 0：能不能不用 Docker（2026-10-27 上午）

先确认技术前提，避免走错路：

| 检查 | 结果 |
|---|---|
| fpk 是否支持自定义进程 | 支持。`cmd/main start\|stop\|status`，**没有 systemd 集成** |
| Landlock / bwrap（dsh 的沙箱依赖） | 均可用，root 与 `nobody` 下都通过 |
| 系统 Node | `nodejs_v24` = 24.22.1-1，够用，但**不在 PATH** |
| dsh 是否支持局域网 | 支持 `--host <IP>`，但**拒绝 `0.0.0.0`** |
| dsh 是否需要 Docker | 不需要 |

结论：**能做**。剩下的是工程问题（体积、入口、升级），不是可行性问题。

## 阶段 1：真机评估与冒烟（同日上午/中午）

- 阶段一（只读体检）**19 OK / 0 FAIL**；阶段二（冒烟）**11 OK / 0 FAIL**。
- dsh `0.2.1-rc.2` 安装体积 **866MB / 63053 个文件**，冷启约 **3s**，RSS **406MB**。
- 这一步定了两件事：**运行时自带 Node**（系统那个是"可被卸载的商店应用"，只省 13% 体积，
  换来一个隐性依赖，不划算）；**数据必须落共享目录**（后面 P6 才验证原因）。

## 阶段 2：M1 骨架包 0.1.0（17:10）

用占位服务（stub）先把安装链路跑通，不背 990MB 的包。

装成后立刻暴露三个问题，全部记进 [ISSUES](ISSUES.md)：

1. `status` 返回 **3**，但进程在跑（F1，路径写法比对）；
2. 打包后 `manifest` 被 **fnpack 重写**，探针 `grep '^service_port='` 静默取空（P4）；
3. `config/`、`wizard/` 装完变 **644**（P5）。

修完复验：`PASS 23 / WARN 3 / FAIL 0`，`status=0`，监听 `192.168.0.114:3080`，HTTP 200。

## 阶段 3：升级到底怎么做（17:25–17:30）——推翻了原计划

原方案假定「fpk 覆盖升级」。实测推翻了它：

- `install-fpk` 对已装应用只回 `is installed`，**没有 force/upgrade**，`upgrade_*` 钩子走不到（P1）；
- `install-local` 会先卸载，但触发平台缺陷 **10237**（临时目录丢 x 位）（P3）；
- CLI `uninstall` 拒绝手动安装的应用，**只能走 Web UI**（P2）。

于是升级流程改成「界面卸载（保留）+ 界面手动安装」，并在 `build.sh` 里加了
「包版本 vs 已装版本」的比对警告，避免同版本白装一次。

> 这期间 `probe/06-upgrade-truth.sh` 出现过一次**假阳性**：卸载被拒、脚本仍判「数据全存活」。
> 现在它带门禁——没看到 `/var/apps/dsh` 消失就判实验无效。教训：**实验脚本必须能证明自己真的做了那件事**。

## 阶段 4：0.2.0——把数据搬到共享目录（17:30–17:37）

用界面卸载做了一次真实实验，得到 P6 那张表：`@appdata` 目录还在但**内容被清空**，
`@appshare` 被 `chmod 000` 但**内部文件存活**。

所以 0.2.0 把 `dsh-home` 与配置副本搬到共享目录 `.dsh-home`（700），配置双写
（`@appconf` + 副本），读取时先 `@appconf` 再副本。重装后会话与 Key 恢复，验证通过。

## 阶段 5：0.4.0——入口跳转器（19:29 建仓 ~ 19:36）

**用户的原话**：「每次通过命令获取启动令牌很麻烦」。查过 dsh 的 web profile：只有
`--host/--port/--tls-cert/--tls-key/--public-url/--trusted-host/--no-open`，
**没有固定令牌开关**，令牌每次启动随机 mint。

方案按用户选择走 **B：跳转器 + 设备白名单**：

- 跳转器占 `service_port`（3080），dsh 退到 3081；
- 未配对访客只看到粘贴页，不泄露任何信息；
- 令牌**不落盘解析**：拿去请求 `127.0.0.1:3081`，回 3xx 即通过；
- 配对成功签 `dsh_gate`（HttpOnly / SameSite=Lax / 180 天 / HMAC），密钥 `@appdata/launcher-secret`（600）；
- 同 IP 5 次失败 → 429，窗口 10 分钟；
- 只 `302`，**不代理业务流量**（代理要改 Host，会破坏 dsh 的 Host/Origin 栅栏）。

同时把仓库建起来：`d54e6db` 初始提交（38 文件 / 400KB），`.gitattributes` 钉 LF，
`cmd/*` 补可执行位，推送到 `T366/dsh-fnos`。

随后 `2d50403` 把运行时钉到 **dsh 0.2.1-rc.3**：npm `latest` 是 rc.2、`next` 是 rc.4，
但 rc.4 的 5 个包与 rc.3 除版本号外内容完全一致（无 GitHub release），判定为无变更重发；
GitHub 最新 release 与官方桌面版都是 rc.3。

## 阶段 6：0.5.0——点图标即进（19:51–19:53）

0.4.0 仍需「首次粘一次令牌」。用户要求去掉这一步，于是跳转器**自己读本次启动的令牌**：

- `cmd/main` 启动 dsh 后从**本次新增日志**抓 `token=`（F2 的教训），写 `launcher.json`（600）；
- 跳转器每次请求现读，`302` 到 `http://<绑定IP>:3081/?token=…`；
- 只有内网来源（含 Tailscale `100.64/10`）自动放行，**公网来源仍走配对**；
- 设置里新增「入口方式」，可切回 `pair`。

同一批还改了流程：`build.sh` 内置自测（失败即中止）、打完自动复制 fpk 到共享目录，
安装/卸载全部收敛到界面（`53af194` 修正了顺序：**先下载 fpk 再卸载**，否则共享目录被
`chmod 000` 就打不开了）。

## 阶段 7：两次打包失败，两次修复（20:01 / 20:07）

两次 `build.sh full` 都卡在同一条断言上：`auto：上游接受这条令牌（303）（期望 303，实际 000）`。
看起来像产品缺陷，实际两次都是**测试自身的问题**：

| 提交 | 根因 | 修法 |
|---|---|---|
| `9adb7be` | 假上游还没 `listen()`，第一发 curl 被拒 | `wait_up()` 轮询就绪 + 重试 + 现场诊断 |
| `cfd363c` | `Location` 残留 `\r`：fnOS 的 sed 不认 `\r` 转义 | `tr -d '\r'` + bash 裁尾随空白（三处） |

第二次的判断依据值得记住：在同一段里 `pair：正确令牌 → 302` 是**通过**的，而那条要求跳转器
主动去请求同一个上游——所以上游是好的，问题在别处。

复现实验（开发机上）：

```console
$ curl -s -o /dev/null -w '%{http_code}' "http://…/?token=A"$'\r'
000                    # exit 3；加 -s 时连报错都看不到
```

`e5a148e` 把这个坑写进了 [PLAN §5.1.1](../PLAN.md)。

## 阶段 8：0.5.0 安全承诺与健壮性（20:38–20:46）

起因是对照社区方案做审查（dshbase / `techysy/deepseek-harness-fnos`、
`10000ge10000/deepseek-harness-fpk`、论坛帖 70194），发现我们 README 里
「公网来源不会被自动放行，这条写在代码里」**在有反向代理时不成立**：

- `launcher` 只看 `socket.remoteAddress`，本机反代会让它变成 `127.0.0.1`，
  于是公网访客被当成内网直连、自动拿到带令牌的跳转；
- 上游文档明确 web profile 是 loopback 服务，跨机访问应由反代 + `--public-url` /
  `--trusted-host` 负责，我们的 `--host <LAN IP>` 是权宜（换来 T6 双网卡问题）。

同一轮把几处确定性的坑一起修了：

| 编号 | 改动 | 验证 |
|---|---|---|
| F9 | `viaProxy()`：出现任何代理头就不自动放行，落配对页 | 本地起假上游：直连 302、带 `X-Forwarded-For`/`X-Real-IP` 均 200 |
| F10 | token 抓取不再写死字符集（`.`/`+`/`%`/`=` 都保留） | token `abc.def-ghi_jkl` → Location 完整、上游 303 |
| F11 | `force_rm()`：先恢复权限再删，删不掉明确告知 | 语法检查；真机待验 |
| F12 | 同版本打包默认 `die`，`DSH_ALLOW_SAME_VERSION=1` 放行 | 语法检查 |
| F13 | selftest 用 `cygpath -u` 去掉盘符冒号、自动取 PATH 的 node | 直接跑：**29 通过 / 22 跳过 / 0 失败**（原 22/22/7） |

`selftest.sh` 同步加了「带 X-Forwarded-For 不自动跳转」的回归项。本轮没有动
`cmd/main` 的进程编排，也没有实现「先换 cookie 再转发」——后者取决于 T2 的真机结论。

## 阶段 9：第三次打包，暴露「残留运行时」（20:55）

推上 Gitea 后在 NAS 上重跑，自测第一次跑满 Linux 全量断言：

```console
== HTTP 探测
  FAIL  GET / 返回 200（期望 200，实际 302）
通过 54 / 跳过 0 / 失败 1
```

**不是入口坏了，是这一段跑成了 dsh 模式。** `detect_mode()` 只看
`runtime/app/node_modules/@deepseek-ai/dsh/package.json` 在不在；而源码树里残留着
上一次 `build.sh full` 装出来的 `app/runtime/app`、`app/runtime/node`——这两个目录
在 `.gitignore` 里，`git pull` 不会清。于是沙箱带着 dsh 包起步：跳转器占 13080、
dsh 退到 13081，`GET 13080/` 返回 302，而该段断言写的是骨架模式的 200。

铁证在日志里：dsh 模式段打印 `node=…/target/runtime/node/bin/node`。没有残留时
`find_node()` 只会找到系统的 `/var/apps/nodejs_v24/...`。

| 编号 | 改动 | 验证 |
|---|---|---|
| F14 | 沙箱复制后 `rm -rf target/runtime/app`（只删副本）+ 新增断言「本段跑的是骨架模式」 | 人为放置残留后自测：打印「已移除残留」、`GET /` 200，**30 通过 / 22 跳过 / 0 失败** |

这个坑的教训比修法重要：**`.gitignore` 的构建产物不会随 `git pull` 消失**，
而自测的假设建立在「源码树是干净的」之上。凡是「按目录存在性判断分支」的地方，
都要先问一句「这个目录会不会是残留」。

## 阶段 10：0.5.0 装上真机，T1 / T2 关闭（21:09–21:14）

F14 修复后重新打包，自测通过，随后界面卸载（保留）→ 手动安装。**第一次把 0.5.0 装到真机上。**

```console
probe/05   PASS 33 / WARN 1 / FAIL 0
probe/07   PASS 10 / FAIL 0（auto-ok）
healthz    {"ok":true,"ready":true,"auto":true,"mode":"auto"}
```

关键事实：

| 项 | 实测 |
|---|---|
| 版本 | `0.5.0`；`target → /vol1/@appcenter/dsh`；bundled dsh `0.2.1-rc.3`、node `v24.22.1` |
| 权限 | 9 个 `cmd/*` 全 755；应用用户 `dsh` uid=971；`dsh-home` 700、`settings.conf` 600 |
| 端口 | 三处一致 3080；launcher 绑 `192.168.0.114:3080`、dsh 绑 `:3081`；3081 裸访问仍 401 |
| 安装耗时 | `install_init` 21:09:29 → `ok` 21:09:51，**解包完成后约 22 秒**可用 |
| F9 | 外部实测：直连 302；`X-Forwarded-For` / `X-Real-IP` / `Forwarded` 均 200 配对页 |

**T2 顺手关掉**（这条悬了整轮）：`probe/07` 的「第二次点击」用的是不带 cookie 的独立
curl，仍然 303 —— 说明**令牌可复用，不是一次性的**；重启前的 dsh cookie 也能继续用（200）。
所以「302 把令牌写进 `Location`」的设计成立，不用改成「先换 cookie 再转发」。
脚本注释里那句「带 jar 测就是假阳性」这次起了作用。

本轮顺带修的小问题与新发现的测量坑：

| 编号 | 内容 |
|---|---|
| F15 | 配对密钥 700 不自愈：`loadSecret()` 读到旧文件直接返回，早期版本留下的宽权限永远不改。改为读到即 `chmod 600` |
| — | `du -sh /var/apps/dsh` 只有 132K/17 文件——`target`、`var`、`etc` 都是软链，`du` 不跟随。真实体积要 `du /vol1/@appcenter/dsh` |
| — | `curl 127.0.0.1:3080/healthz` 返回空：launcher 绑的是局域网 IP。README 与 RUNBOOK 的排错命令已改成先解析 `DSH_BIND` |

## 阶段 11：体积补测 + 一个我自己造成的坑（21:21）

**T5 数据补齐**：`du -sh /vol1/@appcenter/dsh` = **957M**，`find … -type f | wc -l` = **63056**。
包 990MB、装完略小，与预估一致；`install_init` 卡「≥1.5GB 可用」在 957M 面前余量够，
但**解包瞬间的峰值仍未测**（要下次装包时用 `df` 轮询才有数据）。

**用户反馈「应用中心 dsh 只有打开和卸载」**，这直接否掉了我上一轮让他「在应用中心停一下再启动」
的验证方案——没有停止按钮就没有这条路径。三个候选原因写进 T10（manifest 丢了 `ctl_stop`、
平台把运行中判成已停止、或停止入口在详情页的「⋯」里），并加了定性命令。
`probe/05` 从此断言 `ctl_stop=true`，下次验收会直接暴露是哪种。

**同时发现两件比按钮更严重的事**：

1. 上一轮 `probe/07` 是我让用户在 **root** 下跑的。它会 `stop` + `start` 一次，
   于是 dsh 以 root 启动、把 `dsh-home` 里的 `-wal` 与会话库写成了 root 所有。
   应用中心下次以 `dsh`(971) 启动时对这些文件没有写权限——症状是「会话凭空少了」，
   而且不报错。改为 `probe/07` 在 root 下用 `su` 降权执行，并在重启后
   `find "$HOMEDIR" -user root` 自检（F16）。
2. 「安装时启动」用 `/vol1/@appshare/dsh/workspace`，「手工启动」走回退路径
   `/var/apps/dsh/cmd/../shares/workspace`。两者必须指向同一目录，否则就是两套 dsh-home、
   两套会话库，其中一套还会随卸载消失。`probe/05` 新增断言：比对 `readlink -f` 后的结果。

这三条的共同点是：**验收脚本自己会改变被测系统**。以后凡是让用户跑会 `start` 的探针，
都得先问一句「它是以谁的身份启动的、start 之后路径还是原来那个吗」。

## 阶段 12：按钮消失的真因在「回环没有监听」（21:26）

用户在应用中心只看到「打开 / 卸载」，没有停止。按 T10 的三个候选逐条排除：

```console
ctl_stop = true        ← 不是 manifest 丢键
status   rc=0          ← 不是我们的 status 报错
两套 workspace         ← readlink -f 后同一条路径，只有一个 dsh-home
dsh-home root 文件     ← 1 个（probe/07 以 root 重启造成，F16 的现场）
```

于是剩最后一条自洽解释：**launcher 只绑局域网地址**，平台对 `service_port` 的本地探测
（回环）拿不到响应，于是按「未运行」渲染，启停入口跟着消失。这个坑其实早就露过头——
我之前让用户 `curl 127.0.0.1:3080/healthz` 得到空，当时只改了文档，没动根因。

**F17 修法**：`--host` 不是回环时，额外在 `127.0.0.1` 上再起一个监听，共用同一个 handler；
回环监听失败只记日志，不影响局域网入口。同时把 handler 从 `http.createServer(async …)`
里提出来，两个 server 共用。

**验证**：自测新增两条（用 `127.0.0.2` 冒充非回环）——「给 LAN 地址时回环也监听」与
「原地址仍可访问」，Windows 上 **32 通过 / 22 跳过 / 0 失败**；NAS 上预期 **58**。
真机上按钮是否出现，得等下次装包才知道，所以 T10 仍标未关闭。

顺带确认 `appcenter-cli` 1.0.2 有 `start` / `stop` / `status`，
「没有停止按钮时怎么重启」终于有确定答案，不用再靠 `su` 兜底。

## 阶段 13：10330 不是谜，是 stop 撒了谎（21:31）

按 F16 的清理步骤执行时，`appcenter-cli stop dsh` 回 `stop success`，
紧接着 `appcenter-cli start dsh` 回 `something wrong with appcenter: code 10330`，
而且 `var/dsh.pid` 已经不存在了。

链条很清楚：那个 dsh 是**我在 root 下用 probe/07 起的**；应用用户 `dsh` 的 `kill`
对它是 EPERM，静默失败；`do_stopf()` 不看结果，照样删 pidfile、记 done、`return 0`。
于是「pidfile 没了 + status 报未运行 + 端口还被占着」同时成立，`start` 必然 EADDRINUSE，
平台把它折叠成 10330，对话框里一个字的原因都没有。

**F18 修法**（都在 `cmd/main`）：

- 新增 `is_alive()`（排除 `Z` 僵尸态），stop 收尾据此复核；
- 仍活着 → 记 FAILED、写清「谁占着、当前身份没权限」到 `TRIM_TEMP_LOGFILE`、保留 pidfile、`return 1`；
- `do_stop()` 汇总结果，失败时不再删 `launcher.json`（留着比清空更有助排查）；
- `stop` 子命令 `exit $?`；start 的 EADDRINUSE 文案补上「别人留下的进程」这一句。

自测 `32 通过 / 22 跳过 / 0 失败`（stop 相关 6 项全绿）。

教训：**「停止」这种破坏性操作必须验证结果**。原代码只保证「发了信号」，
不保证「进程没了」——而平台只会给一个错误码，用户和我都会先怀疑平台。

## 阶段 14：确认实例归属，版本提到 0.6.0（23:37–23:40）

**先解决「现在跑的是谁」**。外部探测没有信息量——`3080/healthz` 返 200、`3081` 返 401，
root 残留与平台拉起的实例给出完全一样的响应。判据只能是端口属主：

```console
LISTEN 192.168.0.114:3081  pid=3359059
LISTEN 192.168.0.114:3080  pid=3359039
dsh  …/dsh/lib/bin.js --profile web --host 192.168.0.114 --port 3081
```

pidfile 在、属主 `dsh`、命令行与 `--port 3081` 对得上，PID 是新一轮（`3359xxx`，
root 那批是 `3280xxx`）——**平台拉起、应用用户运行**，P0 关闭。

**唯一残留**：`dsh-home` 里 1 个 root 所有的旧会话文件（F16 现场）。23:41 用
`find … -user root -exec chown dsh:AppUsers {} +` 改归属，复查 `find … -user root | wc -l` 得 **0**。

**版本提到 0.6.0**：`manifest` 的 `version` 与 `changelog` 一起改，把 F15 / F17 / F18
三项写进面向用户的话（停止按钮回来、stop 失败会说原因、密钥权限自动收敛）。
`build.sh` 的同版本守卫（F12）要求必须先提版本，否则直接 `die`——这一步是装包的前置条件。

**RUNBOOK 同步**：第 0 步按「已装 0.5.0 → 直接打 0.6.0」改写；第 4 步新增 4.0 磁盘采样
（`df` 每 2 秒一行，装完取最小可用，补 T5 唯一的缺口）；第 5 步把
`curl 127.0.0.1:3080/healthz` 从「会得到空响应，别用」改成**验收项**（期望 200）——
F17 之后这条才算有意义。


## 下一步

1. **打 0.6.0 并验收 P1/P2**：`bash build.sh full` → 下载 → 界面卸载（保留）→ 手动安装 →
   `probe/05`（看 `FAIL 0`、`ctl_stop=true`、workspace 同一目录、`loop=200`）→ 看卡片是否有「停止」（T10）；
2. **瘦身**（一次性收益）：改用 `install_dep_apps: nodejs_v24` + 只打包 `node_modules`，
   目标把 990MB 压到 ~120MB；同时补插件能力（`bin/dsh` 包装 + 官方 plugin market bundle）与 ARM 包；
3. **接飞牛统一网关**（T7）：launcher 只监听 `127.0.0.1`，走 `app.sock`；同时解决双网卡、
   DDNS、FN Connect，并把 F9 的「一律配对」升级成「只信任网关身份头」。
   **先定这个要不要做**——它决定 F17 的双绑是过渡还是终局，也决定 T6 该不该单独做；
4. **进程看护**（T8）：launcher 兼看护，或由 `status` 探测触发拉起；与统一网关同轮设计，
   避免两套重启逻辑打架；
5. **端口可配**（T3）：`manifest` / 桌面入口 / 向导 / 跳转器四处一起改。

未完成项见 [ISSUES.md](ISSUES.md) 的「当前剩余问题」一节。
