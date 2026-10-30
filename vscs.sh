#!/usr/bin/env bash
#
# vscs.sh — VS Code Server 离线安装打包器（glibc / 新目录布局）
#
# 在【联网机】上:
#   ./vscs.sh download [--quality stable|insider] [--commit <id>] [--arch x64|arm64|armhf] [-o <out>]
#   → 默认从官方 update API 取最新版本+commit，生成自解压 install.sh（内含 server + cli 两个 tar）。
#
#   ./vscs.sh windows [--quality stable|insider] [-o <out>]
#   → 下载最新 Windows x64 用户安装包（VSCodeUserSetup-x64-<版本>.exe）。
#
# 在【离线机】上:
#   bash <生成的>.install.sh [--home <自定义VSCODE_HOME>]
#   → 自动按新布局装到 ~/.vscode-server[-insiders]/。
#
# 批量下载插件 vsix（只下载，离线机自行 code --install-extension）:
#   ./vscs.sh extensions <publisher.name ...> [-f <清单>] [--arch x64|arm64|armhf] [-o <dir>]
#   可命令行直接传，或 -f 读清单，也可混用；每个 publisher.name 可选 @版本 和 /平台，# 为注释。
#   已存在且版本匹配（最新版/钉版本）的 vsix 会自动跳过；钉的版本落后最新时打印警告。
#
# ⚠️ 适用边界:
#   - 面向【新版客户端】VS Code 1.86+（glibc ≥ 2.28 的新 cli/servers 布局）。
#   - 老系统(CentOS 7 / glibc 2.17) 上限为 1.85.2，请改用
#     「VSCode 1.85.2 安装」那篇笔记的钉版本方案，本脚本不适用。
#   - 仅 glibc（普通 Linux）。不支持 musl/Alpine —— Remote-SSH 没有 musl server。

set -euo pipefail

err() { echo "错误: $*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
用法:
  vscs.sh download [选项]        在联网机下载并打包成自解压安装包

选项:
  --quality stable|insider       渠道，默认 stable（insider 即 Insiders）
  --commit <40位commit id>       手动指定 commit；默认从官方 update API 取最新版本的 commit
  --arch x64|arm64|armhf         CPU 架构，默认 x64
  -o, --output <path>            产物文件名，默认 vscode-server-<quality>-<arch>-<commit12>.install.sh
  -h, --help                     显示本帮助

示例:
  ./vscs.sh download                                 # stable 最新版 + x64
  ./vscs.sh download --quality insider               # Insiders 最新版
  ./vscs.sh download --commit 8b377503... --arch arm64

下载 Windows x64 用户安装包（默认最新版，官网渠道）:
  vscs.sh windows [--quality stable|insider] [-o <path>]
  默认文件名 VSCodeUserSetup-x64-<版本>.exe；带官方 sha256 校验。

下载插件 vsix（只下载，离线机自行安装）:
  vscs.sh extensions [publisher.name[@版本][/<平台>] ...] [-f <清单文件>] [--arch ...] [-o <dir>]
  可直接在命令行传入，或用 -f 读清单文件，也可两者混用；格式同：
    publisher.name              # 最新版 + 目标架构(自动 platform 回退)
    publisher.name@1.21.2       # 钉版本
    publisher.name/linux-x64    # 强制平台
  已存在且版本匹配的 vsix 自动跳过（损坏的重下）；钉的版本落后最新时打印警告。
  例:
    vscs.sh extensions ms-vscode.cpptools golang.Go
    vscs.sh extensions -f extensions.txt

离线机用法:
  bash <生成的>.install.sh [--home <VSCODE_HOME>]
USAGE
  exit 0
}

# GET 到 stdout：curl 优先，wget 兜底
http_get() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 5 --retry-all-errors --connect-timeout 15 "$1"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- "$1"
  else
    err "需要 wget 或 curl，均未找到"
  fi
}

# 从官方 update API 取指定渠道的最新版本号，写入全局 VERSION
resolve_latest_release() {
  local quality="$1" resp
  resp="$(http_get "https://update.code.visualstudio.com/api/releases/${quality}")" || return 1
  VERSION="$(printf '%s' "$resp" | grep -oE '"[0-9]+\.[0-9]+\.[0-9]+"' | head -1 | tr -d '"')"
  [[ -n "$VERSION" ]]
}

