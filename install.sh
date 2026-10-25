#!/data/data/com.termux/files/usr/bin/bash
# ============================================================
# codebuddy-cli-termux — 在 Termux (Android aarch64) 一键安装 CodeBuddy CLI
#
# 用法:
#   bash <(curl -fsSL https://raw.githubusercontent.com/xkxxs/codebuddy-cli-termux/main/install.sh)
#   bash <(curl -fsSL …/install.sh) --update      # 强制更新 npm 包并重建修复
#   bash <(curl -fsSL …/install.sh) --uninstall
#
# 原理:
#   @tencent-ai/codebuddy-code 是纯 Node.js 包, 无 os/cpu 限制, 可直接
#   npm install -g。Termux 上需三处修复:
#     1. shebang  — bin 脚本写死 /usr/bin/env, Android 不存在
#     2. node-pty — 可选依赖 os:linux 被拒 + 预编译是 glibc 无法 dlopen,
#                   需从源码编译 bionic 版并伪装成 android-arm64 平台包
#     3. 内置更新器 — codebuddy 自带 updater 会尝试 native install
#                   (Termux 不可用), 用 DISABLE_AUTOUPDATER=1 关闭,
#                   改由本项目 wrapper 在启动前做 npm 更新 + 自动修复
# ============================================================
set -euo pipefail

# ---------- 常量 ----------
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
HOME_DIR="${HOME:-/data/data/com.termux/files/home}"
NPM_PKG="@tencent-ai/codebuddy-code"
PKG_DIR="$PREFIX/lib/node_modules/@tencent-ai/codebuddy-code"
PKG_BIN="$PKG_DIR/bin"
LOCAL_BIN="$HOME_DIR/.local/bin"
WRAPPER="$LOCAL_BIN/codebuddy"
PTY_REBUILD="$LOCAL_BIN/codebuddy-pty-rebuild"
PTY_PKG_NAME="@lydell/node-pty-android-arm64"
PTY_LOADER="$PKG_DIR/node_modules/@lydell/node-pty"
PTY_DEST="$PKG_DIR/node_modules/@lydell/node-pty-android-arm64"
# 已验证可在 Termux/bionic 编译通过的 node-pty 源码版本
NODE_PTY_SRC_VER="1.1.0"
FORCE_UPDATE=0

