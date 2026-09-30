#!/bin/bash

daimon_url() {
	daimon_github_url_candidates "$1" | sed -n '1p'
}

daimon_git_clone() {
	local repo_url="$1"
	local target="$2"
	shift 2
	local clone_url prefix
	while IFS= read -r clone_url; do
		[ -z "$clone_url" ] && continue
		echo -e "${gl_kjlan}尝试克隆: $clone_url${gl_bai}"
		prefix=${clone_url%"$repo_url"}
		git -c "url.${prefix}https://github.com/.insteadOf=https://github.com/" \
			clone "$@" "$repo_url" "$target" && return 0
	done < <(daimon_github_url_candidates "$repo_url")
	return 1
}

daimon_git_update() {
	local target="$1" repo_url clone_url prefix
	shift
	repo_url=$(git -C "$target" remote get-url origin) || return 1
	repo_url=$(daimon_strip_github_proxy "$repo_url")
	while IFS= read -r clone_url; do
		prefix=${clone_url%"$repo_url"}
		git -C "$target" -c "url.${prefix}https://github.com/.insteadOf=https://github.com/" "$@" && return 0
	done < <(daimon_github_url_candidates "$repo_url")
	return 1
}

linux_tools() {
  local DAIMON_COUNTRY_CACHE="${DAIMON_COUNTRY_CACHE:-}"
  DAIMON_COUNTRY_CACHE=$(daimon_country)
  local thirdparty_ids=(vim cpcat ctrld starship bat btop tree ripgrep fd fzf blesh yazi ncdu nexttrace iperf3)
  local thirdparty_names=("vim" "cpcat" "Ctrl+D" "starship" "bat" "btop" "tree" "ripgrep" "fd" "fzf" "ble.sh" "yazi" "ncdu" "NextTrace" "iperf3")
  local thirdparty_desc=("文本编辑器+默认编辑器" "复制文件内容到剪贴板" "删除下一个单词绑定" "终端提示符美化" "终端高亮增强" "现代监控" "目录树" "快速文本搜索" "快速文件查找" "模糊搜索" "Bash 行编辑增强" "文件管理" "磁盘占用" "路由追踪" "网络性能测试")

  local programming_ids=(python npm nodejs bun uv git claude codex)
  local programming_names=("python" "npm" "nodejs" "bun" "uv" "git" "ClaudeCode" "Codex")
  local programming_desc=("Python 运行环境" "npm 包管理器" "Node.js 运行环境" "Bun 运行环境" "Python 包管理器" "版本控制" "AI 编程助手" "AI 编程助手")

  reload_bashrc_safely() {
    # 不在当前脚本进程里直接 source ~/.bashrc：
    # ble.sh / fzf / prompt 这类交互配置重复加载时可能导致 TTY detached 或 stty 异常。
    # 配置写入后由 restart_shell_after_tool_install 统一 exec bash 生效。
    hash -r 2>/dev/null || true
  }

  reload_shell_configs_safely() {
    reload_bashrc_safely
    hash -r 2>/dev/null || true
  }

  restart_shell_after_tool_install() {
    reload_shell_configs_safely
    [ "${DAIMON_DEFER_SHELL_RESTART:-0}" = 1 ] && return 0
    echo -e "${gl_lv}工具安装完成，正在使用 exec bash 重新进入命令行...${gl_bai}"
    exec bash
  }

  configure_vim_editor() {
    touch "$HOME/.bashrc"
    grep -qxF 'export EDITOR=vim' "$HOME/.bashrc" 2>/dev/null || echo 'export EDITOR=vim' >> "$HOME/.bashrc"
    grep -qxF 'export VISUAL=vim' "$HOME/.bashrc" 2>/dev/null || echo 'export VISUAL=vim' >> "$HOME/.bashrc"
    ensure_blesh_block_last
    reload_bashrc_safely
    echo "已设置默认编辑器: EDITOR=vim, VISUAL=vim"
  }

  remove_vim_editor_config() {
    [ -f "$HOME/.bashrc" ] && sed -i '/^export EDITOR=vim$/d;/^export VISUAL=vim$/d' "$HOME/.bashrc"
    reload_bashrc_safely
    echo "已删除 vim 默认编辑器配置"
  }

  remove_cpcat_config() {
    [ -f "$HOME/.bashrc" ] || return 0
    local tmp_file
    tmp_file=$(mktemp)
    awk '/^# ========== cpcat clipboard setup ==========$/ {skip=1; next} /^[[:space:]]*# ========== end cpcat clipboard setup ==========$/ {skip=0; next} !skip {print}' "$HOME/.bashrc" > "$tmp_file"
    cat "$tmp_file" > "$HOME/.bashrc"
    rm -f "$tmp_file"
  }

  configure_cpcat() {
    touch "$HOME/.bashrc"
    remove_cpcat_config
    cat >> "$HOME/.bashrc" << 'EOF'

# ========== cpcat clipboard setup ==========
# 一键复制文件内容到剪贴板
cpcat() {
    if [ -f "$1" ]; then
        printf "\033]52;c;$(base64 < "$1" | tr -d '\n')\a"
        echo "✅ 已复制到剪贴板: $1"
    else
        echo "❌ 文件不存在: $1"
    fi
}
# ========== end cpcat clipboard setup ==========
EOF
    ensure_blesh_block_last
    reload_bashrc_safely
    echo "已配置 cpcat"
  }

  remove_ctrld_config() {
    [ -f "$HOME/.bashrc" ] || return 0
    local tmp_file
    tmp_file=$(mktemp)
    awk '/^# ==================== Ctrl\+D 改为删除下一个单词 ====================$/ {skip=1; next} /^[[:space:]]*# ==================== end Ctrl\+D 改为删除下一个单词 ====================$/ {skip=0; next} !skip {print}' "$HOME/.bashrc" | sed '/^bind '\''"\\C-d": kill-word'\''$/d' > "$tmp_file"
    cat "$tmp_file" > "$HOME/.bashrc"
    rm -f "$tmp_file"
  }

  configure_ctrld() {
    touch "$HOME/.bashrc"
    remove_ctrld_config
    cat >> "$HOME/.bashrc" << 'EOF'

# ==================== Ctrl+D 改为删除下一个单词 ====================
bind '"\C-d": kill-word'
# ==================== end Ctrl+D 改为删除下一个单词 ====================
EOF
    ensure_blesh_block_last
    reload_bashrc_safely
    echo "已配置 Ctrl+D 删除下一个单词"
  }

  configure_fd_alias() {
    touch "$HOME/.bashrc"
    sed -i "/^alias fd='fdfind'$/d;/^alias fd=fdfind$/d;/^alias fd=\"fdfind\"$/d" "$HOME/.bashrc" 2>/dev/null || true
    echo "alias fd='fdfind'" >> "$HOME/.bashrc"
    if [ -L /usr/local/bin/fd ] && readlink /usr/local/bin/fd 2>/dev/null | grep -q 'fdfind'; then
      rm -f /usr/local/bin/fd 2>/dev/null || true
    fi
    ensure_blesh_block_last
    reload_bashrc_safely
    echo "已配置 fd 别名: alias fd='fdfind'"
  }

  remove_fd_alias() {
    [ -f "$HOME/.bashrc" ] && sed -i "/^alias fd='fdfind'$/d;/^alias fd=fdfind$/d;/^alias fd=\"fdfind\"$/d" "$HOME/.bashrc" 2>/dev/null || true
    if [ -L /usr/local/bin/fd ] && readlink /usr/local/bin/fd 2>/dev/null | grep -q 'fdfind'; then
      rm -f /usr/local/bin/fd 2>/dev/null || true
    fi
    reload_bashrc_safely
    echo "已删除 fd 别名"
  }

  remove_fzf_config() {
    remove_shell_block "$HOME/.bashrc" '# ========== fzf 核心配置 ==========' '# ========== end fzf 核心配置 =========='
    [ -f "$HOME/.bashrc" ] && sed -i '/\.fzf\.bash/d;/\.fzf\/bin/d;/\/root\/linux-daimon\/tools\/fzf/d;/FZF_DEFAULT_COMMAND/d;/FZF_DEFAULT_OPTS/d;/FZF_CTRL_T_OPTS/d;/FZF_ALT_C_OPTS/d;/BAT_PREVIEW/d' "$HOME/.bashrc" 2>/dev/null || true
  }

  configure_fzf() {
    install git curl tar gzip || return 1
    if ! tool_installed fd; then
      echo "fzf 需要 fd/fdfind，正在安装 fd..."
      install_tool_by_id fd || return 1
    fi
    if ! tool_installed bat; then
      echo "fzf 预览需要 bat/batcat，正在安装 bat..."
      install_tool_by_id bat || return 1
    fi
    if ! tool_installed tree; then
      echo "fzf Alt+C 目录预览需要 tree，正在安装 tree..."
      install_tool_by_id tree || return 1
    fi
    if [ -d "$DAIMON_FZF_DIR/.git" ]; then
      daimon_git_update "$DAIMON_FZF_DIR" pull --ff-only || return 1
    else
      if [ -e "$DAIMON_FZF_DIR" ]; then
        echo "fzf 目录已存在但不是 Git 仓库，请检查: $DAIMON_FZF_DIR"
        return 1
      fi
      daimon_git_clone "https://github.com/junegunn/fzf.git" "$DAIMON_FZF_DIR" --depth 1 || return 1
    fi

    if daimon_is_cn; then
      install_fzf_release || return 1
    fi
    if [ -x "$DAIMON_FZF_DIR/install" ]; then
      "$DAIMON_FZF_DIR/install" --key-bindings --completion --no-update-rc || return 1
    fi
    "$DAIMON_FZF_DIR/bin/fzf" --version || return 1
    export PATH="$DAIMON_FZF_DIR/bin:$PATH"

    touch "$HOME/.bashrc"
    remove_fzf_config
    cat >> "$HOME/.bashrc" <<'EOF'

# ========== fzf 核心配置 ==========

# git clone 安装的 fzf 默认在 /root/linux-daimon/tools/fzf/bin，先加入 PATH，避免 command -v 找不到
[ -d "/root/linux-daimon/tools/fzf/bin" ] && export PATH="/root/linux-daimon/tools/fzf/bin:$PATH"

# 如果没有安装 fzf，只跳过 fzf 配置，不 return 整个 ~/.bashrc
if command -v fzf >/dev/null 2>&1; then
  if fzf --bash >/dev/null 2>&1; then
    eval "$(fzf --bash)"
  elif [ -f ~/.fzf.bash ]; then
    source ~/.fzf.bash
  fi
  # 默认使用 fd/fdfind 列文件
  if command -v fdfind >/dev/null 2>&1; then
    export FZF_DEFAULT_COMMAND='fdfind --type f --strip-cwd-prefix --hidden --follow --exclude .git'
  elif command -v fd >/dev/null 2>&1; then
    export FZF_DEFAULT_COMMAND='fd --type f --strip-cwd-prefix --hidden --follow --exclude .git'
  fi

  # bat/batcat 兼容
  if command -v batcat >/dev/null 2>&1; then
    BAT_PREVIEW='batcat --color=always --style=numbers --line-range=:500 {}'
  elif command -v bat >/dev/null 2>&1; then
    BAT_PREVIEW='bat --color=always --style=numbers --line-range=:500 {}'
  else
    BAT_PREVIEW='sed -n "1,500p" {}'
  fi

  export FZF_DEFAULT_OPTS="
    --height 50%
    --layout=reverse
    --border
    --inline-info
    --preview '$BAT_PREVIEW'
    --preview-window=right:50%
    --bind 'ctrl-/:toggle-preview'
  "

  export FZF_CTRL_T_OPTS="--preview '$BAT_PREVIEW'"

  if command -v tree >/dev/null 2>&1; then
    export FZF_ALT_C_OPTS="--preview 'tree -C {} | head -200'"
  else
    export FZF_ALT_C_OPTS="--preview 'ls -la {} | head -200'"
  fi
fi
# ========== end fzf 核心配置 ==========
EOF
    ensure_blesh_block_last
    reload_bashrc_safely
    "$DAIMON_FZF_DIR/bin/fzf" --version 2>/dev/null || fzf --version 2>/dev/null || true
    echo "fzf 已通过 git clone 安装到 $DAIMON_FZF_DIR 并写入 ~/.bashrc 配置"
  }

  install_fzf_release() (
    local version arch work
    version=$(sed -n 's/^version=//p' "$DAIMON_FZF_DIR/install")
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    case "$(uname -m)" in
      x86_64|amd64) arch=amd64 ;;
      aarch64|arm64) arch=arm64 ;;
      *) echo "不支持的 fzf 架构: $(uname -m)"; return 1 ;;
    esac
    work=$(mktemp -d) || return 1
    trap 'rm -rf -- "$work"' EXIT
    daimon_download_to "https://github.com/junegunn/fzf/releases/download/v$version/fzf-$version-linux_$arch.tar.gz" "$work/fzf.tar.gz" || return 1
    tar -xzOf "$work/fzf.tar.gz" fzf > "$work/fzf" || return 1
    chmod 755 "$work/fzf" || return 1
    [ "$("$work/fzf" --version | cut -d' ' -f1)" = "$version" ] || return 1
    command install -m 755 "$work/fzf" "$DAIMON_FZF_DIR/bin/fzf"
  )

  remove_fzf_all() {
    remove_fzf_config
    rm -rf "$DAIMON_FZF_DIR"
    remove fzf
    reload_bashrc_safely
    echo "已删除 fzf、$DAIMON_FZF_DIR 和 ~/.bashrc 中的 fzf 配置"
  }

  remove_blesh_config() {
    remove_shell_block "$HOME/.bashrc" '# ========== ble.sh setup ==========' '# ========== end ble.sh setup =========='
    [ -f "$HOME/.bashrc" ] && sed -i '\#\.local/share/blesh/ble\.sh#d;\#blesh/ble\.sh#d' "$HOME/.bashrc" 2>/dev/null || true
  }

  ensure_blesh_block_last() {
    [ -f "$HOME/.local/share/blesh/ble.sh" ] || return 0
    touch "$HOME/.bashrc"
    remove_blesh_config
    cat >> "$HOME/.bashrc" <<'EOF'

# ========== ble.sh setup ==========
[ -f ~/.local/share/blesh/ble.sh ] && source ~/.local/share/blesh/ble.sh
# ========== end ble.sh setup ==========
EOF
  }

  configure_blesh() {
    install git make gawk || return 1
    if [ -d "$HOME/ble.sh/.git" ]; then
      daimon_git_update "$HOME/ble.sh" pull --ff-only || return 1
      daimon_git_update "$HOME/ble.sh" submodule update --init --recursive || return 1
    else
      if [ -e "$HOME/ble.sh" ]; then
        echo "ble.sh 目录已存在但不是 Git 仓库，请检查: $HOME/ble.sh"
        return 1
      fi
      daimon_git_clone "https://github.com/akinomyoga/ble.sh.git" "$HOME/ble.sh" --recursive || return 1
    fi

    (cd "$HOME/ble.sh" && make install) || return 1
    [ -s "$HOME/.local/share/blesh/ble.sh" ] || return 1

    ensure_blesh_block_last

    cat > "$HOME/.blerc" <<'EOF'
# 自动补全
bleopt complete_auto_complete=1
# history 自动补全
bleopt complete_auto_history=1
# 使用fzf的快捷键
if command -v fzf >/dev/null 2>&1 || [ -x "/root/linux-daimon/tools/fzf/bin/fzf" ]; then
   ble-import -d integration/fzf-key-bindings
 fi
EOF
    ensure_blesh_block_last
    reload_bashrc_safely
    echo "ble.sh 已安装并配置 ~/.bashrc 和 ~/.blerc"
  }

  remove_blesh_all() {
    remove_blesh_config
    rm -rf "$HOME/ble.sh" "$HOME/.local/share/blesh" "$HOME/.blerc"
    reload_bashrc_safely
    echo "已删除 ble.sh、~/.blerc 和 ~/.bashrc 中的 ble.sh 配置"
  }

  stop_disable_service_safely() {
    local service_name="$1"
    if command -v systemctl >/dev/null 2>&1 && [ -x /bin/systemctl ]; then
      /bin/systemctl stop "$service_name" >/dev/null 2>&1 || true
      /bin/systemctl disable "$service_name" >/dev/null 2>&1 || true
    elif command -v service >/dev/null 2>&1; then
      service "$service_name" stop >/dev/null 2>&1 || true
    fi
  }

  remove_fail2ban_all() {
    stop_disable_service_safely fail2ban
    remove fail2ban
    rm -rf /etc/fail2ban /var/lib/fail2ban
    rm -f /var/log/fail2ban.log
    echo "已彻底删除 fail2ban、配置目录和日志文件"
  }

  remove_iptables_persistent_all() {
    stop_disable_service_safely netfilter-persistent
    stop_disable_service_safely iptables
    remove iptables-persistent netfilter-persistent iptables-services
    rm -rf /etc/iptables
    echo "已彻底删除 iptables-persistent/netfilter-persistent 和 /etc/iptables"
  }

  remove_ufw_all() {
    ufw disable >/dev/null 2>&1 || true
    stop_disable_service_safely ufw
    remove ufw
    rm -rf /etc/ufw /var/lib/ufw
    echo "已彻底删除 ufw、配置目录和状态目录"
  }

  remove_firewalld_all() {
    stop_disable_service_safely firewalld
    remove firewalld
    rm -rf /etc/firewalld
    echo "已彻底删除 firewalld 和 /etc/firewalld"
  }


  remove_shell_block() {
    local file="$1"
    local start_pattern="$2"
    local end_pattern="$3"
    [ -f "$file" ] || return 0
    local tmp_file
    tmp_file=$(mktemp)
    awk -v start="$start_pattern" -v end="$end_pattern" '
      $0 == start {skip=1; next}
      $0 == end {skip=0; next}
      !skip {print}
    ' "$file" > "$tmp_file"
    cat "$tmp_file" > "$file"
    rm -f "$tmp_file"
  }

  remove_starship_config() {
    remove_shell_block "$HOME/.bashrc" '# ========== starship prompt setup ==========' '# ========== end starship prompt setup =========='
    remove_shell_block "$HOME/.zshrc" '# ========== starship prompt setup ==========' '# ========== end starship prompt setup =========='
    [ -f "$HOME/.bashrc" ] && sed -i '/starship init bash/d' "$HOME/.bashrc"
    [ -f "$HOME/.zshrc" ] && sed -i '/starship init zsh/d' "$HOME/.zshrc"
  }

  configure_starship() {
    root_use
    install curl tar gzip || return 1
    mkdir -p "$DAIMON_SCRIPT_DIR" "$HOME/.config"
    local starship_arch starship_target starship_url starship_tar starship_tmp starship_bin starship_status=0

    if daimon_is_cn; then
      case "$(uname -m)" in
        x86_64|amd64) starship_arch="x86_64" ;;
        aarch64|arm64) starship_arch="aarch64" ;;
        i686|i386) starship_arch="i686" ;;
        *) starship_arch="" ;;
      esac

      if [ -z "$starship_arch" ]; then
        echo "当前架构暂不支持自动安装 starship: $(uname -m)"
        return 1
      fi

      starship_target="${starship_arch}-unknown-linux-musl"
      starship_url="https://gh-proxy.com/https://github.com/starship/starship/releases/latest/download/starship-${starship_target}.tar.gz"
      starship_tmp=$(mktemp -d) || return 1
      starship_tar="$starship_tmp/starship.tar.gz"

      if daimon_download_to "$starship_url" "$starship_tar" && tar -xzf "$starship_tar" -C "$starship_tmp"; then
        starship_bin="$starship_tmp/starship"
        [ -f "$starship_bin" ] || starship_bin=$(find "$starship_tmp" -type f -name starship | head -1)
        [ -n "$starship_bin" ] && command install -m 755 "$starship_bin" /usr/local/bin/starship || starship_status=1
      else
        starship_status=1
      fi

      rm -rf -- "$starship_tmp"
    else
      (set -o pipefail; curl -fsSL --connect-timeout 10 --max-time 60 https://starship.rs/install.sh | sh -s -- -y) || starship_status=1
    fi

    if [ "$starship_status" -ne 0 ] || ! starship --version >/dev/null 2>&1; then
      command -v starship >/dev/null 2>&1 || remove_starship_config
      echo "starship 安装失败，未写入新的 Shell 配置"
      return 1
    fi

    touch "$HOME/.bashrc"
    remove_starship_config
    cat >> "$HOME/.bashrc" <<'EOF'
# ========== starship prompt setup ==========
eval "$(starship init bash)"
# ========== end starship prompt setup ==========
EOF
    touch "$HOME/.zshrc"
    cat >> "$HOME/.zshrc" <<'EOF'
# ========== starship prompt setup ==========
eval "$(starship init zsh)"
# ========== end starship prompt setup ==========
EOF

    cat > "$HOME/.config/starship.toml" <<'EOF'
"$schema" = 'https://starship.rs/config-schema.json'

format = """
[](red)\
$os\
$username\
[](bg:peach fg:red)\
$directory\
[](bg:yellow fg:peach)\
$git_branch\
$git_status\
[](fg:yellow bg:green)\
$c\
$rust\
$golang\
$nodejs\
$bun\
$php\
$java\
$kotlin\
$haskell\
$python\
[](fg:green bg:sapphire)\
$conda\
[](fg:sapphire bg:lavender)\
$time\
[ ](fg:lavender)\
$cmd_duration\
$line_break\
$character"""

palette = 'catppuccin_mocha'

[os]
disabled = false
style = "bg:red fg:crust"

[os.symbols]
Windows = ""
Ubuntu = ""
SUSE = ""
Raspbian = ""
Mint = ""
Macos = ""
Manjaro = ""
Linux = ""
Gentoo = ""
Fedora = ""
Alpine = ""
Amazon = ""
Android = ""
AOSC = ""
Arch = ""
Artix = ""
CentOS = ""
Debian = ""
Redhat = ""
RedHatEnterprise = ""

[username]
show_always = true
style_user = "bg:red fg:crust"
style_root = "bg:red fg:crust"
format = '[ $user]($style)'

[directory]
style = "bg:peach fg:crust"
format = "[ $path ]($style)"
home_symbol = "/root"
truncate_to_repo = false
truncation_length = 100
truncation_symbol = ""
fish_style_pwd_dir_length = 0

[directory.substitutions]
"Documents" = " "
"Downloads" = " "
"Music" = " "
"Pictures" = " "
"Developer" = " "

[git_branch]
symbol = ""
style = "bg:yellow"
format = '[[ $symbol $branch ](fg:crust bg:yellow)]($style)'

[git_status]
style = "bg:yellow"
format = '[[($all_status$ahead_behind )](fg:crust bg:yellow)]($style)'

[nodejs]
symbol = ""
style = "bg:green"
format = '[[ $symbol( $version) ](fg:crust bg:green)]($style)'

[bun]
symbol = ""
style = "bg:green"
format = '[[ $symbol( $version) ](fg:crust bg:green)]($style)'

[c]
symbol = " "
style = "bg:green"
format = '[[ $symbol( $version) ](fg:crust bg:green)]($style)'

[rust]
symbol = ""
style = "bg:green"
format = '[[ $symbol( $version) ](fg:crust bg:green)]($style)'

[golang]
symbol = ""
style = "bg:green"
format = '[[ $symbol( $version) ](fg:crust bg:green)]($style)'

[php]
symbol = ""
style = "bg:green"
format = '[[ $symbol( $version) ](fg:crust bg:green)]($style)'

[java]
symbol = " "
style = "bg:green"
format = '[[ $symbol( $version) ](fg:crust bg:green)]($style)'

[kotlin]
symbol = ""
style = "bg:green"
format = '[[ $symbol( $version) ](fg:crust bg:green)]($style)'

[haskell]
symbol = ""
style = "bg:green"
format = '[[ $symbol( $version) ](fg:crust bg:green)]($style)'

[python]
symbol = ""
style = "bg:green"
format = '[[ $symbol( $version)(\(#$virtualenv\)) ](fg:crust bg:green)]($style)'

[docker_context]
symbol = ""
style = "bg:sapphire"
format = '[[ $symbol( $context) ](fg:crust bg:sapphire)]($style)'

[conda]
symbol = "  "
style = "fg:crust bg:sapphire"
format = '[$symbol$environment ]($style)'
ignore_base = false

[time]
disabled = false
time_format = "%R"
style = "bg:lavender"
format = '[[  $time ](fg:crust bg:lavender)]($style)'

[line_break]
disabled = false

[character]
disabled = false
success_symbol = '[❯](bold fg:green)'
error_symbol = '[❯](bold fg:red)'
vimcmd_symbol = '[❮](bold fg:green)'
vimcmd_replace_one_symbol = '[❮](bold fg:lavender)'
vimcmd_replace_symbol = '[❮](bold fg:lavender)'
vimcmd_visual_symbol = '[❮](bold fg:yellow)'

[cmd_duration]
show_milliseconds = true
format = " in $duration "
style = "bg:lavender"
disabled = false
show_notifications = true
min_time_to_notify = 45000

[palettes.catppuccin_mocha]
rosewater = "#f5e0dc"
flamingo = "#f2cdcd"
pink = "#f5c2e7"
mauve = "#cba6f7"
red = "#f38ba8"
maroon = "#eba0ac"
peach = "#fab387"
yellow = "#f9e2af"
green = "#a6e3a1"
teal = "#94e2d5"
sky = "#89dceb"
sapphire = "#74c7ec"
blue = "#89b4fa"
lavender = "#b4befe"
text = "#cdd6f4"
subtext1 = "#bac2de"
subtext0 = "#a6adc8"
overlay2 = "#9399b2"
overlay1 = "#7f849c"
overlay0 = "#6c7086"
surface2 = "#585b70"
surface1 = "#45475a"
surface0 = "#313244"
base = "#1e1e2e"
mantle = "#181825"
crust = "#11111b"

[palettes.catppuccin_frappe]
rosewater = "#f2d5cf"
flamingo = "#eebebe"
pink = "#f4b8e4"
mauve = "#ca9ee6"
red = "#e78284"
maroon = "#ea999c"
peach = "#ef9f76"
yellow = "#e5c890"
green = "#a6d189"
teal = "#81c8be"
sky = "#99d1db"
sapphire = "#85c1dc"
blue = "#8caaee"
lavender = "#babbf1"
text = "#c6d0f5"
subtext1 = "#b5bfe2"
subtext0 = "#a5adce"
overlay2 = "#949cbb"
overlay1 = "#838ba7"
overlay0 = "#737994"
surface2 = "#626880"
surface1 = "#51576d"
surface0 = "#414559"
base = "#303446"
mantle = "#292c3c"
crust = "#232634"

[palettes.catppuccin_latte]
rosewater = "#dc8a78"
flamingo = "#dd7878"
pink = "#ea76cb"
mauve = "#8839ef"
red = "#d20f39"
maroon = "#e64553"
peach = "#fe640b"
yellow = "#df8e1d"
green = "#40a02b"
teal = "#179299"
sky = "#04a5e5"
sapphire = "#209fb5"
blue = "#1e66f5"
lavender = "#7287fd"
text = "#4c4f69"
subtext1 = "#5c5f77"
subtext0 = "#6c6f85"
overlay2 = "#7c7f93"
overlay1 = "#8c8fa1"
overlay0 = "#9ca0b0"
surface2 = "#acb0be"
surface1 = "#bcc0cc"
surface0 = "#ccd0da"
base = "#eff1f5"
mantle = "#e6e9ef"
crust = "#dce0e8"

[palettes.catppuccin_macchiato]
rosewater = "#f4dbd6"
flamingo = "#f0c6c6"
pink = "#f5bde6"
mauve = "#c6a0f6"
red = "#ed8796"
maroon = "#ee99a0"
peach = "#f5a97f"
yellow = "#eed49f"
green = "#a6da95"
teal = "#8bd5ca"
sky = "#91d7e3"
sapphire = "#7dc4e4"
blue = "#8aadf4"
lavender = "#b7bdf8"
text = "#cad3f5"
subtext1 = "#b8c0e0"
subtext0 = "#a5adcb"
overlay2 = "#939ab7"
overlay1 = "#8087a2"
overlay0 = "#6e738d"
surface2 = "#5b6078"
surface1 = "#494d64"
surface0 = "#363a4f"
base = "#24273a"
mantle = "#1e2030"
crust = "#181926"
EOF
    ensure_blesh_block_last
    reload_bashrc_safely
    starship --version 2>/dev/null || true
    echo "starship 已安装并写入配置: $HOME/.config/starship.toml"
  }

  remove_starship_all() {
    remove_starship_config
    rm -f "$HOME/.config/starship.toml"
    rm -f "$DAIMON_SCRIPT_DIR/starship-install.sh"
    rm -f /usr/local/bin/starship /usr/bin/starship "$HOME/.local/bin/starship" "$HOME/.cargo/bin/starship" 2>/dev/null || true
    reload_bashrc_safely
    echo "已彻底删除 starship、shell 初始化配置和 ~/.config/starship.toml"
  }

  remove_bat_config() {
    local bashrc_file="$HOME/.bashrc"
    [ -f "$bashrc_file" ] || return 0
    local tmp_file
    tmp_file=$(mktemp)
    awk '
      /^# ========== bat terminal color setup ==========$/ {skip=1; next}
      /^[[:space:]]*# ========== end bat terminal color setup ==========$/ {skip=0; next}
      /^# ========== bat 终端着色增强 ==========$/ {skip=1; next}
      skip && /^[[:space:]]*fi[[:space:]]*$/ {skip=0; next}
      !skip {print}
    ' "$bashrc_file" > "$tmp_file"
    cat "$tmp_file" > "$bashrc_file"
    rm -f "$tmp_file"
    rm -f "$HOME/.bat.sh"
  }

  configure_bat_terminal() {
    if ! command -v batcat >/dev/null 2>&1 && ! command -v bat >/dev/null 2>&1; then
      install bat
    fi
    if ! command -v batcat >/dev/null 2>&1 && ! command -v bat >/dev/null 2>&1; then
      echo "bat 安装失败或当前系统未提供 bat/batcat 命令"
      return 1
    fi
    local bashrc_file="$HOME/.bashrc"
    local bat_file="$HOME/.bat.sh"
    touch "$bashrc_file"
    remove_bat_config
    cat > "$bat_file" <<'EOF'
  # 避免 alias 抢在函数前面生效
  unalias bat cat docker ping ip ss ps df free systemctl journalctl git lsblk netstat ufw 2>/dev/null

  # Debian/Ubuntu 上 bat 通常叫 batcat
  if command -v batcat >/dev/null 2>&1; then
    __BAT_BIN="batcat"
  elif command -v bat >/dev/null 2>&1; then
    __BAT_BIN="bat"
  else
    __BAT_BIN=""
  fi

  if [ -n "$__BAT_BIN" ]; then
    alias bat="$__BAT_BIN"

    __bat_filter() {
      local lang="${1:-log}"
      if [ -t 1 ]; then
        "$__BAT_BIN" --paging=never --style=plain --color=always -l "$lang"
      else
        command cat
      fi
    }

    cat() {
      if [ -t 1 ]; then
        "$__BAT_BIN" --paging=never --style=plain "$@"
      else
        command cat "$@"
      fi
    }

    bcat()  { __bat_filter log; }
    blog()  { __bat_filter log; }
    bjson() { __bat_filter json; }
    byaml() { __bat_filter yaml; }
    bconf() { __bat_filter conf; }
    bsh()   { __bat_filter bash; }
    bdiff() { __bat_filter diff; }
    bhttp() { __bat_filter http; }

    bauto() {
      local tmp lang
      tmp="$(mktemp)"
      command cat > "$tmp"
      if python3 -m json.tool "$tmp" >/dev/null 2>&1; then
        lang="json"
      elif grep -qE '^(diff --git|@@ |--- |\+\+\+ )' "$tmp"; then
        lang="diff"
      elif grep -qE '^[[:space:]]*[A-Za-z0-9_.-]+:[[:space:]]*' "$tmp"; then
        lang="yaml"
      elif head -n 1 "$tmp" | grep -qE '^#!.*(ba|z|k)?sh'; then
        lang="bash"
      else
        lang="log"
      fi
      if [ -t 1 ]; then
        "$__BAT_BIN" --paging=never --style=plain --color=always -l "$lang" "$tmp"
      else
        command cat "$tmp"
      fi
      rm -f "$tmp"
    }

    raw() { command "$@"; }

    docker() {
      case "$1" in
        ps|images|info|version|stats|events) command docker "$@" 2>&1 | __bat_filter log; return ${PIPESTATUS[0]} ;;
        inspect) command docker "$@" 2>&1 | __bat_filter json; return ${PIPESTATUS[0]} ;;
        logs) command docker "$@" 2>&1 | __bat_filter log; return ${PIPESTATUS[0]} ;;
        compose)
          case "$2" in
            config) command docker "$@" 2>&1 | __bat_filter yaml; return ${PIPESTATUS[0]} ;;
            ps|logs|events|images|top) command docker "$@" 2>&1 | __bat_filter log; return ${PIPESTATUS[0]} ;;
            *) command docker "$@" ;;
          esac
          ;;
        *) command docker "$@" ;;
      esac
    }

    ping() { command ping "$@" 2>&1 | __bat_filter log; return ${PIPESTATUS[0]}; }
    ip() { command ip "$@" 2>&1 | __bat_filter log; return ${PIPESTATUS[0]}; }
    ss() { command ss "$@" 2>&1 | __bat_filter log; return ${PIPESTATUS[0]}; }
    netstat() { command netstat "$@" 2>&1 | __bat_filter log; return ${PIPESTATUS[0]}; }
    ps() { command ps "$@" 2>&1 | __bat_filter log; return ${PIPESTATUS[0]}; }
    df() { command df "$@" 2>&1 | __bat_filter log; return ${PIPESTATUS[0]}; }
    free() { command free "$@" 2>&1 | __bat_filter log; return ${PIPESTATUS[0]}; }
    lsblk() { command lsblk "$@" 2>&1 | __bat_filter log; return ${PIPESTATUS[0]}; }
    systemctl() { command systemctl --no-pager "$@" 2>&1 | __bat_filter log; return ${PIPESTATUS[0]}; }
    journalctl() { command journalctl --no-pager "$@" 2>&1 | __bat_filter log; return ${PIPESTATUS[0]}; }

    ufw() {
      case "$1" in
        status|show|app) command ufw "$@" 2>&1 | __bat_filter log; return ${PIPESTATUS[0]} ;;
        *) command ufw "$@" ;;
      esac
    }

    git() {
      case "$1" in
        diff|show) command git -c color.ui=never "$@" 2>&1 | __bat_filter diff; return ${PIPESTATUS[0]} ;;
        status|log|branch|remote) command git -c color.ui=never "$@" 2>&1 | __bat_filter log; return ${PIPESTATUS[0]} ;;
        *) command git "$@" ;;
      esac
    }
  fi