# 从官方 update API 取 <版本,平台,渠道> 的构建信息，写入全局 COMMIT / BUILD_URL / BUILD_SHA256
resolve_build() {
  local ver="$1" platform="$2" quality="$3" resp
  resp="$(http_get "https://update.code.visualstudio.com/api/versions/${ver}/${platform}/${quality}")" || return 1
  COMMIT="$(printf '%s' "$resp" | grep -oE '"version":"[0-9a-f]{40}"' | head -1 | sed -E 's/.*"([0-9a-f]{40})".*/\1/')"
  BUILD_URL="$(printf '%s' "$resp" | grep -oE '"url":"[^"]+"' | head -1 | sed -E 's/^"url":"//; s/"$//')"
  BUILD_SHA256="$(printf '%s' "$resp" | grep -oE '"sha256hash":"[0-9a-f]{64}"' | head -1 | sed -E 's/.*"([0-9a-f]{64})".*/\1/')"
  [[ -n "$COMMIT" ]]
}

# 从已下载的 server tarball 的 product.json 里读出 VS Code 版本号
peek_version() {
  tar --wildcards -xzOf "$1" '*/product.json' 2>/dev/null \
    | grep -oE '"version"[[:space:]]*:[[:space:]]*"[0-9][^"]*"' \
    | head -1 | sed -E 's/.*"([0-9][^"]*)"/\1/'
}

fetch() {
  local url="$1" out="$2"
  if command -v wget >/dev/null 2>&1; then
    wget -nv -O "$out" "$url"
  elif command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 --retry-all-errors -o "$out" "$url"
  else
    err "下载需要 wget 或 curl，均未找到"
  fi
}

# 下载并校验是合法 gzip（commit 填错时服务器常返回 404 HTML 页）
download_one() {
  local url="$1" out="$2" what="$3"
  echo "  下载 $what ..."
  fetch "$url" "$out" || err "下载失败: $url"
  if ! gzip -t "$out" 2>/dev/null; then
    rm -f "$out"
    err "$what 校验失败（不是有效 gzip，多半是 commit 与客户端不匹配，服务器返回了 404 页）: $url"
  fi
}

# 把生成的自解压安装器头部写到 $1
write_installer_header() {
  cat > "$1" <<'INSTALLER_EOF'
#!/usr/bin/env bash
# VS Code Server 离线安装器（自解压，由 vscs.sh 生成）
# 用法: bash <此文件> [--home <VSCODE_HOME>]
set -euo pipefail

HEADER_LINES=__HEADER_LINES__

CUSTOM_HOME=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --home) CUSTOM_HOME="${2:-}"; shift 2 ;;
    -h|--help)
      cat <<'EOH'
VS Code Server 离线安装器（自解压，由 vscs.sh 生成）
用法:
  bash <此文件> [--home <VSCODE_HOME>]
默认装到 ~/.vscode-server (stable) 或 ~/.vscode-server-insiders (insiders)。
EOH
      exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 1 ;;
  esac
done

for c in tar gzip tail; do
  command -v "$c" >/dev/null 2>&1 || { echo "缺少依赖: $c" >&2; exit 1; }
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 读取自身尾部 = payload.tar.gz
tail -n +$((HEADER_LINES + 1)) "$0" > "$TMP/payload.tar.gz"
tar -xzf "$TMP/payload.tar.gz" -C "$TMP"
# shellcheck disable=SC1091
. "$TMP/manifest.env"

if [[ -n "$CUSTOM_HOME" ]]; then
  VSCODE_HOME="$CUSTOM_HOME"
elif [[ "$URL_QUALITY" == "insider" ]]; then
  VSCODE_HOME="$HOME/.vscode-server-insiders"
else
  VSCODE_HOME="$HOME/.vscode-server"
fi

# 1) server
SERVER_DIR="$VSCODE_HOME/cli/servers/${PREFIX}-${COMMIT}/server"
mkdir -p "$SERVER_DIR"
echo "解压 server -> $SERVER_DIR"
tar -xzf "$TMP/${SERVER_TAR}" --strip-components=1 -C "$SERVER_DIR"

# 2) cli（解压后改名为 code[-insiders]-<commit>）
echo "解压 cli -> $VSCODE_HOME"
tar -xzf "$TMP/${CLI_TAR}" -C "$VSCODE_HOME"
mv -f "$VSCODE_HOME/${CLI_BIN}" "$VSCODE_HOME/${CLI_BIN}-${COMMIT}"

cat <<EOF

完成 ✓
  VS Code  : ${VERSION:-未知}   ($URL_QUALITY, $ARCH)
  commit   : $COMMIT
  quality  : $URL_QUALITY ($PREFIX)
  arch     : $ARCH
  位置     : $VSCODE_HOME
  server   : $SERVER_DIR
  cli      : $VSCODE_HOME/${CLI_BIN}-${COMMIT}

