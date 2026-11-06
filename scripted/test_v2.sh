#!/usr/bin/env bash
# msys2_compare_toolchain.sh  v2
# 修复: 0.00 MiB；所有 pacman 操作用同一临时 root；错误可见；空列表报错。

set -euo pipefail

PKG_PREFIX="mingw-w64-clang-x86_64"
TOOLCHAIN="${PKG_PREFIX}-toolchain"

TARGETS=(
  "${PKG_PREFIX}-ffmpeg"
  "${PKG_PREFIX}-tesseract-ocr"
)

TESS_LANG="${TESS_LANG:-eng}"
if [[ "$TESS_LANG" == "all" ]]; then
  mapfile -t DATA_PKGS < <(pacman -Ssq "^${PKG_PREFIX}-tesseract-data-")
else
  DATA_PKGS=("${PKG_PREFIX}-tesseract-data-${TESS_LANG}")
fi
TARGETS+=("${DATA_PKGS[@]}")

OUT_NONE="msys2_clang64_no_toolchain.txt"
OUT_WITH="msys2_clang64_with_toolchain.txt"
OUT_NONE_PKGS="msys2_clang64_no_toolchain.pkgs"
OUT_WITH_PKGS="msys2_clang64_with_toolchain.pkgs"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die() { log "错误: $*"; exit 1; }

PAC() {
  local d="$1"; shift
  pacman \
    --root "$d/root" \
    --dbpath "$d/db" \
    --cachedir "$d/cache" \
    --gpgdir /etc/pacman.d/gnupg \
    --config /etc/pacman.conf \
    --noconfirm "$@"
}

make_root() {
  local d; d="$(mktemp -d)"
  mkdir -p "$d/root" "$d/db" "$d/cache"
  printf '%s\n' "$d"
}

