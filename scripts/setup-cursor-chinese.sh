#!/usr/bin/env bash
set -euo pipefail

EXTENSION_ID="MS-CEINTL.vscode-language-pack-zh-hans"
LOCALE="zh-cn"

detect_cursor_user_dir() {
  case "$(uname -s)" in
    Darwin)
      echo "${HOME}/Library/Application Support/Cursor/User"
      ;;
    Linux)
      if [[ -d "${HOME}/.config/Cursor/User" ]]; then
        echo "${HOME}/.config/Cursor/User"
      else
        echo "${HOME}/.cursor-server/data/User"
      fi
      ;;
    MINGW*|MSYS*|CYGWIN*)
      if [[ -n "${APPDATA:-}" ]]; then
        echo "${APPDATA}/Cursor/User"
      else
        echo "${HOME}/AppData/Roaming/Cursor/User"
      fi
      ;;
    *)
      echo ""
      ;;
  esac
}

find_cursor_cli() {
  if command -v cursor >/dev/null 2>&1; then
    command -v cursor
    return 0
  fi

  local candidates=(
    "/Applications/Cursor.app/Contents/Resources/app/bin/cursor"
    "${HOME}/.cursor-server/bin"/*/bin/remote-cli/cursor
  )

  local candidate
  for candidate in "${candidates[@]}"; do
    for path in $candidate; do
      if [[ -x "$path" ]]; then
        echo "$path"
        return 0
      fi
    done
  done

  return 1
}

write_locale_files() {
  local user_dir="$1"
  mkdir -p "$user_dir"

  printf '%s\n' "{\"locale\":\"${LOCALE}\"}" > "${user_dir}/locale.json"

  if [[ -f "${user_dir}/argv.json" ]]; then
    python3 - "$user_dir/argv.json" "$LOCALE" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
locale = sys.argv[2]
data = {}
if path.exists():
    data = json.loads(path.read_text())
data["locale"] = locale
path.write_text(json.dumps(data, indent=2) + "\n")
PY
  else
    printf '%s\n' "{
  \"locale\": \"${LOCALE}\"
}" > "${user_dir}/argv.json"
  fi
}

main() {
  local user_dir
  user_dir="$(detect_cursor_user_dir)"

  if [[ -z "$user_dir" ]]; then
    echo "无法识别当前系统的 Cursor 配置目录。" >&2
    exit 1
  fi

  echo "Cursor 用户配置目录: ${user_dir}"
  write_locale_files "$user_dir"
  echo "已写入 locale.json 和 argv.json"

  if cursor_cli="$(find_cursor_cli 2>/dev/null || true)"; then
    echo "正在安装中文语言包: ${EXTENSION_ID}"
    if "$cursor_cli" --install-extension "$EXTENSION_ID" --force; then
      echo "中文语言包安装完成"
    else
      echo "自动安装失败，请手动在扩展市场搜索并安装 Chinese (Simplified) Language Pack" >&2
    fi
  else
    echo "未找到 cursor 命令行工具，请手动安装扩展: ${EXTENSION_ID}" >&2
  fi

  echo
  echo "设置完成。请完全退出并重新打开 Cursor，界面将切换为简体中文。"
}

main "$@"
