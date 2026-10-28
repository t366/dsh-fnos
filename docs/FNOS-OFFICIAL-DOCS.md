# 飞牛 fnOS 官方开发文档 —— 索引、核实与引用

> 核实时间：2026-10-27　方法：逐页抓取官方站正文，不依赖第三方转述。
> 用途：这是本项目的**规范底本**。写 `cmd/`、`config/`、`wizard/` 前先查这里，不要凭记忆。

---

## 0. 入口

| 用途 | 地址 |
|---|---|
| 站点首页 | https://developer.fnnas.com |
| 文档首页（导航从这里进） | https://developer.fnnas.com/docs/guide |
| **AI 索引（官方提供，机器可读）** | https://developer.fnnas.com/llms.txt |
| **AI 全文（官方提供）** | https://developer.fnnas.com/llms-full.txt |
| 文档与开放 API 更新日志 | https://developer.fnnas.com/docs/update-log |

两个要点：

1. **`llms.txt` 是这个站最重要的入口**——它把全部页面按分组列成一份带一句话说明的清单。查文档先拉它，比猜路径可靠。
2. **`sitemap.xml` 不存在（404）**。任何"从 sitemap 发现页面"的做法在这个站上都会失败。

---

## 1. 页面清单（全部实测可访问）

### 快速开始

| 页面 | 路径 | 回答什么 |
|---|---|---|
| 准备工作 | `/docs/quick-started/prerequisites` | 开发机、测试设备、工具前置 |
| 创建应用 | `/docs/quick-started/create-application` | `fnpack create` 生成最小包 |
| 测试应用 | `/docs/quick-started/test-application` | 安装与验证流程 |
| 上架应用 | `/docs/quick-started/publish-application` | 发布到应用中心 |

### 核心概念（本项目主要依赖这一段）

| 页面 | 路径 | 回答什么 |
|---|---|---|
| 应用框架 | `/docs/core-concepts/framework` | 安装后目录布局、9 个生命周期脚本、退出码 |
| Manifest | `/docs/core-concepts/manifest` | 全部字段与取值 |
| 环境变量 | `/docs/core-concepts/environment-variables` | `TRIM_*` 全量清单 |
| 应用权限 | `/docs/core-concepts/privilege` | `run-as` / 用户名 / `join-groups` |
| 应用资源 | `/docs/core-concepts/resource` | `data-share` / `usr-local-linker` / `docker-project` |
| 应用入口 | `/docs/core-concepts/app-entry` | `app/ui/config`、`type: url\|iframe`、`{0}` 图标 |
| index.cgi | `/docs/core-concepts/index-cgi` | 轻量 CGI 入口（本项目不用） |
| 统一网关 | `/docs/core-concepts/gateway-registration` | Unix Socket 转发、用户 Header、**WebSocket** |
| 用户向导 | `/docs/core-concepts/wizard` | 四种向导、字段类型、校验规则 |
| 应用依赖 | `/docs/core-concepts/dependency` | `install_dep_apps` 语法与安装顺序 |
| 中间件服务 | `/docs/core-concepts/middleware` | 内置中间件（本项目不用） |
| **运行时环境** | `/docs/core-concepts/runtime` | **官方推荐的 Node/Python/Java 接入方式** |
| 图标 | `/docs/core-concepts/icon` | `ICON.PNG` / `ICON_256.PNG` / `icon_{0}.png` |

### 示例与工具

| 页面 | 路径 | 回答什么 |
|---|---|---|
| Native 应用案例 | `/docs/examples/native` | 完整可抄：Node 后端 + 网关 Socket + data-share + pid |
| Docker 应用案例 | `/docs/examples/docker` | compose 形态（本项目不用） |
| appcenter-cli | `/docs/cli/appcentercli` | `install-fpk` 等命令行 |
| fnpack | `/docs/cli/fnpack` | `create` / `build --directory` |

### 开放 API（暂不涉及）

`/api/overview`、`/api/calling`、`/api/platform-config`、`/api/authorization/{overview,shared-access,user-access,file-acl,path-convert}`、`/api/page/{routing,ui}`、`/api/error-codes`

---

## 2. 曾经走错的路径（避免重复踩）

