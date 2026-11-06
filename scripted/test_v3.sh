#!/usr/bin/env bash
# msys2_compare_toolchain.sh  v3
# 真实落盘工具链到临时 root，再 dry-run / 实装目标包，消除 --assume-installed 的重合问题。
#
# 用法（在 MSYS2 CLANG64 shell 中）：
#   bash msys2_compare_toolchain.sh
#   FULL=1 bash msys2_compare_toolchain.sh          # 目标包也真实安装，用 pacman -Q 差集
#   TESS_LANG=all bash msys2_compare_toolchain.sh   # 全部 tesseract 语言包
#   WORKDIR=/d/msys2-test KEEP=1 bash ...           # 指定大分区并保留临时目录
#   NOSCRIPT=1 bash ...                             # 安装脚本报错时跳过 scriptlet
#
# 输出：
#   msys2_clang64_no_toolchain.txt / .pkgs
#   msys2_clang64_with_toolchain.txt / .pkgs

set -euo pipefail
export LC_ALL=C

# ============ 配置 ============
PKG_PREFIX="mingw-w64-clang-x86_64"
TOOLCHAIN="${PKG_PREFIX}-toolchain"

TARGETS=(
  "${PKG_PREFIX}-ffmpeg"            # 已依赖 whisper.cpp，不重复加
  "${PKG_PREFIX}-tesseract-ocr"
)

TESS_LANG="${TESS_LANG:-eng}"
if [[ "$TESS_LANG" == "all" ]]; then
  mapfile -t DATA_PKGS < <(pacman -Ssq "^${PKG_PREFIX}-tesseract-data-")
else
  DATA_PKGS=("${PKG_PREFIX}-tesseract-data-${TESS_LANG}")
fi
TARGETS+=("${DATA_PKGS[@]}")

WORKDIR="${WORKDIR:-$(mktemp -d)}"
KEEP="${KEEP:-0}"
FULL="${FULL:-0}"
NOSCRIPT="${NOSCRIPT:-0}"

OUT_NONE="msys2_clang64_no_toolchain.txt"
OUT_WITH="msys2_clang64_with_toolchain.txt"
OUT_NONE_PKGS="msys2_clang64_no_toolchain.pkgs"
OUT_WITH_PKGS="msys2_clang64_with_toolchain.pkgs"

# ============ 工具函数 ============
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die() { log "错误: $*"; exit 1; }

cleanup() {
  if [[ "$KEEP" == "1" ]]; then
    log "保留临时目录: $WORKDIR"
  else
    rm -rf "$WORKDIR"
  fi
}
trap cleanup EXIT

PAC() {
  local d="$1"; shift
  pacman \
    --root "$d/root" \
    --dbpath "$d/db" \
    --cachedir "$d/cache" \
    --gpgdir /etc/pacman.d/gnupg \
    --config /etc/pacman.conf \
    "$@"
}

make_root() {
  local d
  d="$(mktemp -d -p "$WORKDIR" msys2-test.XXXXXX)"
  mkdir -p "$d/root" "$d/db" "$d/cache"
  printf '%s\n' "$d"
}

