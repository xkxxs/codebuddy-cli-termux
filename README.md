# codebuddy-cli-termux

在 Termux (Android ARM64) 上一键安装**官方** CodeBuddy CLI(`@tencent-ai/codebuddy-code`),纯 npm 直装 + 三项 Termux 修复,**无需 proot、无需 root、无需 Ubuntu**。

> 与 [codex-termux](https://github.com/xkxxs/codex-termux) 同思路,但 CodeBuddy 是纯 Node.js 包(无 `os` 限制),比 Codex 的 musl 二进制方案更简单:
> 不需要绕过 npm 平台检查,也不需要 dns53/证书修复 — 只需修 shebang、编译 node-pty、接管启动更新。

## 前置要求

- Termux + aarch64 (ARM64)
- Node.js 18.20.8+(脚本自动安装 `nodejs-lts`)
- 编译 node-pty 需要:`clang`、`make`、`python`(脚本自动安装)

**不需要 root。**(有 root 时脚本会额外做 SELinux context 自愈,避免 npm EACCES。)

## 一行命令安装

优先用 gh-proxy（缓存约几分钟）；拉不动时依次换 jsDelivr（约 12 小时缓存）或 GitHub 直连（实时，但国内网络不稳定）：

```bash
# 推荐: gh-proxy
bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/xkxxs/codebuddy-cli-termux/main/install.sh)

# 备选 1: jsDelivr CDN (约 12 小时缓存, 新提交可能延迟)
bash <(curl -fsSL https://cdn.jsdelivr.net/gh/xkxxs/codebuddy-cli-termux@main/install.sh)

# 备选 2: GitHub 直连 (国内可能超时)
bash <(curl -fsSL https://raw.githubusercontent.com/xkxxs/codebuddy-cli-termux/main/install.sh)
```

## 脚本做了什么

| 步骤 | 说明 |
|---|---|
| 环境检查 | 仅支持 Termux + aarch64 |
| 镜像源适配 | 对 官方/清华/中科大/阿里云/北大/南科大 逐个探测 + 测速,按**新鲜度优先、速度兜底**选源(幂等)。Release 落后最新超过 12 小时的源会被跳过 —— 快的源不一定同步得勤(实测腾讯云曾落后 4 个月、包数差 178 个)。切换前自动备份,切换后 `apt update` 失败会回滚 |
| 软件包升级 | `pkg upgrade -y`(全新 Termux 首次可能数分钟) |
| 依赖安装 | `nodejs-lts`、`python`、`make`、`clang`(按需) |
| 安装 CodeBuddy | `npm install -g @tencent-ai/codebuddy-code`(官方包,无平台限制)。这一步要下载 + 编译 node-pty,耗时数十秒且原本**全程无输出**,现在会显示转圈与已耗时 |
| **修复 1: shebang** | bin 脚本 `#!/usr/bin/env …` → Termux 绝对路径(否则 `bad interpreter` 无法启动) |
| **修复 2: node-pty** | 从 `microsoft/node-pty` 源码 `node-gyp` 编译 bionic 版,组装成 `@lydell/node-pty-android-arm64` 放入包内(官方只有 glibc 预编译,`dlopen` 必挂)。**只在必要时才真编译**,见下节 |
| **修复 3: 关闭内置更新器** | `DISABLE_AUTOUPDATER=1`(内置 updater 会尝试 native install,Termux 不可用) |
| 生成 wrapper | `~/.local/bin/codebuddy`(优先于 npm 原始 bin):启动前检查更新,更新后自动重跑 shebang + node-pty 修复再启动 |
| 验证 | 版本 / shebang / node-pty 三项检查 |

## 启动更新流程(wrapper)

```
codebuddy
   │
   ├─ CODEBUDDY_NO_AUTO_UPDATE=1 ? ──→ 跳过检查,直接启动
   │
   ├─ npm view 最新版 (10s 快速失败,失败静默跳过)
   │     │
   │     ├─ 已是最新 ──→ 直接启动
   │     │
   │     └─ 有新版 ──→ npm 更新
   │                     → 修 shebang      ← npm 会重写 bin,必须重修
   │                     → 重建 node-pty   ← npm 会清掉手工包,必须重建
   │                     → 启动
   │                     (更新失败不阻塞,用现有版本启动)
   │
   └─ pty 缺失时按需补建 → 启动
```

- `codebuddy --version` **不**触发更新检查(保持快速、可脚本化)
- `codebuddy update` 手动强制走上述完整更新+修复流程

## 使用

```bash
codebuddy                     # 启动(自动检查更新);TUI 内 /login 登录
codebuddy update              # 手动更新 + 修复
codebuddy-pty-rebuild         # 手动重建 node-pty(--force 强制)
cbc                           # 等价于 codebuddy
CODEBUDDY_NO_AUTO_UPDATE=1 codebuddy   # 跳过启动更新检查
bash <(curl -fsSL …/install.sh) --update      # 重跑安装脚本强制更新
bash <(curl -fsSL …/install.sh) --uninstall   # 卸载
```

## 为什么需要这三项修复

### 1. shebang

包内 `bin/codebuddy` 等以 `#!/usr/bin/env node` 开头,但 Android 根目录没有 `/usr/bin/env`,直接执行报:

```
/usr/bin/env: bad interpreter: No such file or directory
```

wrapper 用 `node /path/to/bin/codebuddy` 启动可绕过;但用户直接调 `$PREFIX/bin/codebuddy`(npm 链接)时仍需 shebang 正确,且 `npm update` 每次都会重写这些文件 → 更新后必须重修。

### 2. node-pty

CodeBuddy 依赖 `@lydell/node-pty` 获得终端/shell 工具能力。两层问题:

| 层 | 问题 |
|---|---|
| npm 安装 | `@lydell/node-pty-linux-arm64` 声明 `os: linux`,在 `android` 上被拒;且 loader 按 `process.platform` 找的是 **`@lydell/node-pty-android-arm64`**(官方不存在) |
| 动态链接 | 预编译 `pty.node` 依赖 glibc(`ld-linux-aarch64.so.1` 等),bionic `dlopen` 报 `libutil.so.1 not found` |

解决:下载 `microsoft/node-pty` 源码,用 Termux 自带 `node-gyp`/`clang` 编译出 bionic 版,配上 lydell 的 JS 层,组装成 `@lydell/node-pty-android-arm64`。

#### 什么时候会真的编译

`npm install -g` 会清掉手工放入的 `@lydell/node-pty-android-arm64`,所以每次装/更新后都得"补回"。但**补回不等于重编译**,按代价从低到高:

| 情况 | 行为 | 实测耗时 |
|---|---|---|
| 版本号一致且产物完好 | 直接跳过 | **0.8 秒** |
| 产物被清掉 / lydell 版本变了,缓存里有对应版本 | 解压 `~/.cache/codebuddy-pty-rebuild/` | **0.8 秒** |
| 缓存里没有该版本 | 才真正 `npm pack` 源码 + `node-gyp` 编译 | **40 秒** |

缓存文件名带两个版本:`android-arm64-<lydell 版本>-src<node-pty 源码版本>.tar.gz`。
真正的编译只在首次安装、或 codebuddy 升级换了 lydell 版本时发生。

> 历史坑: wrapper 更新后原本调用 `codebuddy-pty-rebuild --force`,而 `--force`
> 会同时跳过"就绪检查"和"缓存命中"两个分支,导致**每次更新都白等 40 秒重编译**。
> 现在更新走不带 `--force` 的路径;`--force` 只在显式 `install.sh --update` 时使用。

#### 版本号从哪来

| 部件 | 版本 | 来源 |
|---|---|---|
| `pty.node`(C++ 编译产物) | `node-pty` **1.1.0** | 脚本里钉死 (`NODE_PTY_SRC_VER`),不自动跟最新 |
| `lib/*.js`(JS 层) | `@lydell/node-pty` 当前版本 | 从 codebuddy 已装的包读出,会随其升级变化 |

两条线目前兼容 —— lydell 的 JS 层只用到 `fork` / `open` / `process` / `resize`
四个原生方法,1.1.0 都有。就绪检查会比对组装时写入 `package.json` 的版本号与
当前 lydell 版本,不一致就重建,避免"新版 JS 层配旧原生模块"。

无 node-pty 时 CodeBuddy 会降级到 `child_process` 跑 shell(功能可用但体验差),所以重建失败只警告不阻塞启动。

### 3. 内置更新器

`codebuddy` 自带 auto-updater / `codebuddy install` 会下载 **native 二进制**(glibc/musl 动态链接),在 Termux 上不可用。wrapper 固定 `DISABLE_AUTOUPDATER=1` 关闭,更新职责全部交给本项目 wrapper(走 npm)。

> ⚠️ 请勿在 Termux 里运行 `codebuddy install`。

## 与 codex-termux 对比

| | codex-termux | codebuddy-cli-termux |
|---|---|---|
| 包形态 | musl 静态二进制 | 纯 Node.js |
| npm `os` 限制 | 有,需 `npm pack` 绕过 | **无,直接装** |
| DNS/证书 | 需 dns53/proot/SSL_CERT_FILE | **不需要**(bionic Node 原生解析) |
| 修复项 | DNS + 证书 + shebang wrapper | shebang + node-pty + 关内置更新器 |
| 启动更新 | ✓ | ✓(更新后自动重跑修复) |

## 常见问题

| 症状 | 原因 | 解决 |
|---|---|---|
| `bad interpreter: /usr/bin/env` | npm 重装后 shebang 未修 | `codebuddy update` 或重跑安装脚本 |
| shell 工具报 node-pty 错误 | npm 更新清掉了 android-arm64 包 | `codebuddy-pty-rebuild` |
| node-gyp 编译失败 | 缺 clang/make/python | `pkg install clang make python` 后 `codebuddy-pty-rebuild --force` |
| 启动变慢(每次查 npm) | 自动更新检查 | `CODEBUDDY_NO_AUTO_UPDATE=1 codebuddy` |
| 想更新但没新版提示 | wrapper 查的是 npm 最新版 | `npm view @tencent-ai/codebuddy-code version` 确认 |
| `codebuddy install` 后起不来 | native 二进制不兼容 Termux | `npm install -g @tencent-ai/codebuddy-code@latest` 后重跑安装脚本 |

## 卸载

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xkxxs/codebuddy-cli-termux/main/install.sh) --uninstall
# 如需删除配置与缓存:
rm -rf ~/.codebuddy ~/.cache/codebuddy-pty-rebuild
```

## 项目结构

```
codebuddy-cli-termux/
├── install.sh      # 一键安装(含 wrapper / pty-rebuild 生成)
├── README.md
└── LICENSE
```

## 许可证

MIT
