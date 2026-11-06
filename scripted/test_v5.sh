#!/usr/bin/env bash
# msys2_compare_toolchain.sh  v5
# 分开测 ffmpeg 与 OCR（tesseract-ocr + data），各自独立干净 root。
#
# 用法（CLANG64 shell）：
#   ./test_v5.sh                          # 默认 dry：干净 dry-run + assume-installed 模拟工具链
#   MODE=real_tc ./test_v5.sh             # 真实安装工具链到临时 root，目标包 dry-run
#   MODE=full ./test_v5.sh                # 工具链和目标包都真实安装（很慢，两次工具链）
#   TESS_LANG=all ./test_v5.sh            # 全部 tesseract 语言包
#   TESS_LANG=chi_sim+eng ./test_v5.sh    # 多个语言包，用 + 连接
#
# 输出（当前目录）：
#   ffmpeg_no_tc.txt / .pkgs
#   ffmpeg_with_tc.txt / .pkgs
#   ocr_no_tc.txt / .pkgs
#   ocr_with_tc.txt / .pkgs
#   summary.txt

set -euo pipefail
export LC_ALL=C   # 关键：pacman -Si/-Qi 输出英文

# ============ 配置 ============
PKG_PREFIX="mingw-w64-clang-x86_64"
TOOLCHAIN="${PKG_PREFIX}-toolchain"

MODE="${MODE:-dry}"
[[ "${FULL:-0}" == "1" ]] && MODE="full"
case "$MODE" in
  dry|real_tc|full) ;;
  *) echo "错误：MODE 只能是 dry / real_tc / full，当前 $MODE" >&2; exit 1 ;;
esac

