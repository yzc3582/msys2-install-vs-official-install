#!/usr/bin/env bash
# msys2_compare_toolchain.sh  v4
# 默认 dry-run；LC_ALL=C 修复 0.00 MiB；可选真实落盘工具链。
#
# 用法（CLANG64 shell）：
#   ./test_v4.sh                         # 默认 MODE=dry：干净 dry-run + assume-installed 模拟工具链
#   MODE=real_tc ./test_v4.sh            # 真实安装工具链到临时 root，目标包 dry-run
#   MODE=full ./test_v4.sh               # 工具链和目标包都真实安装，pacman -Q 差集
#   FULL=1 ./test_v4.sh                  # 等价 MODE=full
#   TESS_LANG=all MODE=full ./test_v4.sh # 全语言包
#   NOBAR=1 MODE=real_tc ./test_v4.sh    # 隐藏进度条（输出重定向到日志时用）
#
# 输出：
#   msys2_clang64_no_toolchain.txt / .pkgs
#   msys2_clang64_with_toolchain.txt / .pkgs

set -euo pipefail
export LC_ALL=C   # 关键：pacman -Si/-Qi 输出英文，awk 才能匹配 Installed Size

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

# 模式：dry（默认）/ real_tc / full
MODE="${MODE:-dry}"
[[ "${FULL:-0}" == "1" ]] && MODE="full"
case "$MODE" in
  dry|real_tc|full) ;;
  *) echo "错误：MODE 只能是 dry / real_tc / full，当前 $MODE" >&2; exit 1 ;;
esac

WORKDIR="${WORKDIR:-$(mktemp -d)}"
KEEP="${KEEP:-0}"
NOBAR="${NOBAR:-0}"

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

# 用临时 root 的 -Si 对仓库包列表求 Installed Size（MiB）
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

# 用临时 root 的 -Qi 对已安装包求实际 Installed Size（MiB）
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