下一步: 在 VS Code 用 Remote-SSH 重新连接此机器即可。
若目标机 glibc < 2.28 (如 CentOS 7)，此新版 server 无法启动，请改用 1.85.2 钉版本方案。
EOF

exit 0
__PAYLOAD_BELOW__
INSTALLER_EOF
}

cmd_download() {
  local QUALITY="stable" ARCH="x64" OUTPUT=""
  COMMIT=""; VERSION=""   # 全局：resolve_build / --commit 写入；VERSION 可能为空（手动 commit 时下载后再补）
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --quality) QUALITY="${2:-}"; shift 2 ;;
      --commit)  COMMIT="${2:-}";  shift 2 ;;
      --arch)    ARCH="${2:-}";    shift 2 ;;
      -o|--output) OUTPUT="${2:-}"; shift 2 ;;
      -h|--help) usage ;;
      *) err "未知参数: $1（用 --help 查看用法）" ;;
    esac
  done

  [[ "$QUALITY" =~ ^(stable|insider)$ ]] || err "--quality 必须是 stable 或 insider"
  [[ "$ARCH" =~ ^(x64|arm64|armhf)$ ]] || err "--arch 必须是 x64 | arm64 | armhf"

  local URL_QUALITY PREFIX CLI_BIN
  case "$QUALITY" in
    stable)  URL_QUALITY=stable;  PREFIX=Stable;   CLI_BIN=code ;;
    insider) URL_QUALITY=insider; PREFIX=Insiders; CLI_BIN=code-insiders ;;
  esac

  if [[ -z "$COMMIT" ]]; then
    echo "==> 查询 ${QUALITY} 最新版本 ..."
    resolve_latest_release "$URL_QUALITY" \
      || err "无法从 update API 获取最新版本（网络问题？）。请用 --commit 指定 40 位 commit id。"
    resolve_build "$VERSION" "linux-x64" "$URL_QUALITY" \
      || err "无法解析 $VERSION 的 commit。请用 --commit 指定 40 位 commit id。"
  fi
  [[ "$COMMIT" =~ ^[0-9a-f]{40}$ ]] || err "commit 格式不对: $COMMIT（应为 40 位小写十六进制）"

  local SERVER_TAR="vscode-server-linux-${ARCH}.tar.gz"
  local CLI_TAR="vscode_cli_linux_${ARCH}_cli.tar.gz"
  [[ -n "$OUTPUT" ]] || OUTPUT="vscode-server-${URL_QUALITY}-${ARCH}-${COMMIT:0:12}.install.sh"

  WORK="$(mktemp -d)"   # 全局变量，确保 EXIT trap 触发时仍在作用域内可清理
  trap '[ -n "${WORK:-}" ] && rm -rf "$WORK"' EXIT

  if [[ -n "$VERSION" ]]; then
    echo "==> VS Code $VERSION  ($QUALITY, $ARCH)  commit=$COMMIT"
  else
    echo "==> commit=$COMMIT  ($QUALITY, $ARCH)  [版本将在下载后从 product.json 识别]"
  fi
  echo "==> 输出: $OUTPUT"

  download_one "https://update.code.visualstudio.com/commit:${COMMIT}/server-linux-${ARCH}/${URL_QUALITY}" \
               "$WORK/$SERVER_TAR" "server ($SERVER_TAR)"
  download_one "https://vscode.download.prss.microsoft.com/dbazure/download/${URL_QUALITY}/${COMMIT}/${CLI_TAR}" \
               "$WORK/$CLI_TAR" "cli ($CLI_TAR)"

  # 手动 --commit 模式下 VERSION 还未知，从刚下载的 server 包内 product.json 读出
  [[ -n "$VERSION" ]] || VERSION="$(peek_version "$WORK/$SERVER_TAR")"

  cat > "$WORK/manifest.env" <<EOF
VERSION=$VERSION
COMMIT=$COMMIT
URL_QUALITY=$URL_QUALITY
PREFIX=$PREFIX
CLI_BIN=$CLI_BIN
ARCH=$ARCH
SERVER_TAR=$SERVER_TAR
CLI_TAR=$CLI_TAR
EOF

  ( cd "$WORK" && tar -czf payload.tar.gz "$SERVER_TAR" "$CLI_TAR" manifest.env )

  write_installer_header "$WORK/header.sh"
  local HL; HL="$(wc -l < "$WORK/header.sh")"
  sed -i "s/__HEADER_LINES__/$HL/" "$WORK/header.sh"

  cat "$WORK/header.sh" "$WORK/payload.tar.gz" > "$OUTPUT"
  chmod +x "$OUTPUT"

  echo
  echo "==> 完成 ✓  ($(ls -lh "$OUTPUT" | awk '{print $5}'))"
  echo "    拷到离线机后运行:  bash $(basename "$OUTPUT")"
}

