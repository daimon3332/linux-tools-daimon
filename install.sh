#!/bin/bash
set -e

BIN_NAME="d"
INSTALL_PATH="/usr/local/bin/${BIN_NAME}"
TMP_FILE="/tmp/daimon.sh"

# 部署 CDN 后，把下面两个域名改成你的真实地址即可。
SOURCES=(
  "https://cn-sh.example.com/daimon.sh"
  "https://sh.example.com/daimon.sh"
  "https://cdn.jsdelivr.net/gh/yourname/daimon@main/dist/daimon.sh"
  "https://raw.githubusercontent.com/yourname/daimon/main/dist/daimon.sh"
)

if [ "$(id -u)" != "0" ]; then
  echo "请使用 root 用户运行安装脚本"
  exit 1
fi

for url in "${SOURCES[@]}"; do
  echo "尝试下载: $url"
  if curl -fsSL --connect-timeout 8 --retry 2 "$url" -o "$TMP_FILE" || wget -O "$TMP_FILE" "$url"; then
    if head -1 "$TMP_FILE" | grep -q '^#!/bin/bash'; then
      mkdir -p /root/linux-script
      cp -f "$TMP_FILE" /root/daimon.sh
      chmod +x /root/daimon.sh
      cp -f /root/daimon.sh "$INSTALL_PATH"
      chmod +x "$INSTALL_PATH"
      ln -sf "$INSTALL_PATH" /usr/bin/d 2>/dev/null || true
      echo "安装完成，以后输入 d 启动 daimon脚本工具箱"
      exit 0
    fi
  fi
 done

echo "所有下载源都失败，请检查网络或 SOURCES 配置。"
exit 1