| 猜的路径 | 结果 | 实际位置 |
|---|---|---|
| `/docs/core-concepts/package-structure` | 404 | `/docs/core-concepts/framework` |
| `/docs/core-concepts/desktop-entry` | 404 | `/docs/core-concepts/app-entry` |
| `/docs/core-concepts/ui` | 404 | `/docs/core-concepts/app-entry` + `/docs/core-concepts/icon` |
| `/sitemap.xml` | 404 | `/llms.txt` |

---

## 3. 对本项目有直接约束的事实

### 3.1 包结构与生命周期

安装后实际布局（`framework`）：

```text
/var/apps/{appname}
├── cmd/{install_init,install_callback,main,upgrade_init,upgrade_callback,
│        uninstall_init,uninstall_callback,config_init,config_callback}
├── config/{privilege,resource}
├── manifest  ICON.PNG  ICON_256.PNG
├── target -> /vol{n}/@appcenter/{appname}
├── etc    -> /vol{n}/@appconf/{appname}
├── var    -> /vol{n}/@appdata/{appname}
├── tmp    -> /vol{n}/@apptemp/{appname}
├── home   -> /vol{n}/@apphome/{appname}
├── meta   shares/
└── wizard/{install,upgrade,uninstall,config}
```

- `cmd/main` 收 `start` / `stop` / `status`；退出码 **0=成功或运行中、1=失败、3=未运行**。
- `ctl_stop=false` 会隐藏启停按钮（静态应用用）。**本项目必须 `true`**。
- 所有生命周期脚本都要**可重复执行**（安装/升级/配置流程都可能被重跑）。
- 失败前把用户能看懂的一句话写进 `TRIM_TEMP_LOGFILE`，应用中心会用对话框展示。

> **注意**：`/var/apps/{app}/target` 是**软链**。所以 `/var/apps/nodejs_v24/target/bin/node` 这种写法**与卷号无关**，跨机器稳定；而 `/vol1/@appcenter/...` 才是随卷号变化的。这修正了此前"复用系统 Node 必须猜卷号"的判断。

### 3.2 Manifest 字段

| 字段 | 取值 / 说明 |
|---|---|
| `appname` | 应用唯一标识 |
| `version` | `1.0.0` 或 `2.1.3-beta` |
| `display_name` / `desc` | 展示名 / 描述（`desc` 可用 HTML） |
| `source` | 第三方固定 `thirdparty` |
| `platform` | `x86` / `arm` / `all`（**含架构二进制时不能用 `all`**） |
| `maintainer` / `maintainer_url` / `distributor` / `distributor_url` | 开发者与发布者 |
| `os_min_version` / `os_max_version` | 兼容范围，按实测填写 |
| `ctl_stop` | `true` 显示启停与运行状态 |
| `install_type` | 空=用户选存储位置；`root`=系统分区 |
| `install_dep_apps` | 依赖应用，`:` 分隔，`>` 声明最低版本 |
| `desktop_uidir` | UI 目录，默认 `ui` |
| `desktop_applaunchname` | 多入口时指定应用卡片打开的入口 ID |
| `service_port` | 服务端口 |
| `checkport` | 启动前是否检查端口，默认 `true` |
| `disable_authorization_path` | `true` 隐藏授权目录设置 |
| `changelog` | 更新说明，面向用户 |

### 3.3 运行时（`runtime` 页，官方推荐做法）

官方明确：**应用可以使用打包运行时环境**，通过 `install_dep_apps` 声明，然后在脚本里把 `bin` 加进 `PATH`：

```ini
install_dep_apps=nodejs_v22
```
```bash
export PATH=/var/apps/nodejs_v22/target/bin:$PATH
node -v && npm -v
```

官方建议里两条值得记住：

- 在生命周期脚本里调用运行时命令前，把运行时 `bin` 加入 `PATH`；
- **应用自身依赖要保存在应用目录或专用虚拟环境里**——即不要往运行时应用目录里 `npm -g`。

这解释了 `marvis-app` 那套探测+注入 PATH 的写法为什么长那样：它是官方推荐路径的手工实现，系统不会自动注入。

### 3.4 应用依赖（`dependency` 页）

- 多个依赖 `:` 分隔；**从右到左安装并启用**（右边的先就绪）。
- `>` 声明最低版本：`database>2.2.2:cache`。
- **依赖不递归**：A 需要 B 和 C，即使 B 也依赖 C，A 也要自己写上 C。

