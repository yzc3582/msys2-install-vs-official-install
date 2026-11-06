#!/usr/bin/env bash
# msys2_compare_toolchain.sh
# 用途：在 MSYS2 中 dry-run 对比“干净环境”与“已有 clang64 工具链环境”下
#       安装 ffmpeg + tesseract-ocr + tesseract-data-* 的包列表和 Installed Size。
# 特点：使用临时 pacman root，不实际安装工具链，不影响真实系统。
# 运行：在 MSYS2 CLANG64 shell 中执行  bash msys2_compare_toolchain.sh
# 可选：TESS_LANG=all bash msys2_compare_toolchain.sh   # 测全部 tesseract 语言包

set -euo pipefail

# ============ 配置 ============
PKG_PREFIX="mingw-w64-clang-x86_64"
TOOLCHAIN="${PKG_PREFIX}-toolchain"

# ffmpeg 已依赖 whisper.cpp，故不重复加入 whisper
TARGETS=(
  "${PKG_PREFIX}-ffmpeg"
  "${PKG_PREFIX}-tesseract-ocr"
)

# 语言包：默认 eng；TESS_LANG=all 则列出全部 tesseract-data-*
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

# ============ 工具函数 ============
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

# 在临时 root 中调用 pacman
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
  local d
  d="$(mktemp -d)"
  mkdir -p "$d/root" "$d/db" "$d/cache"
  printf '%s\n' "$d"
}

# 对包列表文件求和 Installed Size（MiB）
sum_installed_size() {
  local pkgs_file="$1"
  if [[ ! -s "$pkgs_file" ]]; then
    echo "0.00"
    return
  fi
  xargs pacman -Si < "$pkgs_file" 2>/dev/null | awk '
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

# 从包列表构造 --assume-installed pkg=ver 参数数组
# 用法：mapfile -t ASSUME < <(build_assume_args "$pkgs_file")
build_assume_args() {
  local pkgs_file="$1"
  xargs pacman -Si < "$pkgs_file" 2>/dev/null | awk '
    /^Name[[:space:]]*:/ {
      sub(/^[^:]*:[[:space:]]*/, ""); name=$0
    }
    /^Version[[:space:]]*:/ {
      sub(/^[^:]*:[[:space:]]*/, ""); ver=$0
      if (name != "") { print name"="ver; name="" }
    }
  '
}

# ============ 主流程 ============
log "检查 MSYSTEM=${MSYSTEM:-未设置}，目标前缀 ${PKG_PREFIX}"
if [[ "${MSYSTEM:-}" != "CLANG64" ]]; then
  log "警告：当前不是 CLANG64 shell。脚本会显式使用 clang64 包名，通常仍可运行；"
  log "      若 pacman 仓库配置受限，请在 CLANG64 shell 中重新运行。"
fi

# ---------- 场景 A：无工具链（干净环境） ----------
log "场景 A：创建临时干净 root，同步数据库"
D_NONE="$(make_root)"
trap 'rm -rf "$D_NONE" "${D_WITH:-}"' EXIT

PAC "$D_NONE" -Sy >/dev/null 2>&1 || {
  log "错误：临时 root 同步数据库失败。可能是 GPG 或镜像配置问题。"
  exit 1
}

log "场景 A：dry-run 目标包"
PAC "$D_NONE" -Sp --print-format '%n' "${TARGETS[@]}" 2>/dev/null \
  | sort -u > "$OUT_NONE_PKGS"

N_NONE=$(wc -l < "$OUT_NONE_PKGS")
S_NONE=$(sum_installed_size "$OUT_NONE_PKGS")

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
log "场景 B：创建临时干净 root，同步数据库"
D_WITH="$(make_root)"
PAC "$D_WITH" -Sy >/dev/null 2>&1 || {
  log "错误：临时 root 同步数据库失败。"
  exit 1
}

log "场景 B：获取工具链完整递归依赖包列表（不安装）"
PAC "$D_WITH" -Sp --print-format '%n' "$TOOLCHAIN" 2>/dev/null \
  | sort -u > "${D_WITH}/toolchain.pkgs"

N_TOOLCHAIN=$(wc -l < "${D_WITH}/toolchain.pkgs")
S_TOOLCHAIN=$(sum_installed_size "${D_WITH}/toolchain.pkgs")
log "工具链递归依赖：${N_TOOLCHAIN} 包，${S_TOOLCHAIN} MiB"

log "场景 B：构造 --assume-installed 参数"
mapfile -t ASSUME_ARGS < <(
  while IFS= read -r pkgver; do
    printf -- '--assume-installed\n%s\n' "$pkgver"
  done < <(build_assume_args "${D_WITH}/toolchain.pkgs")
)

log "场景 B：dry-run 目标包（假设工具链已安装）"
PAC "$D_WITH" -Sp "${ASSUME_ARGS[@]}" --print-format '%n' "${TARGETS[@]}" 2>/dev/null \
  | sort -u > "$OUT_WITH_PKGS"

N_WITH=$(wc -l < "$OUT_WITH_PKGS")
S_WITH=$(sum_installed_size "$OUT_WITH_PKGS")

{
  echo "# 场景: 干净 clang64，假设工具链 ${TOOLCHAIN} 已安装"
  echo "# 日期: $(date -Iseconds)"
  echo "# 工具链递归依赖包数: ${N_TOOLCHAIN}"
  echo "# 工具链递归依赖 Installed Size: ${S_TOOLCHAIN} MiB"
  echo "# 目标包: ${TARGETS[*]}"
  echo "# 工具链装好后，目标包新增包数: ${N_WITH}"
  echo "# 工具链装好后，目标包新增 Installed Size: ${S_WITH} MiB"
  echo "# 新增包列表:"
  cat "$OUT_WITH_PKGS"
  echo
  echo "# 工具链递归依赖包列表:"
  cat "${D_WITH}/toolchain.pkgs"
} > "$OUT_WITH"

log "场景 B 完成：新增 ${N_WITH} 包，${S_WITH} MiB -> ${OUT_WITH}"

# ---------- 汇总 ----------
log "================ 汇总 ================"
log "无工具链：${N_NONE} 包，${S_NONE} MiB"
log "有工具链（新增）：${N_WITH} 包，${S_WITH} MiB"
log "工具链本身递归依赖：${N_TOOLCHAIN} 包，${S_TOOLCHAIN} MiB"
log "输出文件：${OUT_NONE} / ${OUT_WITH}"