# 对仓库包列表求和 Installed Size（MiB），用临时 root 的 -Si
sum_si() {
  local d="$1"; shift
  local -a pkgs=("$@")
  ((${#pkgs[@]})) || { echo "0.00"; return; }
  PAC "$d" -Si "${pkgs[@]}" 2>/dev/null | awk '
    /^Installed Size[[:space:]]*:/ {
      sub(/^[^:]*:[[:space:]]*/, "")
      v=$1+0; u=$2; m=1
      if (u=="KiB") m=1/1024
      else if (u=="GiB") m=1024
      else if (u=="B") m=1/(1024*1024)
      sum += v*m
    }
    END { printf "%.2f", sum }
  '
}

# 对已安装包求和实际 Installed Size（MiB），用临时 root 的 -Qi
sum_qi() {
  local d="$1"; shift
  local -a pkgs=("$@")
  ((${#pkgs[@]})) || { echo "0.00"; return; }
  PAC "$d" -Qi "${pkgs[@]}" 2>/dev/null | awk '
    /^Installed Size[[:space:]]*:/ {
      sub(/^[^:]*:[[:space:]]*/, "")
      v=$1+0; u=$2; m=1
      if (u=="KiB") m=1/1024
      else if (u=="GiB") m=1024
      else if (u=="B") m=1/(1024*1024)
      sum += v*m
    }
    END { printf "%.2f", sum }
  '
}

# ============ 环境检查 ============
log "MSYSTEM=${MSYSTEM:-未设置}，目标前缀 ${PKG_PREFIX}"
if [[ "${MSYSTEM:-}" != "CLANG64" ]]; then
  log "警告：当前不是 CLANG64 shell；脚本显式使用 clang64 包名，通常仍可运行。"
fi

mkdir -p "$WORKDIR"
avail_mib=$(df -Pm "$WORKDIR" | awk 'NR==2{print $4}')
log "WORKDIR=$WORKDIR，可用空间 ${avail_mib} MiB"
if (( avail_mib < 3000 )); then
  log "警告：空间可能不足。工具链实装约 1–2 GiB；FULL=1 时目标包再加约 1.3 GiB。"
  log "      建议 WORKDIR=/d/msys2-test 指定大分区。"
fi

# ============ 场景 A：干净环境，无工具链 ============
log "场景 A：创建临时干净 root"
D_NONE="$(make_root)"

log "场景 A：-Sy"
if ! PAC "$D_NONE" -Sy 2>"$D_NONE/sy.err"; then
  cat "$D_NONE/sy.err" >&2
  die "临时 root -Sy 失败。若为 GPG 错误，先在真实环境执行 pacman-key --init && pacman-key --populate msys2"
fi

log "场景 A：dry-run 目标包（干净 root，无已安装包）"
if ! PAC "$D_NONE" -Sp --print-format '%n' "${TARGETS[@]}" \
      > "$OUT_NONE_PKGS" 2>"$D_NONE/sp.err"; then
  cat "$D_NONE/sp.err" >&2
  die "场景 A dry-run 失败，检查目标包是否存在于仓库：${TARGETS[*]}"
fi
[[ -s "$OUT_NONE_PKGS" ]] || die "场景 A 包列表为空"
mapfile -t PKGS_NONE < "$OUT_NONE_PKGS"
N_NONE="${#PKGS_NONE[@]}"
S_NONE="$(sum_si "$D_NONE" "${PKGS_NONE[@]}")"

{
  echo "# 场景: 干净 clang64，无工具链（dry-run 递归依赖）"
  echo "# 日期: $(date -Iseconds)"
  echo "# 目标包: ${TARGETS[*]}"
  echo "# 包数: ${N_NONE}"
  echo "# 总 Installed Size: ${S_NONE} MiB"
  echo "# 包列表:"
  cat "$OUT_NONE_PKGS"
} > "$OUT_NONE"
log "场景 A 完成：${N_NONE} 包，${S_NONE} MiB -> ${OUT_NONE}"

# ============ 场景 B：真实安装工具链到临时 root，再处理目标包 ============
log "场景 B：创建临时干净 root"
D_WITH="$(make_root)"

log "场景 B：-Sy"
if ! PAC "$D_WITH" -Sy 2>"$D_WITH/sy.err"; then
  cat "$D_WITH/sy.err" >&2
  die "场景 B 临时 root -Sy 失败"
fi

log "场景 B：真实安装工具链 ${TOOLCHAIN}（可能需要几分钟，下载约 1 GiB）"
INSTALL_OPTS=(-S --noconfirm --noprogressbar)
[[ "$NOSCRIPT" == "1" ]] && INSTALL_OPTS+=(--noscriptlet)

if ! PAC "$D_WITH" "${INSTALL_OPTS[@]}" "$TOOLCHAIN" \
      > "$D_WITH/install_toolchain.log" 2>&1; then
  log "工具链安装失败，日志末尾："
  tail -80 "$D_WITH/install_toolchain.log" >&2
  die "可尝试 NOSCRIPT=1 重新运行；或检查 WORKDIR 空间/网络/GPG"
fi

PAC "$D_WITH" -Qq > "$D_WITH/installed_toolchain.pkgs"
[[ -s "$D_WITH/installed_toolchain.pkgs" ]] || die "工具链安装后 -Qq 为空"
mapfile -t PKGS_TC < "$D_WITH/installed_toolchain.pkgs"
N_TC="${#PKGS_TC[@]}"
S_TC="$(sum_qi "$D_WITH" "${PKGS_TC[@]}")"
log "工具链已真实落盘：${N_TC} 包，实际 Installed Size ${S_TC} MiB"

if [[ "$FULL" == "1" ]]; then
  # ---------- 场景 B-full：真实安装目标包，用 -Q 差集 ----------
  log "场景 B(FULL)：真实安装目标包（下载约 188 MiB，安装约 1.3 GiB）"
  if ! PAC "$D_WITH" "${INSTALL_OPTS[@]}" --needed "${TARGETS[@]}" \
        > "$D_WITH/install_targets.log" 2>&1; then
    log "目标包安装失败，日志末尾："
    tail -80 "$D_WITH/install_targets.log" >&2
    die "可尝试 NOSCRIPT=1 重新运行"
  fi

  PAC "$D_WITH" -Qq > "$D_WITH/installed_full.pkgs"
  comm -13 \
    <(sort "$D_WITH/installed_toolchain.pkgs") \
    <(sort "$D_WITH/installed_full.pkgs") \
    > "$OUT_WITH_PKGS"

  mapfile -t PKGS_NEW < "$OUT_WITH_PKGS"
  N_WITH="${#PKGS_NEW[@]}"
  S_WITH="$(sum_qi "$D_WITH" "${PKGS_NEW[@]}")"
  METHOD="真实安装工具链 + 真实安装目标包，pacman -Q 差集"
else
  # ---------- 场景 B-dry：工具链已真实落盘，再 dry-run 目标包 ----------
  log "场景 B：工具链已落盘，dry-run 目标包（本地 db 已记录工具链，重合应消失）"
  if ! PAC "$D_WITH" -Sp --print-format '%n' "${TARGETS[@]}" \
        > "$OUT_WITH_PKGS" 2>"$D_WITH/sp.err"; then
    cat "$D_WITH/sp.err" >&2
    die "场景 B dry-run 失败"
  fi

  if [[ -s "$OUT_WITH_PKGS" ]]; then
    mapfile -t PKGS_NEW < "$OUT_WITH_PKGS"
    N_WITH="${#PKGS_NEW[@]}"
    S_WITH="$(sum_si "$D_WITH" "${PKGS_NEW[@]}")"
  else
    log "场景 B：目标包没有新增依赖（工具链已全部覆盖），合法结果"
    N_WITH=0; S_WITH="0.00"; : > "$OUT_WITH_PKGS"
  fi
  METHOD="真实安装工具链 + dry-run 目标包"
fi

# 重合检查：新增列表与工具链已安装包的交集（版本升级除外，正常应为 0）
comm -12 \
  <(sort "$D_WITH/installed_toolchain.pkgs") \
  <(sort "$OUT_WITH_PKGS") \
  > "$D_WITH/overlap.pkgs" || true
N_OVERLAP=$(wc -l < "$D_WITH/overlap.pkgs")

{
  echo "# 场景: 干净 clang64，工具链已真实安装到临时 root"
  echo "# 日期: $(date -Iseconds)"
  echo "# 方法: ${METHOD}"
  echo "# 工具链: ${TOOLCHAIN}"
  echo "# 工具链递归依赖包数: ${N_TC}"
  echo "# 工具链实际 Installed Size: ${S_TC} MiB"
  echo "# 目标包: ${TARGETS[*]}"
  echo "# 工具链装好后，目标包新增包数: ${N_WITH}"
  echo "# 工具链装好后，目标包新增 Installed Size: ${S_WITH} MiB"
  echo "# 新增列表与工具链包交集数: ${N_OVERLAP}（正常应为 0；非 0 可能是版本升级）"
  echo "# 新增包列表:"
  cat "$OUT_WITH_PKGS"
  if (( N_OVERLAP > 0 )); then
    echo
    echo "# 交集包（检查是否版本升级）:"
    cat "$D_WITH/overlap.pkgs"
  fi
  echo
  echo "# 工具链已安装包列表:"
  cat "$D_WITH/installed_toolchain.pkgs"
} > "$OUT_WITH"

log "场景 B 完成：新增 ${N_WITH} 包，${S_WITH} MiB，交集 ${N_OVERLAP} -> ${OUT_WITH}"

# ============ 汇总 ============
log "================ 汇总 ================"
log "无工具链：${N_NONE} 包，${S_NONE} MiB"
log "有工具链（新增）：${N_WITH} 包，${S_WITH} MiB"
log "工具链本身：${N_TC} 包，${S_TC} MiB"
log "新增列表与工具链交集：${N_OVERLAP}（正常应为 0）"
log "输出：${OUT_NONE} / ${OUT_WITH}"