### 3.5 权限（`privilege` 页）

```json
{ "defaults": { "run-as": "package" }, "username": "myapp_user", "groupname": "myapp_group" }
```

- `run-as=package` = 专用应用用户（推荐）；`root` 仅用于确需特权的准备动作，长期服务应 `runuser -u "$TRIM_USERNAME"` 降权。
- `username`/`groupname` 省略时按 `appname` 自动生成。
- 可选 `join-groups`，用于 `video` / `render` 这类系统组。
- 应用默认**拿不到**用户文件，需要用户在设置里授权目录，或声明 `data-share`。
- **「应用设置 → 访问权限 → 允许访问以下文件夹」这一页由 `manifest.disable_authorization_path` 控制**：
  `false`（默认）= 用户可添加授权目录；`true` = **整页隐藏**，用户连入口都没有。
  官方原文只有一句「仅当应用不需要用户选择文件或目录访问权限时才使用 `true`」，
  所以**通用型应用一律不要写 `true`**（本项目踩过：ISSUES F23）。
- 用户授权的路径通过环境变量 `TRIM_DATA_ACCESSIBLE_PATHS`（`:` 分隔）传给生命周期脚本；
  平台同时把 ACL 授予应用运行用户（Windows ACL 模型）。**声明/授权都只是前提**：
  官方明确要求应用读写前仍要自己校验文件权限。
- 注意区分两条来源：`TRIM_DATA_SHARE_PATHS` = `config/resource` 里自己声明的那块目录
  （安装时自动建、自动授权）；`TRIM_DATA_ACCESSIBLE_PATHS` = **用户自己挑的**目录。
  前者只覆盖应用自己那块，后者才是「用户把任意文件夹交给你」的正规通道。

### 3.6 资源（`resource` 页）

```json
{ "data-share": { "shares": [ { "name": "myapp/documents" } ] } }
```

- `name` 用 `应用名/子目录`；系统安装时创建目录并自动授予运行用户 ACL（**Windows ACL，不是 POSIX ACL**）。
- `permission`（`rw`/`ro`）**只在需要授权别的用户或应用时**才写，大多数情况不需要。
- 脚本里用 `TRIM_DATA_SHARE_PATHS`（`:` 分隔）取路径，或走软链 `/var/apps/{app}/share/{sub}`。
- 另有 `usr-local-linker`（暴露 `bin`/`lib`/`etc` 到 `/usr/local/*`）与 `docker-project`。

### 3.7 入口（`app-entry` + `icon` 页）

```json
{
  ".url": {
    "myapp.main": {
      "title": "My App",
      "icon": "images/icon_{0}.png",
      "type": "url",
      "protocol": "http",
      "port": "8080",
      "url": "/",
      "allUsers": true
    }
  }
}
```

- `type`：`iframe`=桌面窗口内打开；`url`=浏览器标签页/外部 Web 视图。
- `icon` 用 `{0}` 占位，系统替换为所需尺寸 → 目录里必须是 **`icon_64.png` / `icon_256.png`（下划线）**。
- `port` / `url` 支持 `${wizard_port}`、`${wizard_path}` 插值。
- 其他字段：`allUsers`、`fileTypes`、`noDisplay`、`control.accessPerm`（`editable`/`readonly`/`hidden`）。
- 多入口时用 `desktop_applaunchname` 指定应用卡片打开哪个。
- 包图标：根目录 `ICON.PNG`=64×64、`ICON_256.PNG`=256×256；sRGB；≤1024KB；**主体要圆角矩形，不能直角满铺**；64px 下仍要清晰。

### 3.8 统一网关（`gateway-registration` 页）

```json
{
  ".url": {
    "myapp.main": {
      "gatewayPrefix": "/app/myapp",
      "gatewaySocket": "app.sock",
      "url": "/app/myapp",
      "type": "iframe", "protocol": "", "allUsers": true
    }
  }
}
```

- 应用必须**监听 Unix Socket**（`${TRIM_APPDEST}/app.sock`），网关校验 NAS 登录态后转发过去。
- 网关入口**忽略 `protocol` 和 `port`**。
- 转发时注入可信 Header：`X-Trim-Userid` / `X-Trim-Isadmin` / `X-Trim-Username`。
- **明确支持 WebSocket**，建议放在稳定子路径（`/app/myapp/ws`），连接建立时同样带身份 Header。
- 路由应保持在 `gatewayPrefix` 下 → **应用必须能接受带前缀的路径**。

