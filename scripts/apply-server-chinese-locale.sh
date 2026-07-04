#!/usr/bin/env bash
set -euo pipefail

EXTENSION_ID="MS-CEINTL.vscode-language-pack-zh-hans"
LOCALE="zh-cn"
SERVER_USER_DIR="${HOME}/.cursor-server/data/User"
SERVER_EXT_DIR="${HOME}/.cursor-server/extensions"
SERVER_BIN_DIR="${HOME}/.cursor-server/bin"
TMP_DIR="/tmp/cursor-zh-hans-setup"

mkdir -p "$SERVER_USER_DIR" "$SERVER_EXT_DIR" "$TMP_DIR"

printf '%s\n' "{\"locale\":\"${LOCALE}\"}" > "${SERVER_USER_DIR}/locale.json"
printf '%s\n' "{
  \"locale\": \"${LOCALE}\"
}" > "${SERVER_USER_DIR}/argv.json"

mkdir -p "${SERVER_USER_DIR%/User}/Machine"
printf '%s\n' "{\"locale\":\"${LOCALE}\"}" > "${SERVER_USER_DIR%/User}/Machine/locale.json"

if [[ ! -d "${SERVER_EXT_DIR}"/ms-ceintl.vscode-language-pack-zh-hans-* ]]; then
  echo "正在下载中文语言包..."
  curl -sL -o "${TMP_DIR}/zh-hans.vsix" \
    "https://marketplace.visualstudio.com/_apis/public/gallery/publishers/MS-CEINTL/vsextensions/vscode-language-pack-zh-hans/latest/vspackage"
  gunzip -c "${TMP_DIR}/zh-hans.vsix" > "${TMP_DIR}/zh-hans.zip"
  unzip -qo "${TMP_DIR}/zh-hans.zip" -d "${TMP_DIR}/extracted"
  VERSION="$(python3 -c "import json; print(json.load(open('${TMP_DIR}/extracted/extension/package.json'))['version'])")"
  TARGET="${SERVER_EXT_DIR}/ms-ceintl.vscode-language-pack-zh-hans-${VERSION}"
  rm -rf "$TARGET"
  cp -r "${TMP_DIR}/extracted/extension" "$TARGET"
  python3 - "$TARGET/package.json" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
pkg = json.loads(path.read_text())
pkg.setdefault("engines", {})["vscode"] = "^1.105.0"
path.write_text(json.dumps(pkg, ensure_ascii=False))
PY
fi

EXT_PATH="$(ls -d "${SERVER_EXT_DIR}"/ms-ceintl.vscode-language-pack-zh-hans-* | head -1)"
VERSION="$(basename "$EXT_PATH" | sed 's/.*-//')"

python3 - "$SERVER_EXT_DIR/extensions.json" "$EXT_PATH" "$VERSION" <<'PY'
import json, sys
from pathlib import Path
ext_dir = Path(sys.argv[1])
ext_path = Path(sys.argv[2])
version = sys.argv[3]
entry = [{
    "identifier": {"id": "MS-CEINTL.vscode-language-pack-zh-hans"},
    "version": version,
    "location": {"$mid": 1, "path": str(ext_path), "scheme": "file"},
    "relativeLocation": ext_path.name,
    "metadata": {"installedTimestamp": 1751592000000, "source": "gallery"}
}]
ext_dir.write_text(json.dumps(entry, indent=2) + "\n")
print("extensions.json 已更新")
PY

echo "云端 Cursor Server 中文配置已完成："
echo "  - locale.json / argv.json -> ${LOCALE}"
echo "  - 语言包 -> ${EXT_PATH}"
echo
echo "注意：你看到的菜单/侧边栏界面由【本机 Cursor 客户端】控制。"
echo "请在本地 Cursor 中执行以下操作后重启："
echo "  1. Ctrl+Shift+X 搜索 Chinese，安装 Microsoft 简体中文语言包"
echo "  2. Ctrl+Shift+P 输入 Configure Display Language，选择 中文(简体)"
echo "  3. 完全退出并重新打开 Cursor"