# ---- extensions 子命令：按清单批量下载插件 vsix（只下载，不安装）----

# 解析一行清单到全局 EXT_ID / EXT_VERSION / EXT_PLATFORM
# 格式: publisher.name[@version][/platform]
parse_ext_line() {
  local spec="$1" rest v
  EXT_ID="${spec%%[/@]*}"
  rest="${spec#"$EXT_ID"}"
  EXT_VERSION=""; EXT_PLATFORM=""
  if [[ "$rest" == @* ]]; then
    v="${rest#@}"
    EXT_VERSION="${v%%/*}"
    if [[ "$v" == */* ]]; then EXT_PLATFORM="${v#*/}"; fi
  elif [[ "$rest" == /* ]]; then
    EXT_PLATFORM="${rest#/}"
  fi
}

# 查询 Marketplace 拿最新版本号；失败/不存在返回非 0（stdout 空）
resolve_latest_version() {
  local id="$1" resp
  resp="$(curl -fsSL --compressed -X POST \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json;api-version=6.1-preview.1' \
    'https://marketplace.visualstudio.com/_apis/public/gallery/extensionquery' \
    -d "{\"filters\":[{\"criteria\":[{\"filterType\":7,\"value\":\"$id\"}]}],\"flags\":914}" 2>/dev/null)" || return 1
  printf '%s' "$resp" | grep -oE '"version":"[0-9][^"]*"' | head -1 | sed -E 's/.*"([0-9][^"]*)"/\1/'
}

# 下载 vsix：platform 优先，失败回退 universal。成功返回 0
# 注意 --compressed：Marketplace 的 vspackage 响应是 gzip 压缩的，不加会存成 gzip 流（PK 魔数校验失败）
download_vsix() {
  local out="$1" base="$2" platform="$3"
  if [[ -n "$platform" ]]; then
    curl -fsSL --compressed --retry 2 -o "$out" "$base?targetPlatform=$platform" 2>/dev/null && return 0
    curl -fsSL --compressed --retry 2 -o "$out" "$base" 2>/dev/null && return 0
  else
    curl -fsSL --compressed --retry 2 -o "$out" "$base" 2>/dev/null && return 0
  fi
  return 1
}

cmd_extensions() {
  local LIST="" ARCH="x64" OUT=""
  local -a SPECS=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -f|--list) LIST="${2:-}"; shift 2 ;;
      --arch)    ARCH="${2:-}"; shift 2 ;;
      -o|--output) OUT="${2:-}"; shift 2 ;;
      -h|--help) usage ;;
      -*) err "未知选项: $1（用 --help 查看用法）" ;;
      *) SPECS+=("$1"); shift ;;        # 命令行直接传入的 publisher.name ...
    esac
  done

  if [[ -z "$LIST" && ${#SPECS[@]} -eq 0 ]]; then
    err "需要 -f <清单文件> 或在命令行直接传入 publisher.name ..."
  fi
  if [[ -n "$LIST" && ! -f "$LIST" ]]; then err "清单文件不存在: $LIST"; fi
  [[ "$ARCH" =~ ^(x64|arm64|armhf)$ ]] || err "--arch 必须是 x64 | arm64 | armhf"
  command -v curl >/dev/null 2>&1 || err "extensions 子命令需要 curl"
  [[ -n "$OUT" ]] || OUT="./vscode-extensions-linux-${ARCH}"
  mkdir -p "$OUT"

  # 汇总要处理的 spec：清单文件每行 + 命令行位置参数（可混用）
  local -a ALL=()
  local raw
  if [[ -n "$LIST" ]]; then
    while IFS= read -r raw || [[ -n "$raw" ]]; do ALL+=("$raw"); done < "$LIST"
  fi
  if (( ${#SPECS[@]} )); then ALL+=("${SPECS[@]}"); fi

  local DEFAULT_PLAT="linux-${ARCH}"
  local ok=0 fail=0 skip=0 line
  for raw in "${ALL[@]}"; do
    line="$(printf '%s' "${raw%%#*}" | tr -d '[:space:]')"
    if [[ -z "$line" ]]; then continue; fi
    parse_ext_line "$line"
    local id="$EXT_ID" ver="$EXT_VERSION" plat="$EXT_PLATFORM"
    if [[ -z "$plat" ]]; then plat="$DEFAULT_PLAT"; fi
    echo "==> $id"
    if [[ -z "$ver" ]]; then
      ver="$(resolve_latest_version "$id")" || true
      if [[ -z "$ver" ]]; then
        echo "  ✗ 找不到该插件或网络异常，跳过"; fail=$((fail+1)); continue
      fi
      echo "    最新版: $ver"
    else
      # 钉版本：顺带查一下最新版，落后时警告（仍按钉的版本下载，不擅自升级）
      local latest; latest="$(resolve_latest_version "$id")" || true
      if [[ -n "$latest" && "$latest" != "$ver" ]]; then
        echo "    ⚠ 钉的版本 $ver 落后于最新版 $latest（仍按钉版本处理）"
      fi
    fi
    local pub="${id%%.*}" name="${id#*.}"
    local base="https://marketplace.visualstudio.com/_apis/public/gallery/publishers/${pub}/vsextensions/${name}/${ver}/vspackage"
    local fname="${OUT}/${id}-${ver}.vsix"
    # 下载前检测：已存在且版本匹配（即最新/钉的版本）则跳过；存在但损坏则重下
    if [[ -f "$fname" ]]; then
      if [[ "$(head -c2 "$fname" 2>/dev/null)" == "PK" ]]; then
        echo "    ✓ 已存在 ${id}-${ver}.vsix，跳过"
        skip=$((skip+1)); continue
      else
        echo "    已存在但文件损坏，重新下载"
        rm -f "$fname"
      fi
    fi
    if download_vsix "$fname" "$base" "$plat"; then
      if [[ "$(head -c2 "$fname" 2>/dev/null)" == "PK" ]]; then
        echo "    ✓ ${id}-${ver}.vsix  ($(ls -lh "$fname" | awk '{print $5}'))"
        ok=$((ok+1))
      else
        rm -f "$fname"
        echo "  ✗ 下载内容不是有效 vsix，跳过"; fail=$((fail+1))
      fi
    else
      rm -f "$fname"
      echo "  ✗ 下载失败，跳过"; fail=$((fail+1))
    fi
  done

  echo
  echo "==> 完成：成功 $ok / 已存在跳过 $skip / 失败 $fail  →  $OUT"
  echo "    离线机安装: code --install-extension ${OUT}/*.vsix"
  if [[ "$fail" -ne 0 ]]; then echo "    （有失败项，见上方 ✗）"; fi
}

# ---- windows 子命令：下载最新 Windows x64 用户安装包 ----

cmd_windows() {
  local QUALITY="stable" OUT=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --quality) QUALITY="${2:-}"; shift 2 ;;
      -o|--output) OUT="${2:-}"; shift 2 ;;
      -h|--help) usage ;;
      *) err "未知参数: $1（用 --help 查看用法）" ;;
    esac
  done
  [[ "$QUALITY" =~ ^(stable|insider)$ ]] || err "--quality 必须是 stable 或 insider"

  echo "==> 查询 ${QUALITY} 最新版本 ..."
  local url sha="" pinned=0
  if resolve_latest_release "$QUALITY" && resolve_build "$VERSION" "win32-x64-user" "$QUALITY" && [[ -n "$BUILD_URL" ]]; then
    url="$BUILD_URL"; sha="$BUILD_SHA256"; pinned=1
    echo "==> 最新版: $VERSION  commit=$COMMIT"
  else
    # API 不可用（insider 版本列表偶发故障）时回退到 evergreen 重定向地址
    url="https://update.code.visualstudio.com/latest/win32-x64-user/${QUALITY}"
    echo "==> 版本查询失败，改用 evergreen 地址下载（文件名不带版本号，无 sha256 校验）"
  fi

  if [[ -z "$OUT" ]]; then
    if [[ "$pinned" -eq 1 ]]; then OUT="VSCodeUserSetup-x64-${VERSION}.exe"; else OUT="VSCodeUserSetup-x64-${QUALITY}-latest.exe"; fi
  fi

  fetch "$url" "$OUT" || err "下载失败: $url"
  if [[ -n "$sha" ]] && command -v sha256sum >/dev/null 2>&1; then
    echo "$sha  $OUT" | sha256sum -c - || { rm -f "$OUT"; err "sha256 校验失败，已删除 $OUT"; }
  fi

  echo
  echo "==> 完成 ✓  $OUT ($(ls -lh "$OUT" | awk '{print $5}'))"
}

case "${1:-}" in
  download) shift; cmd_download "$@" ;;
  windows) shift; cmd_windows "$@" ;;
  extensions) shift; cmd_extensions "$@" ;;
  ""|-h|--help|help) usage ;;
  *) err "未知命令: ${1:-}（用 --help 查看用法）" ;;
esac