对本项目：dsh 只会监听 TCP 的 `--host:--port`，且不支持 base path。要用网关，得加一层"Unix Socket ↔ TCP"桥（socat）并改写路径——**v1 不做**。

### 3.9 环境变量（`environment-variables` 页）

| 变量 | 含义 |
|---|---|
| `TRIM_APPNAME` / `TRIM_APPVER` / `TRIM_OLD_APPVER` | 应用名 / 当前版本 / 升级前版本 |
| `TRIM_APP_STATUS` | `INSTALL`/`START`/`UPGRADE`/`UNINSTALL`/`STOP`/`CONFIG` |
| `TRIM_APPDEST` | 已安装的 `target` 目录 |
| `TRIM_PKGETC` / `TRIM_PKGVAR` / `TRIM_PKGTMP` / `TRIM_PKGHOME` / `TRIM_PKGMETA` | 配置 / 数据 / 临时 / 用户数据 / 元数据 |
| `TRIM_APPDEST_VOL` | 安装所在存储空间路径 |
| `TRIM_USERNAME` / `TRIM_GROUPNAME` / `TRIM_UID` / `TRIM_GID` | 应用用户上下文 |
| `TRIM_RUN_USERNAME` / `TRIM_RUN_GROUPNAME` / `TRIM_RUN_UID` / `TRIM_RUN_GID` | **当前脚本执行者**（特权脚本里可能不同） |
| `TRIM_SERVICE_PORT` | `manifest.service_port` |
| `TRIM_DATA_SHARE_PATHS` | 声明的共享目录，`:` 分隔 |
| `TRIM_DATA_ACCESSIBLE_PATHS` | 用户授权的可访问路径，`:` 分隔 |
| `TRIM_TEMP_LOGFILE` | 写**用户可见错误**的临时文件 |
| `TRIM_TEMP_UPGRADE_FOLDER` / `TRIM_PKGINST_TEMP_DIR` / `TRIM_TEMP_TPKFILE` | 升级 / 安装解压临时目录 |
| `TRIM_SYS_VERSION`(`_MAJOR`/`_MINOR`/`_BUILD`) / `TRIM_SYS_ARCH` / `TRIM_KERNEL_VERSION` / `TRIM_SYS_MACHINE_ID` / `TRIM_SYS_LANGUAGE` | 系统上下文 |
| `TRIM_API_TOKEN` | 调用开放 API 的 token |

向导字段**直接变成同名环境变量**，不加 `TRIM_` 前缀（官方建议自定义字段用 `wizard_` 前缀，且**永远不要**用 `TRIM_`）。

### 3.10 向导（`wizard` 页）

- 四种：`install` / `upgrade` / `uninstall` / `config`，都是**数组**，元素是 `{ stepTitle, items[] }`。
- 字段类型：`text` / `password` / `radio` / `checkbox` / `select` / `switch` / `tips`。
- 校验走 `rules`：`required`、`min`/`max`、`len`、`pattern`，每条可带 `message`。
- 默认值字段名是 **`initValue`**（不是 `default`）；提示文本用 `helpText`。

**实测约束（文档没写，只能靠 fnpack 报错反推）**：

| 约束 | 依据 |
|---|---|
| **`initValue` 必须是字符串**，布尔/数字会直接打回 | `wizard/uninstall` 里 `"initValue": false` 导致 `fnpack build` 失败：`File "uninstall" is not valid due to JSON format or content validation failure.` 改成 `"false"` 或改用 `radio` + 字符串即通过 |
| fnpack 的校验错误**只说文件名、不说字段** | 所以 `build.sh` 内置了 `lint.js`（heredoc 内联），把已知约束提前检查到「第几步第几项」 |
| `radio` / `select` / `checkbox` 需要 `options: [{label, value}]`，且 `initValue` 要落在某个 `value` 上 | 与 `select` 示例同构 |
| `tips` 不需要 `field`，但需要 `helpText` | `install` 向导实测 |
| 空 `rules: []` 无意义，已从本项目所有向导移除 | 降低被校验器挑剔的面 |

