#!/usr/bin/env bash
# 在你 Mac 的【终端.app】里粘贴运行这一行（不是 Cursor 聊天窗口）：
# bash "/Users/你的用户名/path/to/EA/scripts/install-mac-chinese.sh"
# 或者在本项目目录执行：bash scripts/install-mac-chinese.sh

set -euo pipefail

EXTENSION_ID="MS-CEINTL.vscode-language-pack-zh-hans"
LOCALE="zh-cn"
USER_DIR="${HOME}/Library/Application Support/Cursor/User"
EXT_ROOT="${HOME}/.cursor/extensions"
TMP="/tmp/cursor-zh-hans-mac"

mkdir -p "$USER_DIR" "$EXT_ROOT" "$TMP"

echo "==> 1/3 写入中文显示语言配置"
printf '%s\n' "{\"locale\":\"${LOCALE}\"}" > "${USER_DIR}/locale.json"
if [[ -f "${USER_DIR}/argv.json" ]]; then
  python3 - "$USER_DIR/argv.json" "$LOCALE" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1]); loc = sys.argv[2]
data = json.loads(p.read_text()) if p.exists() else {}
data['locale'] = loc
p.write_text(json.dumps(data, indent=2) + '\n')
PY
else
  printf '%s\n' "{\n  \"locale\": \"${LOCALE}\"\n}" > "${USER_DIR}/argv.json"
fi

echo "==> 2/3 下载并安装中文语言包"
curl -fsSL -o "${TMP}/zh-hans.vsix" \
  "https://marketplace.visualstudio.com/_apis/public/gallery/publishers/MS-CEINTL/vsextensions/vscode-language-pack-zh-hans/latest/vspackage"
gunzip -c "${TMP}/zh-hans.vsix" > "${TMP}/zh-hans.zip"
rm -rf "${TMP}/extracted" && unzip -qo "${TMP}/zh-hans.zip" -d "${TMP}/extracted"
VERSION="$(python3 -c "import json; print(json.load(open('${TMP}/extracted/extension/package.json'))['version'])")"
TARGET="${EXT_ROOT}/ms-ceintl.vscode-language-pack-zh-hans-${VERSION}"
rm -rf "$TARGET"
cp -r "${TMP}/extracted/extension" "$TARGET"

if command -v cursor >/dev/null 2>&1; then
  echo "==> 3/3 通过 cursor 命令注册扩展"
  cursor --install-extension "$EXTENSION_ID" --force || true
elif [[ -x "/Applications/Cursor.app/Contents/Resources/app/bin/cursor" ]]; then
  "/Applications/Cursor.app/Contents/Resources/app/bin/cursor" --install-extension "$EXTENSION_ID" --force || true
else
  echo "==> 3/3 已手动解压语言包到 ${TARGET}"
fi

echo
echo "✅ 安装完成！请完全退出 Cursor（Cmd+Q），然后重新打开。"
echo "   打开后界面应显示为简体中文。"