# 用临时 root 的 pacman 查 -Si，输出 "name\tversion\tinstalled_bytes"
query_pkgs() {
  local root="$1"; shift
  local -a pkgs=("$@")
  ((${#pkgs[@]})) || return 0
  PAC "$root" -Si "${pkgs[@]}" | awk '
    /^Name[[:space:]]*:/ { sub(/^[^:]*:[[:space:]]*/, ""); name=$0 }
    /^Version[[:space:]]*:/ { sub(/^[^:]*:[[:space:]]*/, ""); ver=$0 }
    /^Installed Size[[:space:]]*:/ {
      sub(/^[^:]*:[[:space:]]*/, "")
      v=$1+0; u=$2; b=v
      if (u=="KiB") b=v*1024
      else if (u=="MiB") b=v*1024*1024
      else if (u=="GiB") b=v*1024*1024*1024
      else if (u=="B") b=v
      printf "%s\t%s\t%.0f\n", name, ver, b
    }
  '
}

# 从 query_pkgs 输出求和，单位 MiB
sum_from_query() {
  awk -F'\t' '{sum += $3} END {printf "%.2f", sum/1024/1024}'
}

read_pkgs() { mapfile -t "$1" < "$2"; }

# ---------- 场景 A：无工具链 ----------
log "场景 A：创建临时干净 root"
D_NONE="$(make_root)"
trap 'rm -rf "$D_NONE" "${D_WITH:-}"' EXIT

log "场景 A：-Sy"
if ! PAC "$D_NONE" -Sy 2>"$D_NONE/sy.err"; then
  log "临时 root -Sy 失败，stderr 如下："
  cat "$D_NONE/sy.err" >&2
  die "请先检查 MSYS2 keyring：pacman-key --init && pacman-key --populate msys2"
fi

log "场景 A：dry-run 目标包"
if ! PAC "$D_NONE" -Sp --print-format '%n' "${TARGETS[@]}" \
      > "$OUT_NONE_PKGS" 2>"$D_NONE/sp.err"; then
  log "临时 root -Sp 失败，stderr 如下："
  cat "$D_NONE/sp.err" >&2
  die "dry-run 失败，目标包可能不在当前仓库：${TARGETS[*]}"
fi

[[ -s "$OUT_NONE_PKGS" ]] || die "场景 A 包列表为空，dry-run 没有输出任何包"
mapfile -t PKGS_NONE < "$OUT_NONE_PKGS"
log "场景 A：共 ${#PKGS_NONE[@]} 个包，查询 -Si"
QUERY_NONE="$(query_pkgs "$D_NONE" "${PKGS_NONE[@]}")"
[[ -n "$QUERY_NONE" ]] || die "场景 A -Si 查询为空，临时 root 数据库可能不完整"
S_NONE="$(printf '%s\n' "$QUERY_NONE" | sum_from_query)"
N_NONE="${#PKGS_NONE[@]}"

{
  echo "# 场景: 干净 clang64，无工具链"
  echo "# 日期: $(date -Iseconds)"
  echo "# 目标包: ${TARGETS[*]}"
  echo "# 包数: ${N_NONE}"
  echo "# 总 Installed Size: ${S_NONE} MiB"
  echo "# 包列表:"
  cat "$OUT_NONE_PKGS"
} > "$OUT_NONE"
log "场景 A 完成：${N_NONE} 包，${S_NONE} MiB -> ${OUT_NONE}"

# ---------- 场景 B：已有工具链 ----------
log "场景 B：创建临时干净 root"
D_WITH="$(make_root)"
if ! PAC "$D_WITH" -Sy 2>"$D_WITH/sy.err"; then
  cat "$D_WITH/sy.err" >&2
  die "场景 B 临时 root -Sy 失败"
fi

log "场景 B：获取工具链递归依赖（不安装）"
if ! PAC "$D_WITH" -Sp --print-format '%n' "$TOOLCHAIN" \
      > "$D_WITH/toolchain.pkgs" 2>"$D_WITH/tc.err"; then
  cat "$D_WITH/tc.err" >&2
  die "工具链 dry-run 失败：$TOOLCHAIN"
fi
[[ -s "$D_WITH/toolchain.pkgs" ]] || die "工具链包列表为空"
mapfile -t PKGS_TC < "$D_WITH/toolchain.pkgs"
QUERY_TC="$(query_pkgs "$D_WITH" "${PKGS_TC[@]}")"
[[ -n "$QUERY_TC" ]] || die "工具链 -Si 查询为空"
S_TC="$(printf '%s\n' "$QUERY_TC" | sum_from_query)"
N_TC="${#PKGS_TC[@]}"
log "工具链递归依赖：${N_TC} 包，${S_TC} MiB"

log "场景 B：构造 --assume-installed"
ASSUME_ARGS=()
while IFS=$'\t' read -r n v _; do
  [[ -n "$n" && -n "$v" ]] || continue
  ASSUME_ARGS+=(--assume-installed "${n}=${v}")
done <<< "$QUERY_TC"

log "场景 B：dry-run 目标包（假设工具链已装）"
if ! PAC "$D_WITH" -Sp "${ASSUME_ARGS[@]}" --print-format '%n' "${TARGETS[@]}" \
      > "$OUT_WITH_PKGS" 2>"$D_WITH/sp.err"; then
  cat "$D_WITH/sp.err" >&2
  die "场景 B dry-run 失败"
fi

# 注意：如果工具链已覆盖全部目标依赖，这里可能为空，这是合法结果
N_WITH=0; S_WITH="0.00"
if [[ -s "$OUT_WITH_PKGS" ]]; then
  mapfile -t PKGS_WITH < "$OUT_WITH_PKGS"
  QUERY_WITH="$(query_pkgs "$D_WITH" "${PKGS_WITH[@]}")"
  [[ -n "$QUERY_WITH" ]] || die "场景 B -Si 查询为空"
  S_WITH="$(printf '%s\n' "$QUERY_WITH" | sum_from_query)"
  N_WITH="${#PKGS_WITH[@]}"
else
  log "场景 B：目标包没有新增依赖（工具链已全部覆盖），这是合法结果"
  : > "$OUT_WITH_PKGS"
fi

{
  echo "# 场景: 干净 clang64，假设工具链 ${TOOLCHAIN} 已安装"
  echo "# 日期: $(date -Iseconds)"
  echo "# 工具链递归依赖包数: ${N_TC}"
  echo "# 工具链递归依赖 Installed Size: ${S_TC} MiB"
  echo "# 目标包: ${TARGETS[*]}"
  echo "# 工具链装好后，目标包新增包数: ${N_WITH}"
  echo "# 工具链装好后，目标包新增 Installed Size: ${S_WITH} MiB"
  echo "# 新增包列表:"
  cat "$OUT_WITH_PKGS"
  echo
  echo "# 工具链递归依赖包列表:"
  cat "$D_WITH/toolchain.pkgs"
} > "$OUT_WITH"
log "场景 B 完成：新增 ${N_WITH} 包，${S_WITH} MiB -> ${OUT_WITH}"

log "================ 汇总 ================"
log "无工具链：${N_NONE} 包，${S_NONE} MiB"
log "有工具链（新增）：${N_WITH} 包，${S_WITH} MiB"
log "工具链本身递归依赖：${N_TC} 包，${S_TC} MiB"
log "输出：${OUT_NONE} / ${OUT_WITH}"