TESS_LANG="${TESS_LANG:-eng}"
DATA_PKGS=()
if [[ "$TESS_LANG" == "all" ]]; then
  mapfile -t DATA_PKGS < <(pacman -Ssq "^${PKG_PREFIX}-tesseract-data-")
  ((${#DATA_PKGS[@]})) || { echo "错误：无法获取 tesseract-data-* 列表，请先 pacman -Sy" >&2; exit 1; }
else
  IFS='+' read -r -a _langs <<< "$TESS_LANG"
  for l in "${_langs[@]}"; do
    DATA_PKGS+=("${PKG_PREFIX}-tesseract-data-${l}")
  done
fi

TARGET_FFMPEG=("${PKG_PREFIX}-ffmpeg")
TARGET_OCR=("${PKG_PREFIX}-tesseract-ocr" "${DATA_PKGS[@]}")

WORKDIR="${WORKDIR:-$(mktemp -d)}"
KEEP="${KEEP:-0}"
NOBAR="${NOBAR:-0}"

SUMMARY="summary.txt"

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

# 写报告：无工具链场景
write_report_no_tc() {
  local f=$1 targets=$2 n=$3 s=$4 pkgs=$5
  {
    echo "# 场景: 干净 clang64，无工具链（dry-run 递归依赖）"
    echo "# 日期: $(date -Iseconds)"
    echo "# 目标包: ${targets}"
    echo "# 包数: ${n}"
    echo "# Installed Size: ${s} MiB"
    echo "# 包列表:"
    cat "$pkgs"
  } > "$f"
}

# 写报告：有工具链场景
write_report_with_tc() {
  local f=$1 targets=$2 n=$3 s=$4 pkgs=$5
  local n_tc=$6 s_tc=$7 tc_list=$8 n_overlap=$9 overlap_file=${10}
  {
    echo "# 场景: clang64，MODE=${MODE}"
    echo "# 日期: $(date -Iseconds)"
    echo "# 方法: ${METHOD}"
    echo "# 工具链: ${TOOLCHAIN}"
    echo "# 工具链包数: ${n_tc}"
    echo "# 工具链 Installed Size: ${s_tc} MiB"
    echo "# 目标包: ${targets}"
    echo "# 新增包数: ${n}"
    echo "# 新增 Installed Size: ${s} MiB"
    echo "# 新增列表与工具链交集数: ${n_overlap}（dry 可能非 0；real_tc/full 应为 0 或版本升级）"
    echo "# 新增包列表:"
    cat "$pkgs"
    if [[ -n "$tc_list" && -f "$tc_list" ]]; then
      echo
      echo "# 工具链包列表:"
      cat "$tc_list"
    fi
    if [[ -n "$overlap_file" && -s "$overlap_file" ]]; then
      echo
      echo "# 交集包列表:"
      cat "$overlap_file"
    fi
  } > "$f"
}

# 对一组 targets 测两种口径
measure_one() {
  local name=$1; shift
  local -a targets=("$@")
  local N_A S_A N_B S_B N_TC S_TC N_OVERLAP METHOD TC_LIST

  # ---------- 场景 A：无工具链 ----------
  log "[$name] 场景 A：干净 root"
  local D_A
  D_A="$(make_root)"
  PAC "$D_A" -Sy >/dev/null 2>"$D_A/sy.err" || { cat "$D_A/sy.err" >&2; die "[$name] A -Sy 失败"; }

  log "[$name] 场景 A：dry-run"
  if ! PAC "$D_A" -Sp --print-format '%n' "${targets[@]}" \
        > "${name}_no_tc.pkgs" 2>"$D_A/sp.err"; then
    cat "$D_A/sp.err" >&2; die "[$name] A dry-run 失败"
  fi
  [[ -s "${name}_no_tc.pkgs" ]] || die "[$name] A 包列表为空"
  mapfile -t P_A < "${name}_no_tc.pkgs"
  N_A=${#P_A[@]}
  S_A="$(sum_si "$D_A" "${P_A[@]}")"
  [[ "$S_A" != "0.00" ]] || die "[$name] A 求和为 0.00，检查 pacman -Si 输出"
  write_report_no_tc "${name}_no_tc.txt" "${targets[*]}" "$N_A" "$S_A" "${name}_no_tc.pkgs"
  log "[$name] 场景 A 完成：${N_A} 包，${S_A} MiB"

  # ---------- 场景 B：有工具链 ----------
  log "[$name] 场景 B：创建 root（MODE=$MODE）"
  local D_B
  D_B="$(make_root)"
  PAC "$D_B" -Sy >/dev/null 2>"$D_B/sy.err" || { cat "$D_B/sy.err" >&2; die "[$name] B -Sy 失败"; }

  if [[ "$MODE" == "dry" ]]; then
    log "[$name] 场景 B(dry)：工具链 dry-run"
    if ! PAC "$D_B" -Sp --print-format '%n' "$TOOLCHAIN" \
          > "$D_B/tc.pkgs" 2>"$D_B/tc.err"; then
      cat "$D_B/tc.err" >&2; die "[$name] 工具链 dry-run 失败"
    fi
    [[ -s "$D_B/tc.pkgs" ]] || die "[$name] 工具链包列表为空"
    mapfile -t P_TC < "$D_B/tc.pkgs"
    N_TC=${#P_TC[@]}
    S_TC="$(sum_si "$D_B" "${P_TC[@]}")"
    TC_LIST="$D_B/tc.pkgs"

    mapfile -t ASSUME < <(build_assume_args "$D_B" "${P_TC[@]}")
    ((${#ASSUME[@]})) || die "[$name] assume 参数为空"

    log "[$name] 场景 B(dry)：目标包 dry-run（assume 工具链）"
    if ! PAC "$D_B" -Sp "${ASSUME[@]}" --print-format '%n' "${targets[@]}" \
          > "${name}_with_tc.pkgs" 2>"$D_B/sp.err"; then
      cat "$D_B/sp.err" >&2; die "[$name] B dry-run 失败"
    fi
    if [[ -s "${name}_with_tc.pkgs" ]]; then
      mapfile -t P_B < "${name}_with_tc.pkgs"
      N_B=${#P_B[@]}
      S_B="$(sum_si "$D_B" "${P_B[@]}")"
    else
      N_B=0; S_B="0.00"; : > "${name}_with_tc.pkgs"
    fi
    METHOD="dry：干净 root + --assume-installed 模拟工具链"
  else
    log "[$name] 场景 B($MODE)：真实安装工具链（进度可见；NOBAR=1 隐藏）"
    local tc_log="$D_B/install_tc.log"
    if ! PAC "$D_B" "${INSTALL_OPTS[@]}" "$TOOLCHAIN" 2>&1 | tee "$tc_log"; then
      tail -80 "$tc_log" >&2; die "[$name] 工具链安装失败"
    fi
    PAC "$D_B" -Qq > "$D_B/installed_tc.pkgs"
    [[ -s "$D_B/installed_tc.pkgs" ]] || die "[$name] 工具链 -Qq 为空"
    mapfile -t P_TC < "$D_B/installed_tc.pkgs"
    N_TC=${#P_TC[@]}
    S_TC="$(sum_qi "$D_B" "${P_TC[@]}")"
    TC_LIST="$D_B/installed_tc.pkgs"

    if [[ "$MODE" == "full" ]]; then
      log "[$name] 场景 B(full)：真实安装目标包"
      local tg_log="$D_B/install_tg.log"
      if ! PAC "$D_B" "${INSTALL_OPTS[@]}" --needed "${targets[@]}" 2>&1 | tee "$tg_log"; then
        tail -80 "$tg_log" >&2; die "[$name] 目标包安装失败"
      fi
      PAC "$D_B" -Qq > "$D_B/installed_full.pkgs"
      comm -13 <(sort "$D_B/installed_tc.pkgs") <(sort "$D_B/installed_full.pkgs") \
        > "${name}_with_tc.pkgs"
      mapfile -t P_B < "${name}_with_tc.pkgs"
      N_B=${#P_B[@]}
      S_B="$(sum_qi "$D_B" "${P_B[@]}")"
      METHOD="full：真实安装工具链 + 目标包，pacman -Q 差集"
    else
      log "[$name] 场景 B(real_tc)：目标包 dry-run（工具链已落盘）"
      if ! PAC "$D_B" -Sp --print-format '%n' "${targets[@]}" \
            > "${name}_with_tc.pkgs" 2>"$D_B/sp.err"; then
        cat "$D_B/sp.err" >&2; die "[$name] B dry-run 失败"
      fi
      if [[ -s "${name}_with_tc.pkgs" ]]; then
        mapfile -t P_B < "${name}_with_tc.pkgs"
        N_B=${#P_B[@]}
        S_B="$(sum_si "$D_B" "${P_B[@]}")"
      else
        N_B=0; S_B="0.00"; : > "${name}_with_tc.pkgs"
      fi
      METHOD="real_tc：真实安装工具链 + dry-run 目标包"
    fi
  fi

  comm -12 <(sort "$TC_LIST") <(sort "${name}_with_tc.pkgs") \
    > "$D_B/overlap.pkgs" || true
  N_OVERLAP=$(wc -l < "$D_B/overlap.pkgs")

  write_report_with_tc "${name}_with_tc.txt" "${targets[*]}" \
    "$N_B" "$S_B" "${name}_with_tc.pkgs" \
    "$N_TC" "$S_TC" "$TC_LIST" "$N_OVERLAP" "$D_B/overlap.pkgs"

  log "[$name] 场景 B 完成：新增 ${N_B} 包，${S_B} MiB，交集 ${N_OVERLAP}"

  printf '%s|%d|%s|%d|%s|%d|%s|%d\n' \
    "$name" "$N_A" "$S_A" "$N_B" "$S_B" "$N_TC" "$S_TC" "$N_OVERLAP" \
    >> "$SUMMARY"
}

# ============ 环境检查 ============
log "MODE=$MODE，MSYSTEM=${MSYSTEM:-未设置}，TESS_LANG=$TESS_LANG"
[[ "${MSYSTEM:-}" == "CLANG64" ]] || log "警告：当前不是 CLANG64 shell；脚本显式使用 clang64 包名。"

mkdir -p "$WORKDIR"
avail_mib=$(df -Pm "$WORKDIR" | awk 'NR==2{print $4}')
log "WORKDIR=$WORKDIR，可用空间 ${avail_mib} MiB"
if [[ "$MODE" == "full" ]] && (( avail_mib < 6000 )); then
  log "警告：MODE=full 需两次真实安装工具链+目标包，空间可能不足；建议 WORKDIR=/d/msys2-test"
fi

sample=$(pacman -Si "${PKG_PREFIX}-ffmpeg" 2>/dev/null | grep -m1 '^Installed Size' || true)
[[ -n "$sample" ]] || die "pacman -Si 未输出英文 Installed Size，LC_ALL=C 未生效？"

: > "$SUMMARY"

# ============ 分别测 ffmpeg 和 OCR ============
log "===== 测试 ffmpeg（含 whisper.cpp 依赖）====="
measure_one "ffmpeg" "${TARGET_FFMPEG[@]}"

log "===== 测试 OCR（tesseract-ocr + data）====="
measure_one "ocr" "${TARGET_OCR[@]}"

# ============ 汇总 ============
log "================ 汇总 ================"
awk -F'|' '
BEGIN {
  printf "%-8s | %7s | %10s | %7s | %10s | %8s | %10s | %7s\n", \
    "tool", "no_tc#", "no_tc(MiB)", "tc#", "tc(MiB)", "tc_dep#", "tc_dep(MiB)", "overlap"
  printf "%s\n", "---------+---------+------------+---------+------------+----------+------------+--------"
}
{
  printf "%-8s | %7d | %10s | %7d | %10s | %8d | %10s | %7d\n", $1, $2, $3, $4, $5, $6, $7, $8
}
' "$SUMMARY" | tee -a "$SUMMARY"

log "输出文件："
log "  ffmpeg_no_tc.txt / .pkgs"
log "  ffmpeg_with_tc.txt / .pkgs"
log "  ocr_no_tc.txt / .pkgs"
log "  ocr_with_tc.txt / .pkgs"
log "  summary.txt"