# ---------- 颜色 ----------
RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[1;33m'; BLU='\033[1;36m'; NC='\033[0m'
ok()   { echo -e "${GRN}✓${NC} $*"; }
info() { echo -e "${BLU}▸${NC} $*"; }
warn() { echo -e "${YEL}⚠${NC} $*"; }
fail() { echo -e "${RED}✗${NC} $*"; exit 1; }

# 长时间无输出的操作 (npm install -g、node-pty 编译) 会让人以为卡死。
# 后台跑命令 + 前台转圈显示已耗时; 输出存到 $SPIN_OUT 供调用方判断
# (codebuddy 需要 grep npm 输出里的 EACCES / ENOTEMPTY, 所以不能丢给 /dev/null)。
SPIN_OUT=""
run_with_spinner() {
    local msg="$1"; shift
    local log i=0 rc=0
    local -a chars=('|' '/' '-' '\\')
    log=$(mktemp "${TMPDIR:-$PREFIX/tmp}/spin.XXXXXX")
    "$@" >"$log" 2>&1 &
    local pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        printf '\r\033[K  %s %s (%ds)' "$msg" "${chars[$(( i % 4 ))]}" "$(( i / 2 ))"
        i=$(( i + 1 ))
        sleep 0.5
    done
    wait "$pid" || rc=$?
    printf '\r\033[K'
    SPIN_OUT=$(cat "$log" 2>/dev/null)
    rm -f "$log"
    return $rc
}

# ---------- 环境检查 ----------
check_environment() {
    if [ "$(uname -o 2>/dev/null || true)" != "Android" ] && [ ! -x "$PREFIX/bin/pkg" ]; then
        fail "此脚本仅支持 Termux (Android)。普通 Linux 请直接: npm install -g $NPM_PKG"
    fi
    [ "$(uname -m)" = "aarch64" ] || fail "仅支持 aarch64 (ARM64), 当前: $(uname -m)"
    command -v curl >/dev/null || { info "安装 curl…"; pkg install -y curl; }
    info "环境检查通过 (Termux aarch64)"
}

# ---------- 镜像源适配 ----------
# 刚装的 Termux 默认官方源, 国内经常慢/不可达。本函数对候选源逐个探测 + 测速,
# 再按"新鲜度优先、速度兜底"选一个自动切换 (幂等; 切换后 apt update 失败会回滚)。
#
# 排序规则 —— 每一条都是实测踩出来的:
#   1) 可用性: HTTP 200 **且 Release 里能解析出 Date: 字段**
#      华为云是反例: /termux/... 路径下 Release 与 Packages 都返回 200, 内容却是
#      一个 12KB 的 HTML 页面。只校验状态码的话它会被算进候选。
#   2) 绝对陈旧: Release 日期距今超过 MIRROR_MAX_AGE 的直接判废。
#      腾讯云实测停留在 4 个月前 (2831 包 vs 官方 3009 包, python 3.13 vs 3.14)。
#   3) 新鲜度优先: Release 日期落后"最新的那个候选"超过 MIRROR_FRESH_GRACE 就不要。
#      实测 2026-10-19 —— 快慢和新鲜度并不一致:
#        官方/清华      python 3.14.8   nodejs 26.4.0-1   patchelf 0.19.2
#        中科大/阿里云  python 3.14.6-1 (其余同上)
#        腾讯云         python 3.13.13  nodejs 26.3.1    patchelf 0.19.0
#      只看速度很容易切到一个包版本偏旧的源。
#   4) 落在宽限窗口内的多个候选 → 选最快的。
MIRROR_FRESH_GRACE="${MIRROR_FRESH_GRACE:-43200}"   # 12 小时
MIRROR_MAX_AGE="${MIRROR_MAX_AGE:-2592000}"         # 30 天

# $1=Release 文件路径 → 输出 Unix 时间戳; 解析不出返回非零
release_ts() {
    local d
    d=$(awk -F': ' '/^Date: /{print $2; exit}' "$1" 2>/dev/null) || d=""
    [ -n "$d" ] || return 1
    date -d "$d" +%s 2>/dev/null || return 1
}

fix_mirror() {
    local sources_file="$PREFIX/etc/apt/sources.list"
    [ -f "$sources_file" ] || { warn "未找到 apt 源文件, 跳过镜像适配"; return; }

    # 候选: "显示名 base URL" (路径各不相同, 已逐个实测 HTTP 200)
    local candidates=(
        "官方 https://packages.termux.dev/apt/termux-main"
        "清华 https://mirrors.tuna.tsinghua.edu.cn/termux/apt/termux-main"
        "中科大 https://mirrors.ustc.edu.cn/termux/apt/termux-main"
        "阿里云 https://mirrors.aliyun.com/termux/termux-main"
        "北大 https://mirrors.pku.edu.cn/termux/termux-main"
        "南科大 https://mirrors.sustech.edu.cn/termux/apt/termux-main"
        "南阳理工 https://mirror.nyist.edu.cn/termux/apt/termux-main"
    )

    local work entry name url code ts age t1 t2 t i cut
    work=$(mktemp -d "${TMPDIR:-$PREFIX/tmp}/mirror.XXXXXX")
    # shellcheck disable=SC2064
    trap "rm -rf '$work'" RETURN

    local now n=0 newest=0
    local -a NAMES=() URLS=() TIMES=() STAMPS=()
    now=$(date +%s)

    for entry in "${candidates[@]}"; do
        name="${entry%% *}"
        url="${entry##* }"
        code=$(curl -s -o "$work/rel" -w '%{http_code}' \
            --connect-timeout 5 --max-time 15 "$url/dists/stable/Release" 2>/dev/null) || code=000
        if [ "$code" != "200" ]; then
            info "跳过 $name (Release HTTP $code)"
            continue
        fi
        # 关键在于必须解析得出 Date —— 挡掉返回 HTML 却给 200 的假源
        ts=$(release_ts "$work/rel") || {
            info "跳过 $name (Release 里没有 Date 字段 —— 多半是个返回网页的假源)"
            continue
        }
        age=$(( now - ts ))
        if [ "$age" -gt "$MIRROR_MAX_AGE" ]; then
            info "跳过 $name (同步于 $(( age / 86400 )) 天前, 太陈旧)"
            continue
        fi
        t1=$(curl -s -o /dev/null -w '%{time_total}' \
            --connect-timeout 5 --max-time 15 "$url/dists/stable/Release" 2>/dev/null) || t1=999
        t2=$(curl -s -o /dev/null -w '%{time_total}' \
            --connect-timeout 5 --max-time 15 "$url/dists/stable/Release" 2>/dev/null) || t2=999
        t=$(printf '%s\n%s\n' "$t1" "$t2" | sort -n | head -1)
        info "候选 $name: ${t}s, 同步于 $(( age / 3600 )) 小时前"
        [ "$ts" -gt "$newest" ] && newest=$ts
        NAMES+=("$name"); URLS+=("$url"); TIMES+=("$t"); STAMPS+=("$ts")
        n=$(( n + 1 ))
    done

    if [ "$n" -eq 0 ]; then
        warn "所有候选源都不可用, 保持当前配置 (可手动: pkg change-repo)"
        return
    fi

    # 只保留"新鲜度落在宽限窗口内"的, 再从中选最快的
    local best_name="" best_url="" best_t=999999 best_ts=0
    cut=$(( newest - MIRROR_FRESH_GRACE ))
    i=0
    while [ "$i" -lt "$n" ]; do
        if [ "${STAMPS[$i]}" -ge "$cut" ]; then
            t="${TIMES[$i]}"
            if [ -z "$best_url" ] || awk "BEGIN{exit !($t < $best_t)}"; then
                best_name="${NAMES[$i]}"; best_url="${URLS[$i]}"; best_t="$t"; best_ts="${STAMPS[$i]}"
            fi
        fi
        i=$(( i + 1 ))
    done

    if [ -z "$best_url" ]; then
        warn "候选源的同步时间都超出宽限窗口, 保持当前配置"
        return
    fi
    ok "选定源: $best_name (${best_t}s, 同步于 $(( (now - best_ts) / 3600 )) 小时前)"

    # 当前已是选定源 → 不动
    if grep -qF "$best_url" "$sources_file" 2>/dev/null; then
        ok "当前源已是选定源, 无需切换"
        return
    fi

    local backup="$sources_file.bak.$(date +%s)"
    cp "$sources_file" "$backup"
    warn "切换源: $(grep -oE 'https://[^ ]+' "$sources_file" | head -1) → $best_name"
    {
        echo "# 由 install.sh 自动切换 (选定: $best_name ${best_t}s, Release $(( (now - best_ts) / 3600 )) 小时前)"
        echo "deb $best_url stable main"
    } > "$sources_file"

    if DEBIAN_FRONTEND=noninteractive apt update -y >/dev/null 2>&1; then
        ok "apt update 成功 ($best_name), 原配置备份: $(basename "$backup")"
    else
        warn "apt update 失败, 已自动回滚到原配置"
        cp "$backup" "$sources_file"
        DEBIAN_FRONTEND=noninteractive apt update -y >/dev/null 2>&1 || true
    fi
}

upgrade_packages() {
    info "更新软件包索引并升级全部软件包…"
    info "提示: 全新 Termux 首次升级可能耗时数分钟 (下载量大), 请耐心等待, 不要打断"
    if DEBIAN_FRONTEND=noninteractive pkg upgrade -y; then
        ok "软件包已是最新"
    else
        warn "pkg upgrade 未完全成功, 请稍后重试 (pkg upgrade -y)"
    fi
}
# ---------- 依赖 ----------
# nodejs-lts: node+npm; python/make/clang: node-gyp 编译 node-pty 原生模块
install_dependencies() {
    local need=()
    command -v node   >/dev/null || need+=(nodejs-lts)
    command -v npm    >/dev/null || need+=(nodejs-lts)
    command -v python >/dev/null || need+=(python)
    command -v make   >/dev/null || need+=(make)
    command -v clang  >/dev/null || need+=(clang)
    if [ ${#need[@]} -gt 0 ]; then
        need=($(printf '%s\n' "${need[@]}" | awk '!seen[$0]++'))
        info "安装依赖: ${need[*]}"
        pkg install -y "${need[@]}" || fail "依赖安装失败, 请先手动: pkg update && pkg upgrade"
    else
        ok "依赖已就绪 (node $(node --version), npm, python, make, clang)"
    fi
    [ -f "$PREFIX/lib/node_modules/npm/node_modules/node-gyp/bin/node-gyp.js" ] \
        || warn "未找到 node-gyp, node-pty 编译可能失败 (可试: npm install -g node-gyp)"
}

# ---------- SELinux context 自愈 ----------
# 有 root 时对齐文件 MLS 类别, 避免 npm install 报 EACCES (与 codex-termux 同款)
fix_selinux_context() {
    local ctx mcs
    ctx=$(tr -d '\0' < /proc/self/attr/current 2>/dev/null || true)
    [ -n "$ctx" ] || return 0
    mcs=$(printf '%s' "$ctx" | sed -n 's/.*\(:s[0-9][0-9]*.*\)$/\1/p')
    [ -n "$mcs" ] || return 0
    command -v sudo >/dev/null 2>&1 || return 0
    sudo -n true 2>/dev/null || return 0

    local fixed=0 p fctx target
    for p in "$PREFIX/bin/codebuddy" "$PREFIX/bin/cbc" "$PKG_DIR"; do
        if [ ! -L "$p" ] && [ ! -e "$p" ]; then
            sudo -n test -e "$p" 2>/dev/null || continue
        fi
        fctx=$(sudo -n stat -c '%C' "$p" 2>/dev/null || true)
        [ -n "$fctx" ] || continue
        target="${fctx%%:s*}${mcs}"
        [ "$fctx" != "$target" ] || continue
        if [ -L "$p" ]; then
            sudo -n chcon -h "$target" "$p" 2>/dev/null && fixed=1
        else
            sudo -n chcon -R "$target" "$p" 2>/dev/null && fixed=1
        fi
    done
    [ "$fixed" = 1 ] && ok "已修复 SELinux context (MCS 类别对齐)"
    return 0
}

current_version() {
    node -p "require('$PKG_DIR/package.json').version" 2>/dev/null || echo ""
}

# ---------- 安装/更新 npm 包 ----------
# npm update 时若包内有 extraneous 文件 (如我们注入的 node-pty-android-arm64),
# 会 rmdir ENOTEMPTY 导致安装中断。策略: 更新前预清理注入物, 失败则卸载强删重装。
npm_install_fresh() {
    local mode="${1:-full}" npm_out rc=0

    # 预清理: 去掉 npm 不认识的注入目录, 让替换能顺利完成
    rm -rf "${PKG_DIR}/node_modules/@lydell/node-pty-android-arm64" 2>/dev/null || true

    run_with_spinner "npm install -g ${NPM_PKG}@latest (较慢, 需下载并编译 node-pty)" \
        npm install -g "${NPM_PKG}@latest" || rc=$?
    npm_out="$SPIN_OUT"
    if [ "$rc" -ne 0 ] && printf '%s' "$npm_out" | grep -q 'EACCES'; then
        [ "$mode" = "full" ] && warn "npm 报 EACCES, 修复 SELinux context 后重试…"
        fix_selinux_context
        rc=0
        run_with_spinner "重试 npm install -g ${NPM_PKG}@latest" \
            npm install -g "${NPM_PKG}@latest" || rc=$?
        npm_out="$SPIN_OUT"
    fi
    if [ "$rc" -ne 0 ] && printf '%s' "$npm_out" | grep -qE 'ENOTEMPTY|EEXIST'; then
        [ "$mode" = "full" ] && warn "npm 目录残留 (ENOTEMPTY), 卸载后强删重装…"
        npm uninstall -g "$NPM_PKG" >/dev/null 2>&1 || true
        rm -rf "$PKG_DIR"
        rc=0
        npm_out=$(npm install -g "${NPM_PKG}@latest" 2>&1) || rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
        printf '%s\n' "$npm_out" >&2
        fail "npm 安装失败 (错误见上)"
    fi
    return 0
}

install_codebuddy() {
    local mode="${1:-full}"
    [ "$mode" = "full" ] && info "安装 $NPM_PKG (npm)…"
    fix_selinux_context
    npm_install_fresh "$mode"
    [ "$mode" = "full" ] && ok "已安装: $(current_version)"
    return 0
}

# ---------- shebang 修复 ----------
# bin 脚本 shebang 为 /usr/bin/env[ -S …], Android 无 /usr/bin/env → 改绝对路径。
# npm 每次 install/update 都会重写这些文件, 更新后必须重跑 (幂等)。
fix_shebangs() {
    [ -d "$PKG_BIN" ] || return 0
    local fixed=0 f first
    for f in "$PKG_BIN"/*; do
        [ -f "$f" ] || continue
        first=$(head -1 "$f" 2>/dev/null || true)
        case "$first" in
            '#!/usr/bin/env '*)
                # 注意: 替换串写 #!$PREFIX (PREFIX 已含开头 /), 不能写 #!/$PREFIX 否则变 #!//
                sed -i "1s|^#!/usr/bin/env |#!$PREFIX/bin/env |" "$f"
                fixed=1
                ;;
        esac
    done
    if [ "$fixed" = 1 ] && [ -n "${1:-}" ]; then
        ok "shebang 已修复 ($PKG_BIN)"
    fi
    return 0
}

# ---------- node-pty 重建脚本 ----------
# 引号 heredoc 原样写出; 版本号/包名在脚本内以字面量出现 (由下方 sed 注入)。
write_pty_rebuild_script() {
    mkdir -p "$LOCAL_BIN"
    cat > "$PTY_REBUILD" << 'PTY_REBUILD_EOF'
#!/data/data/com.termux/files/usr/bin/bash
# ============================================================
# codebuddy-pty-rebuild — 为 CodeBuddy CLI 重建 node-pty (android-arm64)
#
# 背景: @lydell/node-pty 按 process.platform 查找
#   @lydell/node-pty-android-arm64, 官方不存在该包;
#   官方 linux-arm64 预编译是 glibc, bionic 无法 dlopen。
# 方案: 从 microsoft/node-pty 源码 node-gyp 编译 (bionic),
#       配 lydell 的 JS 层, 组装成 android-arm64 平台包。
#
# npm install -g 更新 CodeBuddy 后此包会被清掉, 需重跑本脚本
# (wrapper 更新时会自动调用)。
#
# 用法: codebuddy-pty-rebuild [--force]
# ============================================================
set -euo pipefail

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
HOME_DIR="${HOME:-/data/data/com.termux/files/home}"
PKG_DIR="$PREFIX/lib/node_modules/@tencent-ai/codebuddy-code"
PTY_LOADER="$PKG_DIR/node_modules/@lydell/node-pty"
PTY_DEST="$PKG_DIR/node_modules/@lydell/node-pty-android-arm64"
PTY_CACHE_DIR="$HOME_DIR/.cache/codebuddy-pty-rebuild"
PTY_PKG_NAME="@lydell/node-pty-android-arm64"
NODE_PTY_SRC_VER="NODE_PTY_SRC_VER_PLACEHOLDER"
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[1;33m'; BLU='\033[1;36m'; NC='\033[0m'
ok()   { echo -e "${GRN}✓${NC} $*"; }
info() { echo -e "${BLU}▸${NC} $*"; }
warn() { echo -e "${YEL}⚠${NC} $*"; }
fail() { echo -e "${RED}✗${NC} $*"; exit 1; }

[ -d "$PKG_DIR" ] || fail "CodeBuddy 未安装: $PKG_DIR"
[ -d "$PTY_LOADER" ] || fail "缺少 @lydell/node-pty (loader), 请先: npm install -g @tencent-ai/codebuddy-code"

LYDELL_VER=$(node -p "require('$PTY_LOADER/package.json').version")
[ -n "$LYDELL_VER" ] || fail "无法读取 @lydell/node-pty 版本"

pty_ok() {
    [ -f "$PTY_DEST/build/Release/pty.node" ] || return 1
    [ -f "$PTY_DEST/package.json" ] || return 1
    node -e "require('$PTY_LOADER')" 2>/dev/null
}

# 注意: 光靠 pty_ok 不够 —— 若 codebuddy 升级后 lydell JS 层换了版本, 而
# npm 又没把旧的 pty.node 清掉, 它依然"能加载", 于是被误判成已就绪, 结果
# 新版 JS 层配旧原生模块。所以还要比对组装时写进 package.json 的版本号。
PTY_BUILT_VER=$(node -p "require('$PTY_DEST/package.json').version" 2>/dev/null || echo "")
if [ "$FORCE" != 1 ] && [ "$PTY_BUILT_VER" = "$LYDELL_VER" ] && pty_ok; then
    ok "node-pty 已就绪 (lydell $LYDELL_VER), 无需重建 (--force 可强制)"
    exit 0
fi

WORK="${TMPDIR:-$HOME_DIR}/codebuddy-pty-$$"
mkdir -p "$WORK"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

mkdir -p "$PTY_CACHE_DIR"
CACHE_TAR="$PTY_CACHE_DIR/android-arm64-${LYDELL_VER}-src${NODE_PTY_SRC_VER}.tar.gz"

# 缓存命中: 直接解压 (同 lydell + node-pty 源码版本, 跳过编译)
if [ "$FORCE" != 1 ] && [ -f "$CACHE_TAR" ]; then
    info "命中缓存: $(basename "$CACHE_TAR")"
    mkdir -p "$(dirname "$PTY_DEST")"
    rm -rf "$PTY_DEST"
    tar -xzf "$CACHE_TAR" -C "$(dirname "$PTY_DEST")"
    if pty_ok; then
        ok "node-pty 已从缓存恢复 (lydell $LYDELL_VER)"
        exit 0
    fi
    warn "缓存校验失败, 回退源码编译…"
    rm -rf "$PTY_DEST"
fi

info "重建 node-pty: lydell JS v$LYDELL_VER + node-pty 源码 v$NODE_PTY_SRC_VER"
cd "$WORK"

info "下载源码…"
npm pack "node-pty@${NODE_PTY_SRC_VER}" --silent >/dev/null
npm pack "@lydell/node-pty-linux-arm64@${LYDELL_VER}" --silent >/dev/null
tar xzf "node-pty-${NODE_PTY_SRC_VER}.tgz"
mv package pty_src
lydell_tgz=$(ls lydell-node-pty-linux-arm64-*.tgz 2>/dev/null | head -1)
[ -n "$lydell_tgz" ] || fail "lydell 平台包下载失败 (@lydell/node-pty-linux-arm64@${LYDELL_VER})"
tar xzf "$lydell_tgz"
mv package lydell_src

info "node-gyp 编译 native (bionic)…"
cd pty_src
npm install --ignore-scripts --no-save node-addon-api@7 --silent >/dev/null 2>&1 || true
node "$PREFIX/lib/node_modules/npm/node_modules/node-gyp/bin/node-gyp.js" rebuild \
    || fail "node-gyp 编译失败 (缺 clang/make/python? 试: pkg install clang make python)"
[ -f build/Release/pty.node ] || fail "编译产物缺失: build/Release/pty.node"

info "组装 $PTY_PKG_NAME…"
mkdir -p "$PTY_DEST/lib" "$PTY_DEST/build/Release"
cp -a "$WORK/lydell_src/lib/." "$PTY_DEST/lib/"
cp build/Release/pty.node "$PTY_DEST/build/Release/pty.node"
cat > "$PTY_DEST/package.json" << JSON_EOF
{
  "name": "$PTY_PKG_NAME",
  "version": "${LYDELL_VER}",
  "description": "node-pty for android-arm64 (built from source on Termux)",
  "license": "MIT",
  "type": "commonjs",
  "main": "./lib/index.js",
  "exports": { ".": { "default": "./lib/index.js" } }
}
JSON_EOF

tar -czf "$CACHE_TAR" -C "$(dirname "$PTY_DEST")" "node-pty-android-arm64" 2>/dev/null || true

pty_ok || fail "组装后加载验证失败"
ok "node-pty 就绪: $PTY_DEST"
PTY_REBUILD_EOF
    # 注入源码版本号 (heredoc 用引号防展开, 此处替换占位符)
    sed -i "s|NODE_PTY_SRC_VER_PLACEHOLDER|${NODE_PTY_SRC_VER}|g" "$PTY_REBUILD"
    chmod +x "$PTY_REBUILD"
    info "node-pty 重建脚本: $PTY_REBUILD"
}

run_pty_rebuild() {
    local extra="${1:-}"
    local rc=0
    # 提示语不写"编译" —— 多数情况下它只是跳过或从缓存恢复, 0.1 秒的事,
    # 只有缓存里没有对应版本才会真编译 (那时脚本自己会打印"下载源码/编译")
    if [ "$extra" = "force" ]; then
        run_with_spinner "处理 node-pty 原生模块" "$PTY_REBUILD" --force || rc=$?
    else
        run_with_spinner "处理 node-pty 原生模块" "$PTY_REBUILD" || rc=$?
    fi
    # 重建脚本的提示值得看: 是"无需重建"、"已从缓存恢复"还是真编译了
    if [ "$rc" -ne 0 ]; then
        printf '%s\n' "$SPIN_OUT" | head -20
        warn "node-pty 重建失败 (shell 工具可能降级, 可手动: codebuddy-pty-rebuild)"
    else
        printf '%s\n' "$SPIN_OUT"
    fi
}

# ---------- 启动 wrapper ----------
write_wrapper() {
    mkdir -p "$LOCAL_BIN"
    cat > "$WRAPPER" << 'WRAPPER_EOF'
#!/data/data/com.termux/files/usr/bin/bash
# ============================================================
# codebuddy wrapper for Termux (由 codebuddy-cli-termux/install.sh 生成)
# - 启动前检查 npm 最新版: 非最新 → 更新 + shebang/node-pty 修复 → 启动
#   已最新 → 直接启动 (可用 CODEBUDDY_NO_AUTO_UPDATE=1 跳过检查)
# - 更新失败不阻塞, 用现有版本启动
# - 手动更新: codebuddy update
# - 关闭 codebuddy 内置 updater (native install 在 Termux 不可用)
# ============================================================
set -euo pipefail

export DISABLE_AUTOUPDATER="${DISABLE_AUTOUPDATER:-1}"

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
HOME_DIR="${HOME:-/data/data/com.termux/files/home}"
NPM_PKG="@tencent-ai/codebuddy-code"
PKG_DIR="$PREFIX/lib/node_modules/@tencent-ai/codebuddy-code"
PKG_BIN="$PKG_DIR/bin"
REAL_JS="$PKG_BIN/codebuddy"
PTY_REBUILD="$HOME_DIR/.local/bin/codebuddy-pty-rebuild"
PTY_DEST="$PKG_DIR/node_modules/@lydell/node-pty-android-arm64"

current_version() {
    node -p "require('$PKG_DIR/package.json').version" 2>/dev/null || echo ""
}

latest_version() {
    npm view "$NPM_PKG" version --fetch-timeout=10000 --fetch-retries=0 2>/dev/null || true
}

version_ge() {
    [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1" ]
}

# npm 会重写 bin 文件 shebang, 更新后必须重跑 (幂等)
fix_shebangs() {
    local f first
    [ -d "$PKG_BIN" ] || return 0
    for f in "$PKG_BIN"/*; do
        [ -f "$f" ] || continue
        first=$(head -1 "$f" 2>/dev/null || true)
        case "$first" in
            '#!/usr/bin/env '*)
                # PREFIX 已含开头 /, 替换串不能再加 / 否则 shebang 变 #!//
                sed -i "1s|^#!/usr/bin/env |#!$PREFIX/bin/env |" "$f"
                ;;
        esac
    done
    return 0
}

# npm update 会清掉手工放入的 node-pty-android-arm64 → 更新后补回。
#
# 这里**不能用 --force**: 它会同时跳过"就绪检查"和"缓存命中"两个分支,
# 于是每次 codebuddy 更新都要重新 npm pack 源码 + node-gyp 编译一遍
# (数十秒, 且毫无必要 —— node-pty 源码版本是钉死的)。
# 不带 --force 时的行为:
#   版本号一致且产物完好 → 零开销跳过
#   产物缺失/lydell 版本变了 → 命中缓存直接解压恢复 (秒回)
#   缓存里没有对应版本 → 才真正下载源码编译
rebuild_pty() {
    if [ -x "$PTY_REBUILD" ]; then
        "$PTY_REBUILD" >/dev/null 2>&1 \
            || echo "!! node-pty 重建失败 (shell 工具可能降级), 可手动: codebuddy-pty-rebuild" >&2
    fi
}

# npm 对含 extraneous 文件的包 rmdir 会 ENOTEMPTY → 预清理注入物, 失败则卸载强删重装
npm_install_latest() {
    rm -rf "$PTY_DEST" 2>/dev/null || true
    if npm install -g "${NPM_PKG}@latest" 2>&1; then
        return 0
    fi
    echo "→ npm 替换失败 (可能 ENOTEMPTY), 卸载后强删重装…"
    npm uninstall -g "$NPM_PKG" >/dev/null 2>&1 || true
    rm -rf "$PKG_DIR"
    npm install -g "${NPM_PKG}@latest" 2>&1
}

do_update() {
    echo "→ 更新 $NPM_PKG (npm)…"
    if ! npm_install_latest; then
        echo "!! npm 更新失败" >&2
        return 1
    fi
    echo "→ 修复 shebang…"
    fix_shebangs
    echo "→ 重建 node-pty (android-arm64)…"
    rebuild_pty
    echo "✓ 已更新: $(current_version)"
    return 0
}

# pty 包缺失时补建 (正常存在则零开销跳过)
ensure_pty() {
    [ -f "$PTY_DEST/build/Release/pty.node" ] && [ -f "$PTY_DEST/package.json" ] && return 0
    [ -x "$PTY_REBUILD" ] || return 0
    echo "→ node-pty 缺失, 重建中…"
    rebuild_pty
}

# 启动前确认入口仍在 (npm 更新中途失败可能留半残)
ensure_entry() {
    [ -f "$REAL_JS" ] && return 0
    echo "!! 入口缺失: $REAL_JS" >&2
    echo "!! 尝试修复安装…" >&2
    npm_install_latest >&2 || true
    fix_shebangs
    [ -f "$REAL_JS" ] || {
        echo "!! 修复失败, 请手动: npm install -g ${NPM_PKG}@latest" >&2
        exit 1
    }
}

case "${1:-}" in
    update|-u|--update|upgrade)
        do_update || { echo "!! 更新失败" >&2; exit 1; }
        ;;
    --version|-V|-v|version)
        # 版本查询不触发更新检查 (保持快速/可脚本化)
        exec node "$REAL_JS" "$@"
        ;;
    *)
        if [ "${CODEBUDDY_NO_AUTO_UPDATE:-0}" != "1" ] && command -v npm >/dev/null 2>&1; then
            LATEST="$(latest_version)"
            if [ -n "$LATEST" ]; then
                CURRENT="$(current_version)"
                if [ -z "$CURRENT" ] || ! version_ge "$CURRENT" "$LATEST"; then
                    echo "→ 检测到新版本 v${LATEST} (当前 ${CURRENT:-未知}), 更新并修复…"
                    if do_update; then
                        echo "→ 更新完成, 启动 codebuddy…"
                    else
                        echo "!! 自动更新失败, 使用现有版本启动" >&2
                    fi
                fi
            fi
            # 网络差时 latest 为空 → 静默跳过, 直接启动
        fi
        ensure_entry
        ensure_pty
        exec node "$REAL_JS" "$@"
        ;;
esac
WRAPPER_EOF
    chmod +x "$WRAPPER"
    ln -sfn "$WRAPPER" "$LOCAL_BIN/cbc"

    # 确保 ~/.local/bin 优先于 $PREFIX/bin (wrapper 覆盖 npm 原始 bin)
    if ! grep -q '\.local/bin' "$HOME_DIR/.bashrc" 2>/dev/null; then
        echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME_DIR/.bashrc"
        info "~/.local/bin 已加入 PATH (~/.bashrc)"
    fi
    ok "启动 wrapper: $WRAPPER (cbc → 同脚本)"
}

# ---------- 验证 ----------
verify() {
    local ver
    ver=$(PATH="$LOCAL_BIN:$PREFIX/bin:$PATH" codebuddy --version 2>/dev/null) \
        || ver=$(node "$PKG_BIN/codebuddy" --version 2>/dev/null) \
        || fail "验证失败: codebuddy 无法运行"
    ok "安装成功: $ver"

    local first
    first=$(head -1 "$PKG_BIN/codebuddy" 2>/dev/null || true)
    case "$first" in
        "#!$PREFIX/bin/env "*|"#!$PREFIX/bin/node"*)
            ok "shebang 正常"
            ;;
        *)
            warn "shebang 可能未修复: $first"
            ;;
    esac

    if [ -f "$PTY_DEST/build/Release/pty.node" ] && node -e "require('$PTY_LOADER')" 2>/dev/null; then
        ok "node-pty (android-arm64) 正常"
    else
        warn "node-pty 未就绪 — 可手动: codebuddy-pty-rebuild"
    fi
}

# ---------- 配置指引 ----------
show_guide() {
    echo
    echo "=============================================================="
    echo "  安装完成! 下一步"
    echo "=============================================================="
    echo
    echo "  1. 启动并登录 (TUI 内执行 /login):"
    echo "       codebuddy"
    echo
    echo "  2. 常用命令:"
    echo "       codebuddy                启动 (自动检查更新)"
    echo "       codebuddy update         手动更新 + 修复"
    echo "       codebuddy-pty-rebuild    手动重建 node-pty"
    echo "       CODEBUDDY_NO_AUTO_UPDATE=1 codebuddy   跳过更新检查"
    echo
    echo "  3. 重跑本脚本即重装/修复 (幂等); --uninstall 卸载"
    echo
    echo "  安装完成后请退出 Termux 重新打开 (或新开一个会话), 让 PATH 生效。"
    echo
    echo "  建议的 Android 设置 (防止 Termux 被系统杀后台):"
    echo "    1. 开发者选项 → 停止限制子进程: 开启"
    echo "    2. 系统设置 → 应用 → Termux → 电池: 不优化"
    echo "    3. 后台活动 / 自启动: 设为无限制"
    echo
    echo "  注意: 请勿运行 codebuddy install (native 安装在 Termux 不可用)"
    echo "=============================================================="
    echo
}

# ---------- 卸载 ----------
uninstall() {
    warn "将卸载 CodeBuddy CLI…"
    npm uninstall -g "$NPM_PKG" >/dev/null 2>&1 || true
    rm -f "$WRAPPER" "$LOCAL_BIN/cbc" "$PTY_REBUILD"
    ok "已卸载 npm 包与 wrapper。"
    warn "保留配置: ~/.codebuddy  (如需删除: rm -rf ~/.codebuddy)"
    warn "保留缓存:  ~/.cache/codebuddy-pty-rebuild"
    exit 0
}

# ---------- 主流程 ----------
case "${1:-}" in
    --uninstall|-uninstall) uninstall ;;
    --update|-update) FORCE_UPDATE=1 ;;
esac

info "codebuddy-cli-termux 安装脚本 — 仅支持 Termux aarch64"
check_environment
fix_mirror
upgrade_packages
install_dependencies

if [ "$FORCE_UPDATE" = 1 ]; then
    info "强制更新: npm 最新版 + 全量修复重建"
    install_codebuddy
    fix_shebangs "verbose"
    write_pty_rebuild_script
    run_pty_rebuild force
else
    install_codebuddy
    fix_shebangs "verbose"
    write_pty_rebuild_script
    run_pty_rebuild
fi

write_wrapper
verify
show_guide