> ⚠️ 全量校验用 `bash build.sh` 前先跑一遍它会自带的 linter；`node -e 'JSON.parse'` 只能证明语法合法，**证明不了内容合法**。

### 3.11 CLI

- `fnpack create <name>` 生成骨架。
- **`fnpack build --directory <包目录>`** 打包（官方示例写法；不带参数是否等价未文档化）。
- `appcenter-cli install-fpk <file.fpk>` 安装测试。

---

## 4. 官方 Native 示例值得直接抄的部分

`/docs/examples/native` 是一个 Notepad：Node 后端 + React 前端 + 统一网关 + `data-share`。它验证了我们这套做法，也给了几个现成写法：

| 示例做法 | 我们的对应 |
|---|---|
| `install_dep_apps=nodejs_v22` + `export PATH=/var/apps/nodejs_v22/target/bin:$PATH` | 自带 runtime 时改为解析 bundled 路径（顺序 bundled → system） |
| `PID_FILE="${TRIM_PKGVAR}/app.pid"`，`status` 用 `kill -0` | 一致；我们额外存 PGID 以便整组回收 |
| `stop` 先 `TERM`，轮询 10s 后 `KILL` | 一致（我们 15s） |
| `DATA_DIR="${TRIM_DATA_SHARE_PATHS%%:*}"` | 一致 |
| 网关 Socket 放 `${TRIM_APPDEST}/app.sock` | 不采用（dsh 不支持 unix socket） |
| `echo "Unknown command: $1" > "$TRIM_TEMP_LOGFILE"` | 一致 |

差异是刻意的：示例用 `app.listen(SOCKET_PATH)` 直接监听 socket，dsh 做不到；示例也不管进程组，dsh 的 pty 子进程必须按组回收。

---

## 5. 与本项目实现的比对

| 项 | 官方规范 | 本项目现状 | 结论 |
|---|---|---|---|
| 包图标 | `ICON.PNG` 64、`ICON_256.PNG` 256、圆角 | 已按此生成 | ✅ |
| 入口图标 | `images/icon_{0}.png` → `icon_64.png`/`icon_256.png` | **已改**（原为 `icon-{0}.png` + `icon-64.png`） | ✅ 已对齐 |
| 入口 `type` | `iframe`（桌面内）/ `url`（新标签） | `url` | ✅ 有意为之（dsh 需要完整浏览器能力） |
| `desktop_applaunchname` | 与入口 ID 一致 | `dsh.main` | ✅ |
| privilege | `run-as=package` | `package`，`dsh`/`dsh` | ✅ |
| resource | `data-share.shares[].name = 应用名/子目录`，`permission` 可选 | `dsh/workspace`，无 `permission` | ✅ |
| 生命周期 | 9 个脚本、退出码 0/1/3、可重入 | 9 个齐全 | ✅ |
| 用户可见错误 | 写 `TRIM_TEMP_LOGFILE` | `say()`/`fail()` 已写 | ✅ |
| manifest | 见 §3.2 | `platform=x86`（含 node 二进制）、`ctl_stop=true`、`service_port=3080` | ✅ |
| 打包命令 | `fnpack build --directory <dir>` | **已改为 `--directory .`** | ✅ 已对齐 |
| 向导字段命名 | 建议自定义字段用 `wizard_` 前缀、禁用 `TRIM_` | `dsh_apikey` / `dsh_bind` | ⚠️ 有意偏离（`dsh_` 同样不与系统变量冲突；字段名一旦发布就要保持稳定，等确定要改就一起改） |
| 运行时 | 官方推荐 `install_dep_apps` + PATH | 自带 node（R1），slim 变体可声明依赖 | ⚠️ 有意偏离，理由见 PLAN §3.1 |
| 入口模型 | 端口 / CGI / 网关 | 端口 | ⚠️ 网关需 unix socket，v1 不用 |

---

## 6. 下次该读的页面

- 要正式上架：`/docs/quick-started/publish-application`、`/docs/cli/fnpack`（签名相关）
- 要把 dsh 接进飞牛桌面登录态：`/docs/core-concepts/gateway-registration`（配合 socat 桥）
- 要读文件/调开放能力：`/api/authorization/overview`、`/api/calling`
- 想知道文档最近改了什么：`/docs/update-log`