# 从 -Si 输出构造 --assume-installed pkg=ver
build_assume_args() {
  local d="$1"; shift
  local -a pkgs=("$@")
  ((${#pkgs[@]})) || return 0
  PAC "$d" -Si "${pkgs[@]}" 2>/dev/null | awk '
    /^Name[[:space:]]*:/ { sub(/^[^:]*:[[:space:]]*/, ""); n=$0 }
    /^Version[[:space:]]*:/ {
      sub(/^[^:]*:[[:space:]]*/, ""); v=$0
      if (n!="") { printf "--assume-installed\n%s=%s\n", n, v; n="" }
    }
  '
}

INSTALL_OPTS=(-S --noconfirm)
[[ "$NOBAR" == "1" ]] && INSTALL_OPTS+=(--noprogressbar)

# ============ 环境检查 ============
log "MODE=$MODE，MSYSTEM=${MSYSTEM:-未设置}，目标前缀 ${PKG_PREFIX}"
[[ "${MSYSTEM:-}" == "CLANG64" ]] || log "警告：当前不是 CLANG64 shell；脚本显式使用 clang64 包名。"

mkdir -p "$WORKDIR"
avail_mib=$(df -Pm "$WORKDIR" | awk 'NR==2{print $4}')
log "WORKDIR=$WORKDIR，可用空间 ${avail_mib} MiB"
if [[ "$MODE" != "dry" ]] && (( avail_mib < 3000 )); then
  log "警告：MODE=$MODE 需真实落盘，空间可能不足；建议 WORKDIR=/d/msys2-test"
fi

# 验证 locale 修复
if ! PAC /dev/null -h >/dev/null 2>&1; then :; fi
sample=$(pacman -Si "$PKG_PREFIX-ffmpeg" 2>/dev/null | grep -m1 '^Installed Size' || true)
[[ -n "$sample" ]] || die "pacman -Si 未输出英文 Installed Size，LC_ALL=C 未生效？"

# ============ 场景 A：干净环境，无工具链 ============
log "场景 A：创建临时干净 root"
D_NONE="$(make_root)"

log "场景 A：-Sy"
if ! PAC "$D_NONE" -Sy 2>"$D_NONE/sy.err"; then
  cat "$D_NONE/sy.err" >&2
  die "临时 root -Sy 失败。若为 GPG 错误，先执行 pacman-key --init && pacman-key --populate msys2"
fi

log "场景 A：dry-run 目标包"
if ! PAC "$D_NONE" -Sp --print-format '%n' "${TARGETS[@]}" \
      > "$OUT_NONE_PKGS" 2>"$D_NONE/sp.err"; then
  cat "$D_NONE/sp.err" >&2
  die "场景 A dry-run 失败，目标包可能不存在：${TARGETS[*]}"
fi
[[ -s "$OUT_NONE_PKGS" ]] || die "场景 A 包列表为空"
mapfile -t PKGS_NONE < "$OUT_NONE_PKGS"
N_NONE="${#PKGS_NONE[@]}"
S_NONE="$(sum_si "$D_NONE" "${PKGS_NONE[@]}")"
[[ "$S_NONE" != "0.00" ]] || die "场景 A 求和仍为 0.00，检查 pacman -Si 输出格式"

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

# ============ 场景 B ============
log "场景 B：创建临时干净 root（MODE=$MODE）"
D_WITH="$(make_root)"

log "场景 B：-Sy"
if ! PAC "$D_WITH" -Sy 2>"$D_WITH/sy.err"; then
  cat "$D_WITH/sy.err" >&2
  die "场景 B 临时 root -Sy 失败"
fi

if [[ "$MODE" == "dry" ]]; then
  # ---------- dry：--assume-installed 模拟工具链 ----------
  log "场景 B(dry)：获取工具链递归依赖（不安装）"
  if ! PAC "$D_WITH" -Sp --print-format '%n' "$TOOLCHAIN" \
        > "$D_WITH/toolchain.pkgs" 2>"$D_WITH/tc.err"; then
    cat "$D_WITH/tc.err" >&2
    die "工具链 dry-run 失败：$TOOLCHAIN"
  fi
  [[ -s "$D_WITH/toolchain.pkgs" ]] || die "工具链包列表为空"
  mapfile -t PKGS_TC < "$D_WITH/toolchain.pkgs"
  N_TC="${#PKGS_TC[@]}"
  S_TC="$(sum_si "$D_WITH" "${PKGS_TC[@]}")"
  log "工具链递归依赖：${N_TC} 包，仓库 Installed Size ${S_TC} MiB"

  log "场景 B(dry)：构造 --assume-installed"
  mapfile -t ASSUME_ARGS < <(build_assume_args "$D_WITH" "${PKGS_TC[@]}")
  ((${#ASSUME_ARGS[@]})) || die "--assume-installed 参数为空"

  log "场景 B(dry)：dry-run 目标包（假设工具链已装）"
  if ! PAC "$D_WITH" -Sp "${ASSUME_ARGS[@]}" --print-format '%n' "${TARGETS[@]}" \
        > "$OUT_WITH_PKGS" 2>"$D_WITH/sp.err"; then
    cat "$D_WITH/sp.err" >&2
    die "场景 B dry-run 失败"
  fi

  if [[ -s "$OUT_WITH_PKGS" ]]; then
    mapfile -t PKGS_NEW < "$OUT_WITH_PKGS"
    N_WITH="${#PKGS_NEW[@]}"
    S_WITH="$(sum_si "$D_WITH" "${PKGS_NEW[@]}")"
  else
    log "场景 B：目标包无新增依赖（工具链全覆盖），合法结果"
    N_WITH=0; S_WITH="0.00"; : > "$OUT_WITH_PKGS"
  fi
  METHOD="dry：干净 root + --assume-installed 模拟工具链"

  # 重合检查
  comm -12 <(sort "$D_WITH/toolchain.pkgs") <(sort "$OUT_WITH_PKGS") \
    > "$D_WITH/overlap.pkgs" || true
  N_OVERLAP=$(wc -l < "$D_WITH/overlap.pkgs")

else
  # ---------- real_tc / full：真实安装工具链 ----------
  log "场景 B($MODE)：真实安装工具链 ${TOOLCHAIN}（会显示进度；NOBAR=1 可隐藏）"
  tc_log="$D_WITH/install_toolchain.log"
  if ! PAC "$D_WITH" "${INSTALL_OPTS[@]}" "$TOOLCHAIN" 2>&1 | tee "$tc_log"; then
    log "工具链安装失败，日志末尾："
    tail -80 "$tc_log" >&2
    die "可尝试 NOBAR=1；或检查 WORKDIR 空间/网络/GPG"
  fi
  [[ "${PIPESTATUS[0]}" == "0" ]] || { tail -80 "$tc_log" >&2; die "工具链安装失败"; }

  PAC "$D_WITH" -Qq > "$D_WITH/installed_toolchain.pkgs"
  [[ -s "$D_WITH/installed_toolchain.pkgs" ]] || die "工具链安装后 -Qq 为空"
  mapfile -t PKGS_TC < "$D_WITH/installed_toolchain.pkgs"
  N_TC="${#PKGS_TC[@]}"
  S_TC="$(sum_qi "$D_WITH" "${PKGS_TC[@]}")"
  log "工具链已真实落盘：${N_TC} 包，实际 Installed Size ${S_TC} MiB"

  if [[ "$MODE" == "full" ]]; then
    log "场景 B(full)：真实安装目标包"
    tg_log="$D_WITH/install_targets.log"
    if ! PAC "$D_WITH" "${INSTALL_OPTS[@]}" --needed "${TARGETS[@]}" 2>&1 | tee "$tg_log"; then
      log "目标包安装失败，日志末尾："; tail -80 "$tg_log" >&2; die "目标包安装失败"
    fi
    [[ "${PIPESTATUS[0]}" == "0" ]] || { tail -80 "$tg_log" >&2; die "目标包安装失败"; }

    PAC "$D_WITH" -Qq > "$D_WITH/installed_full.pkgs"
    comm -13 \
      <(sort "$D_WITH/installed_toolchain.pkgs") \
      <(sort "$D_WITH/installed_full.pkgs") \
      > "$OUT_WITH_PKGS"
    mapfile -t PKGS_NEW < "$OUT_WITH_PKGS"
    N_WITH="${#PKGS_NEW[@]}"
    S_WITH="$(sum_qi "$D_WITH" "${PKGS_NEW[@]}")"
    METHOD="full：真实安装工具链 + 真实安装目标包，pacman -Q 差集"
  else
    log "场景 B(real_tc)：工具链已落盘，dry-run 目标包"
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
      log "场景 B：目标包无新增依赖，合法结果"
      N_WITH=0; S_WITH="0.00"; : > "$OUT_WITH_PKGS"
    fi
    METHOD="real_tc：真实安装工具链 + dry-run 目标包"
  fi

  comm -12 <(sort "$D_WITH/installed_toolchain.pkgs") <(sort "$OUT_WITH_PKGS") \
    > "$D_WITH/overlap.pkgs" || true
  N_OVERLAP=$(wc -l < "$D_WITH/overlap.pkgs")
fi

{
  echo "# 场景: clang64，MODE=${MODE}"
  echo "# 日期: $(date -Iseconds)"
  echo "# 方法: ${METHOD}"
  echo "# 工具链: ${TOOLCHAIN}"
  echo "# 工具链包数: ${N_TC}"
  echo "# 工具链 Installed Size: ${S_TC} MiB"
  echo "# 目标包: ${TARGETS[*]}"
  echo "# 新增包数: ${N_WITH}"
  echo "# 新增 Installed Size: ${S_WITH} MiB"
  echo "# 新增列表与工具链包交集数: ${N_OVERLAP}（dry 模式下可能非 0，real_tc/full 应为 0 或版本升级）"
  echo "# 新增包列表:"
  cat "$OUT_WITH_PKGS"
  if (( N_OVERLAP > 0 )); then
    echo
    echo "# 交集包:"
    cat "$D_WITH/overlap.pkgs"
  fi
  echo
  echo "# 工具链包列表:"
  if [[ -f "$D_WITH/installed_toolchain.pkgs" ]]; then
    cat "$D_WITH/installed_toolchain.pkgs"
  else
    cat "$D_WITH/toolchain.pkgs"
  fi
} > "$OUT_WITH"

log "场景 B 完成：新增 ${N_WITH} 包，${S_WITH} MiB，交集 ${N_OVERLAP} -> ${OUT_WITH}"

# ============ 汇总 ============
log "================ 汇总 ================"
log "MODE=${MODE}"
log "无工具链：${N_NONE} 包，${S_NONE} MiB"
log "有工具链（新增）：${N_WITH} 包，${S_WITH} MiB"
log "工具链本身：${N_TC} 包，${S_TC} MiB"
log "新增与工具链交集：${N_OVERLAP}"
log "输出：${OUT_NONE} / ${OUT_WITH}"