EOF
    cat >> "$bashrc_file" <<'EOF'
# ========== bat 终端着色增强 ==========
if [ -f ~/.bat.sh ]; then
    source ~/.bat.sh
fi
EOF
    ensure_blesh_block_last
    reload_bashrc_safely
    echo "bat 终端高亮配置已写入: $bat_file"
  }

  remove_bat_all() {
    remove_bat_config
    remove bat batcat
    reload_bashrc_safely
    echo "已删除 bat 终端高亮配置，并尝试卸载 bat/batcat"
  }

  install_yazi_griffo() {
    root_use
    install curl ca-certificates file || return 1
    if command -v apt >/dev/null 2>&1; then
      command install -d -m 0755 /etc/apt/keyrings || return 1
      daimon_download_to https://yazi-rs.github.io/builds/yazi-keyring.gpg /etc/apt/keyrings/yazi.gpg || return 1
      chmod 644 /etc/apt/keyrings/yazi.gpg || return 1
      printf '%s\n' 'deb [signed-by=/etc/apt/keyrings/yazi.gpg] https://yazi-rs.github.io/builds/ stable main' \
        > /etc/apt/sources.list.d/yazi.list || return 1
      DEBIAN_FRONTEND=noninteractive apt-get update \
        -o Dir::Etc::sourcelist=sources.list.d/yazi.list -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0 || return 1
      DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a APT_LISTCHANGES_FRONTEND=none apt-get install -y --no-install-recommends \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        yazi || return 1
    else
      install yazi || return 1
    fi
    yazi --version && ya --version
  }

  remove_yazi_all() {
    remove yazi || return 1
    rm -rf "$HOME/.config/yazi" "$HOME/.local/share/yazi" "$HOME/.cache/yazi"
    if command -v apt >/dev/null 2>&1; then
      rm -f /etc/apt/sources.list.d/debian.griffo.io.list
      rm -f /etc/apt/trusted.gpg.d/debian.griffo.io.gpg
      rm -f /etc/apt/sources.list.d/yazi.list /etc/apt/keyrings/yazi.gpg
      apt update -y 2>/dev/null || true
    fi
  }

  install_nexttrace() {
    root_use
    install curl ca-certificates || return 1
    if command -v apt >/dev/null 2>&1; then
      local repo_url
      repo_url=$(daimon_url https://github.com/nxtrace/nexttrace-debs/releases/latest/download/)
      command install -d -m 0755 /etc/apt/keyrings || return 1
      daimon_download_to "https://github.com/nxtrace/nexttrace-debs/releases/latest/download/nexttrace-archive-keyring.gpg" /etc/apt/keyrings/nexttrace.gpg || return 1
      chmod 644 /etc/apt/keyrings/nexttrace.gpg || return 1
      printf '%s\n' \
        'Types: deb' \
        "URIs: $repo_url" \
        'Suites: ./' \
        'Signed-By: /etc/apt/keyrings/nexttrace.gpg' \
        > /etc/apt/sources.list.d/nexttrace.sources || return 1
      DEBIAN_FRONTEND=noninteractive apt-get update \
        -o Dir::Etc::sourcelist=sources.list.d/nexttrace.sources -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0 || return 1
      DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a APT_LISTCHANGES_FRONTEND=none apt-get install -y \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        nexttrace || return 1
    else
      install nexttrace || return 1
    fi
    nexttrace --version
  }

  remove_nexttrace_all() {
    remove nexttrace
    if command -v apt >/dev/null 2>&1; then
      rm -f /etc/apt/keyrings/nexttrace.gpg /etc/apt/sources.list.d/nexttrace.sources
      apt update -y 2>/dev/null || true
    fi
  }

  python_312_is_default() {
    if [ -r /etc/os-release ] && [ "$(. /etc/os-release; printf '%s' "$ID")" = debian ]; then
      command -v python3 >/dev/null 2>&1 && python3 --version 2>&1 | grep -q '^Python 3\.'
      return
    fi
    command -v python3.12 >/dev/null 2>&1 || return 1
    python --version 2>&1 | grep -q '^Python 3\.12\.'
  }

  install_python_312() {
    root_use
    local python312_bin
    if [ -r /etc/os-release ] && [ "$(. /etc/os-release; printf '%s' "$ID")" = debian ]; then
      install python3 python3-venv python3-pip || return 1
      python3 --version
      return
    fi
    if command -v apt >/dev/null 2>&1; then
      DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a APT_LISTCHANGES_FRONTEND=none apt update -y
      if ! apt-cache show python3.12 >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a APT_LISTCHANGES_FRONTEND=none apt install -y \
          -o Dpkg::Options::="--force-confdef" \
          -o Dpkg::Options::="--force-confold" \
          software-properties-common || return 1
        if ! command -v add-apt-repository >/dev/null 2>&1; then
          echo "未检测到 add-apt-repository，无法添加 Python 3.12 软件源"
          return 1
        fi
        add-apt-repository -y ppa:deadsnakes/ppa || return 1
        mkdir -p "$DAIMON_SCRIPT_DIR"
        touch "$DAIMON_SCRIPT_DIR/python312-deadsnakes-added"
        DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a APT_LISTCHANGES_FRONTEND=none apt update -y
      fi
      DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a APT_LISTCHANGES_FRONTEND=none apt install -y \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        python3.12 python3.12-venv python3.12-dev python3-pip || return 1
    else
      install python3.12
    fi

    python312_bin="$(command -v python3.12 2>/dev/null || true)"
    if [ -n "$python312_bin" ]; then
      if [ -e /usr/local/bin/python ] && [ "$(readlink /usr/local/bin/python 2>/dev/null)" != "/etc/alternatives/daimon-python" ]; then
        echo "检测到 /usr/local/bin/python 已存在，跳过默认 python 切换"
      elif command -v update-alternatives >/dev/null 2>&1; then
        update-alternatives --install /usr/local/bin/python daimon-python "$python312_bin" 312
        update-alternatives --set daimon-python "$python312_bin"
      fi
    fi

    hash -r 2>/dev/null || true
    python3.12 --version 2>/dev/null || true
    python --version 2>/dev/null || true
    if ! command -v python3.12 >/dev/null 2>&1; then
      echo "Python 3.12 安装失败"
      return 1
    fi
    if ! python_312_is_default; then
      echo "Python 3.12 已安装，但 python 默认命令未切换到 3.12"
      return 1
    fi
  }

  remove_python_312_all() {
    if [ -r /etc/os-release ] && [ "$(. /etc/os-release; printf '%s' "$ID")" = debian ]; then
      echo "Debian 系统 Python 已保留；不卸载系统解释器。"
      return 0
    fi
    if [ "$(readlink -f /usr/bin/python3 2>/dev/null)" = "$(readlink -f /usr/bin/python3.12 2>/dev/null)" ] && [ -x /usr/bin/python3.12 ]; then
      echo "Python 3.12 是系统 Python，保留解释器和系统依赖，仅移除 daimon 的 python 快捷配置。"
      command -v update-alternatives >/dev/null 2>&1 && update-alternatives --remove daimon-python /usr/bin/python3.12
      return 0
    fi
    if command -v update-alternatives >/dev/null 2>&1; then
      update-alternatives --remove daimon-python /usr/bin/python3.12 2>/dev/null || true
    fi
    if [ -L /usr/local/bin/python ] && [ "$(readlink /usr/local/bin/python 2>/dev/null)" = "/etc/alternatives/daimon-python" ]; then
      rm -f /usr/local/bin/python
    fi
    remove python3.12 python3.12-venv python3.12-dev
    if [ -f "$DAIMON_SCRIPT_DIR/python312-deadsnakes-added" ] && command -v add-apt-repository >/dev/null 2>&1; then
      add-apt-repository --remove -y ppa:deadsnakes/ppa 2>/dev/null || true
      rm -f "$DAIMON_SCRIPT_DIR/python312-deadsnakes-added"
      apt update -y 2>/dev/null || true
    fi
  }


  load_nvm_env() {
    export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
    [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
    [ -s "$NVM_DIR/bash_completion" ] && . "$NVM_DIR/bash_completion" 2>/dev/null || true
  }

  install_nvm_lts_auto() {
    install curl ca-certificates || return 1
    export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"

    if [ ! -s "$NVM_DIR/nvm.sh" ]; then
      if daimon_is_cn; then
        bash -c "$(curl -fsSL https://gitee.com/RubyMetric/nvm-cn/raw/main/install.sh)" || return 1
      else
        curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.6/install.sh | bash || return 1
      fi
    fi

    load_nvm_env
    if ! command -v nvm >/dev/null 2>&1; then
      echo "nvm 安装失败或未能加载"
      return 1
    fi

    nvm install --lts || return 1
    nvm alias default 'lts/*' || return 1
    nvm use default >/dev/null 2>&1 || true
    hash -r 2>/dev/null || true
    node -v
    npm -v
  }

  remove_nvm_all() {
    remove nodejs npm 2>/dev/null || true
    rm -rf "$HOME/.nvm" "$HOME/.npm" "$HOME/.node-gyp"
    [ -f "$HOME/.bashrc" ] && sed -i '/NVM_DIR/d;/nvm\.sh/d;/bash_completion.*nvm/d;/nvm-cn/d' "$HOME/.bashrc" 2>/dev/null || true
    [ -f "$HOME/.profile" ] && sed -i '/NVM_DIR/d;/nvm\.sh/d;/bash_completion.*nvm/d;/nvm-cn/d' "$HOME/.profile" 2>/dev/null || true
    [ -f "$HOME/.bash_profile" ] && sed -i '/NVM_DIR/d;/nvm\.sh/d;/bash_completion.*nvm/d;/nvm-cn/d' "$HOME/.bash_profile" 2>/dev/null || true
    reload_shell_configs_safely
    echo "已删除 nvm、Node.js、npm 及相关用户缓存"
  }

  configure_claude_code_settings() {
    [ ! -e "$HOME/.claude/settings.json" ] || { echo "保留已有 ClaudeCode 配置"; return 0; }
    mkdir -p "$HOME/.claude"
    cat > "$HOME/.claude/settings.json" <<'EOF'
{
  "env": {
    "DISABLE_INSTALLATION_CHECKS": "1",
    "ENABLE_TOOL_SEARCH": "true",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "claude-opus-4-8",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME": "claude-opus-4-8",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "claude-opus-4-8[1M]",
    "ANTHROPIC_DEFAULT_OPUS_MODEL_NAME": "claude-opus-4-8",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "claude-opus-4-8[1M]",
    "ANTHROPIC_DEFAULT_SONNET_MODEL_NAME": "claude-opus-4-8",
    "ANTHROPIC_MODEL": "claude-opus-4-8[1m]",
    "ANTHROPIC_REASONING_MODEL": "claude-opus-4-8[1m]",
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
    "DISABLE_AUTOUPDATER": "1",
    "ANTHROPIC_BASE_URL": "https://api.deepseek.com/anthropic",
    "ANTHROPIC_API_KEY": "12346"
  },
  "includeCoAuthoredBy": false,
  "model": "opus[1m]",
  "skipDangerousModePermissionPrompt": true,
  "hasCompletedOnboarding": true
}
EOF

    if command -v python3 >/dev/null 2>&1; then
      [ -f "$HOME/.claude.json" ] || printf '{}\n' > "$HOME/.claude.json"
      python3 - "$HOME/.claude.json" <<'PY'
import json
import sys
path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    data = {}
if not isinstance(data, dict):
    data = {}
data["hasCompletedOnboarding"] = True
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY
    else
      printf '{\n  "hasCompletedOnboarding": true\n}\n' > "$HOME/.claude.json"
    fi
  }

  install_claude_code_auto() {
    export PATH="$HOME/.local/bin:$PATH"
    if command -v claude >/dev/null 2>&1; then
      claude update 2>/dev/null || true
    elif daimon_is_cn; then
      install_nvm_lts_auto || return 1
      load_nvm_env
      npm install -g @anthropic-ai/claude-code --registry=https://registry.npmmirror.com || return 1
    else
      daimon_require_cmd curl || return 1
      curl -fsSL https://claude.ai/install.sh | bash || return 1
      export PATH="$HOME/.local/bin:$PATH"
    fi

    configure_claude_code_settings
    if ! command -v claude >/dev/null 2>&1; then
      echo "ClaudeCode 安装失败或 claude 命令不在 PATH"
      return 1
    fi
    claude --version
  }

  remove_claude_code_all() {
    load_nvm_env
    npm uninstall -g @anthropic-ai/claude-code 2>/dev/null || true
    rm -rf "$HOME/.claude"
    rm -f "$HOME/.claude.json"
    reload_shell_configs_safely
    echo "已删除 ClaudeCode 和 ~/.claude 配置"
  }

  configure_codex_settings() {
    [ ! -e "$HOME/.codex/config.toml" ] || { echo "保留已有 Codex 配置"; return 0; }
    mkdir -p "$HOME/.codex"
    cat > "$HOME/.codex/config.toml" <<'EOF'
model = "gpt-5.5"
model_reasoning_effort = "high"
disable_response_storage = true
fast_mode = true
service_tier = "fast"
personality = "pragmatic"
approval_policy = "never"
sandbox_mode = "danger-full-access"
web_search = "cached"
approvals_reviewer = "user"
model_provider = "default"

[notice]
hide_full_access_warning = true

[sandbox_workspace_write]
network_access = true

[features]
multi_agent = false
unified_exec = false
collaboration_modes = false
steer = false
memories = false
apps = false
js_repl = false

[model_providers]

[model_providers.default]
name = "default"
base_url = "https://api.deepseek.com"
wire_api = "responses"
requires_openai_auth = false
experimental_bearer_token = "default"
EOF
  }

  install_codex_cli() {
    if ! command -v npm >/dev/null 2>&1; then
      install_nvm_lts_auto || return 1
    else
      load_nvm_env
    fi
    npm install -g @openai/codex@latest || return 1
    configure_codex_settings
    if ! command -v codex >/dev/null 2>&1; then
      echo "Codex 安装失败或 codex 命令不在 PATH"
      return 1
    fi
    codex --version
  }

  remove_codex_all() {
    load_nvm_env
    npm uninstall -g @openai/codex 2>/dev/null || true
    rm -f "$HOME/.codex/config.toml"
    rmdir "$HOME/.codex" 2>/dev/null || true
    reload_shell_configs_safely
    echo "已删除 Codex 和 ~/.codex/config.toml"
  }

  tool_installed() {
    local id="$1"
    case "$id" in
      vim) command -v vim >/dev/null 2>&1 && grep -qxF 'export EDITOR=vim' "$HOME/.bashrc" 2>/dev/null && grep -qxF 'export VISUAL=vim' "$HOME/.bashrc" 2>/dev/null ;;
      cpcat) grep -q '^# ========== cpcat clipboard setup ==========$' "$HOME/.bashrc" 2>/dev/null ;;
      ctrld) grep -q '^# ==================== Ctrl+D 改为删除下一个单词 ====================$' "$HOME/.bashrc" 2>/dev/null || grep -q '^bind '\''"\\C-d": kill-word'\''$' "$HOME/.bashrc" 2>/dev/null ;;
      starship) command -v starship >/dev/null 2>&1 && [ -f "$HOME/.config/starship.toml" ] ;;
      bat) (command -v batcat >/dev/null 2>&1 || command -v bat >/dev/null 2>&1) && [ -f "$HOME/.bat.sh" ] && grep -q '^# ========== bat 终端着色增强 ==========$' "$HOME/.bashrc" 2>/dev/null ;;
      ripgrep) command -v rg >/dev/null 2>&1 ;;
      fd) command -v fd >/dev/null 2>&1 || (command -v fdfind >/dev/null 2>&1 && grep -Eq "^alias fd=('fdfind'|\"fdfind\"|fdfind)$" "$HOME/.bashrc" 2>/dev/null) ;;
      fzf) [ -x "$DAIMON_FZF_DIR/bin/fzf" ] && grep -q '^# ========== fzf 核心配置 ==========$' "$HOME/.bashrc" 2>/dev/null ;;
      blesh) [ -f "$HOME/.local/share/blesh/ble.sh" ] && grep -q '^# ========== ble.sh setup ==========$' "$HOME/.bashrc" 2>/dev/null ;;
      python) python_312_is_default ;;
      npm) command -v npm >/dev/null 2>&1 ;;
      nodejs) command -v node >/dev/null 2>&1 ;;
      iptables-persistent) command -v netfilter-persistent >/dev/null 2>&1 || dpkg -s iptables-persistent >/dev/null 2>&1 ;;
      firewalld) command -v firewall-cmd >/dev/null 2>&1 ;;
      claude) command -v claude >/dev/null 2>&1 && [ -f "$HOME/.claude/settings.json" ] ;;
      codex) command -v codex >/dev/null 2>&1 && [ -f "$HOME/.codex/config.toml" ] ;;
      *) command -v "$id" >/dev/null 2>&1 ;;
    esac
  }

  show_tool_status() {
    echo -e "${gl_kjlan}------------------------${gl_bai}"
    for ((i=0; i<${#tool_ids[@]}; i++)); do
      local status="未安装"
      local color="$gl_hong"
      if tool_installed "${tool_ids[i]}"; then
        status="已安装"
        color="$gl_lv"
      fi
      printf "%2d. %-20s %-18s %b%s%b\n" "$((i+1))" "${tool_names[i]}" "${tool_desc[i]}" "$color" "$status" "$gl_bai"
    done
    echo -e "${gl_kjlan}------------------------${gl_bai}"
  }

  install_tool_by_id() {
    local id="$1"
    case "$id" in
      vim)
        if tool_installed vim || command -v vim >/dev/null 2>&1; then
          echo "vim 已安装，正在检查并设置默认编辑器..."
        else
          install vim || return 1
        fi
        configure_vim_editor
        vim --version 2>/dev/null | head -n 1 || true
        ;;
      cpcat)
        configure_cpcat
        ;;
      ctrld)
        configure_ctrld
        ;;
      starship)
        configure_starship
        ;;
      bat)
        configure_bat_terminal
        ;;
      ripgrep)
        install ripgrep || return 1
        rg --version 2>/dev/null | head -n 1 || true
        ;;
      fd)
        install fd-find || return 1
        configure_fd_alias
        fd --version 2>/dev/null || fdfind --version 2>/dev/null || true
        ;;
      fzf)
        configure_fzf
        ;;
      blesh)
        configure_blesh
        ;;
      python)
        install_python_312
        ;;
      npm|nodejs)
        install_nvm_lts_auto
        ;;
      bun)
        if tool_installed bun; then
          bun --version
        else
          install curl unzip || return 1
          daimon_run_cached_script "https://bun.sh/install" "bun-install.sh" || return 1
          export BUN_INSTALL="${BUN_INSTALL:-$HOME/.bun}"
          export PATH="$BUN_INSTALL/bin:$PATH"
          reload_shell_configs_safely
          bun --version 2>/dev/null || true
        fi
        ;;
      uv)
        if tool_installed uv; then
          uv --version
        else
          install curl || return 1
          daimon_run_cached_script "https://astral.sh/uv/install.sh" "uv-install.sh" || return 1
          export PATH="$HOME/.local/bin:$PATH"
          reload_shell_configs_safely
          uv --version 2>/dev/null || true
        fi
        ;;
      iptables-persistent)
        if command -v apt >/dev/null 2>&1; then
          DEBIAN_FRONTEND=noninteractive apt update -y && DEBIAN_FRONTEND=noninteractive apt install -y iptables-persistent
        elif command -v dnf >/dev/null 2>&1; then
          dnf install -y iptables-services
        elif command -v yum >/dev/null 2>&1; then
          yum install -y iptables-services
        else
          install iptables-persistent
        fi
        ;;
      ufw)
        install ufw
        ufw status 2>/dev/null || true
        ;;
      firewalld)
        install firewalld
        systemctl enable firewalld >/dev/null 2>&1 || true
        systemctl start firewalld >/dev/null 2>&1 || true
        firewall-cmd --state 2>/dev/null || true
        ;;
      yazi)
        install_yazi_griffo
        ;;
      nexttrace)
        install_nexttrace
        ;;
      git|curl|tree|wget|sudo|socat|htop|iftop|unzip|tar|tmux|ffmpeg|btop|ncdu|iperf3)
        install "$id" || return 1
        command -v "$id" >/dev/null 2>&1 && "$id" --version 2>/dev/null | head -n 1 || true
        ;;
      fail2ban)
        install fail2ban
        systemctl enable fail2ban >/dev/null 2>&1 || true
        systemctl start fail2ban >/dev/null 2>&1 || true
        fail2ban-client status 2>/dev/null || true
        ;;
      claude)
        install_claude_code_auto
        ;;
      codex)
        install_codex_cli
        ;;
      *) echo "未知工具: $id" ;;
    esac
  }

  remove_tool_by_id() {
    local id="$1"
    case "$id" in
      vim) remove_vim_editor_config; remove vim ;;
      cpcat) remove_cpcat_config; reload_bashrc_safely; echo "已删除 cpcat 配置" ;;
      ctrld) remove_ctrld_config; reload_bashrc_safely; echo "已删除 Ctrl+D 绑定" ;;
      starship) remove_starship_all ;;
      bat) remove_bat_all ;;
      btop) remove btop; rm -rf "$HOME/.config/btop" ;;
      yazi) remove_yazi_all ;;
      htop) remove htop; rm -rf "$HOME/.config/htop" "$HOME/.htoprc" ;;
      ripgrep) remove ripgrep ;;
      fd) remove_fd_alias; remove fd-find ;;
      fzf) remove_fzf_all ;;
      blesh) remove_blesh_all ;;
      nexttrace) remove_nexttrace_all ;;
      python) remove_python_312_all ;;
      npm|nodejs) remove_nvm_all ;;
      iptables-persistent) remove_iptables_persistent_all ;;
      ufw) remove_ufw_all ;;
      firewalld) remove_firewalld_all ;;
      fail2ban) remove_fail2ban_all ;;
      claude) remove_claude_code_all ;;
      codex) remove_codex_all ;;
      bun) rm -rf "$HOME/.bun"; sed -i '/bun\/bin/d' ~/.bashrc ~/.profile ~/.bash_profile 2>/dev/null || true; reload_shell_configs_safely ;;
      uv) rm -f "$HOME/.local/bin/uv" "$HOME/.local/bin/uvx"; reload_shell_configs_safely ;;
      *) remove "$id" ;;
    esac
  }

  handle_tool_numbers() {
    local action="$1"
    local input="$2"
    local n id failed=0
    for n in $input; do
      if ! [[ "$n" =~ ^[0-9]{1,3}$ ]] || [ "$n" -lt 1 ] || [ "$n" -gt ${#tool_ids[@]} ]; then
        echo "跳过无效编号: $n"
        failed=1
        continue
      fi
      id="${tool_ids[$((10#$n-1))]}"
      if [ "$action" = "install" ]; then
        if ! install_tool_by_id "$id" || ! tool_installed "$id"; then
          echo "工具安装或验证失败: $id"
          failed=1
        fi
      else
        remove_tool_by_id "$id" || failed=1
      fi
    done
    return "$failed"
  }

  all_tool_numbers() {
    seq 1 ${#tool_ids[@]} | tr '\n' ' '
  }

  tool_category_menu() {
    local category_key="$1"
    local category_title="$2"
    local tool_ids=()
    local tool_names=()
    local tool_desc=()

    case "$category_key" in
      thirdparty)
        tool_ids=("${thirdparty_ids[@]}")
        tool_names=("${thirdparty_names[@]}")
        tool_desc=("${thirdparty_desc[@]}")
        ;;
      programming)
        tool_ids=("${programming_ids[@]}")
        tool_names=("${programming_names[@]}")
        tool_desc=("${programming_desc[@]}")
        ;;
      *)
        echo "未知分类: $category_key"
        break_end
        return
        ;;
    esac

    while true; do
      clear
      echo -e "$category_title"
      show_tool_status
      echo -e "${gl_kjlan}1.   ${gl_bai}安装工具（支持多选，输入工具编号，如: 1 4 6）"
      echo -e "${gl_kjlan}2.   ${gl_bai}卸载工具（支持多选，输入工具编号，如: 7 10）"
      echo -e "${gl_kjlan}3.   ${gl_bai}全部安装"
      echo -e "${gl_kjlan}4.   ${gl_bai}全部卸载"
      echo -e "${gl_kjlan}0.   ${gl_bai}返回上一级菜单"
      echo -e "${gl_kjlan}------------------------${gl_bai}"
      read -e -p "请输入你的选择: " sub_choice || return 1
      case $sub_choice in
        1)
          read -e -p "请输入要安装的工具编号（支持多选，空格分隔）: " nums || return 1
          handle_tool_numbers install "$nums" && [ -n "$nums" ] && restart_shell_after_tool_install
          ;;
        2)
          read -e -p "请输入要卸载的工具编号（支持多选，空格分隔）: " nums || return 1
          handle_tool_numbers remove "$nums"
          ;;
        3)
          nums="$(all_tool_numbers)"
          read -e -i "$nums" -p "请确认/修改要安装的工具编号（默认全选，空格分隔）: " nums || return 1
          handle_tool_numbers install "$nums" && [ -n "$nums" ] && restart_shell_after_tool_install
          ;;
        4)
          nums="$(all_tool_numbers)"
          read -e -i "$nums" -p "请确认/修改要卸载的工具编号（默认全选，空格分隔）: " nums || return 1
          read -e -p "确认卸载以上编号对应工具？(y/N): " confirm || return 1
          if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
            handle_tool_numbers remove "$nums"
          else
            echo "已取消"
          fi
          ;;
        0) return ;;
        *) echo "无效的输入!" ;;
      esac
      break_end
    done
  }

  case "${1:-}" in
    thirdparty)
      tool_category_menu thirdparty "第三方工具"
      return
      ;;
    thirdparty-install-all)
      local tool_ids=("${thirdparty_ids[@]}")
      handle_tool_numbers install "$(seq 1 ${#tool_ids[@]} | tr '\n' ' ')" || return 1
      restart_shell_after_tool_install
      return
      ;;
    programming|basic)
      tool_category_menu programming "编程工具"
      return
      ;;
    programming-install-all)
      local tool_ids=("${programming_ids[@]}")
      handle_tool_numbers install "$(seq 1 ${#tool_ids[@]} | tr '\n' ' ')" || return 1
      restart_shell_after_tool_install
      return
      ;;
  esac

  while true; do
    clear
    echo -e "工具管理"
    echo -e "${gl_kjlan}1.   ${gl_bai}第三方工具"
    echo -e "${gl_kjlan}2.   ${gl_bai}编程工具"
    echo -e "${gl_kjlan}0.   ${gl_bai}返回主菜单"
    echo -e "${gl_kjlan}------------------------${gl_bai}"
    read -e -p "请输入你的选择: " sub_choice || return 1
    case $sub_choice in
      1) tool_category_menu thirdparty "第三方工具" ;;
      2) tool_category_menu programming "编程工具" ;;
      0) return ;;
      *) echo "无效的输入!"; break_end ;;
    esac
  done
}
