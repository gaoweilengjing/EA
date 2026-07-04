#!/usr/bin/env bash
set -euo pipefail

EXTENSION_ID="MS-CEINTL.vscode-language-pack-zh-hans"
LOCALE="zh-cn"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

detect_cursor_user_dir() {
  case "$(uname -s)" in
    Darwin)
      echo "${HOME}/Library/Application Support/Cursor/User"
      ;;
    Linux)
      if [[ -d "${HOME}/.config/Cursor/User" ]]; then
        echo "${HOME}/.config/Cursor/User"
      elif [[ -d "${HOME}/.cursor-server/data/User" ]]; then
        echo "${HOME}/.cursor-server/data/User"
      else
        echo ""
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

is_server_only_env() {
  [[ -d "${HOME}/.cursor-server/data/User" && ! -d "${HOME}/.config/Cursor/User" ]]
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

print_client_steps() {
  cat <<'EOF'

========================================
重要：界面语言需要在【本机 Cursor】设置
========================================

你当前连接的是云端环境。菜单、侧边栏、设置页等界面
由你自己电脑上的 Cursor 客户端渲染，云端 Agent 无法直接修改。

请在你本机 Cursor 里操作（约 30 秒）：

1) 按 Ctrl+Shift+X（Mac: Cmd+Shift+X）
   搜索 Chinese，安装：
   Chinese (Simplified) Language Pack for Visual Studio Code
   （Microsoft 官方）

2) 按 Ctrl+Shift+P（Mac: Cmd+Shift+P）
   输入：Configure Display Language
   选择：中文(简体) / zh-cn

3) 点击 Restart，或完全退出 Cursor 后重新打开

如果还是英文，打开设置 JSON，确认有：
  "locale": "zh-cn"
EOF
}

main() {
  local user_dir
  user_dir="$(detect_cursor_user_dir)"

  if is_server_only_env; then
    echo "检测到云端 Cursor Server 环境，正在配置服务端..."
    bash "${SCRIPT_DIR}/apply-server-chinese-locale.sh"
    print_client_steps
    exit 0
  fi

  if [[ -z "$user_dir" ]]; then
    echo "无法识别 Cursor 配置目录。" >&2
    print_client_steps
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
      echo "自动安装失败，请按下方步骤手动安装。" >&2
    fi
  else
    echo "未找到 cursor 命令行工具，请按下方步骤手动安装扩展。" >&2
  fi

  echo
  echo "本地配置完成。请完全退出并重新打开 Cursor。"
  print_client_steps
}

main "$@"
