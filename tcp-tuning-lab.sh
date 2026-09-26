#!/usr/bin/env bash
# DAIMON_TCP_LAB_VERSION=1

daimon_tcp_lab_download_helpers() {
    local base="https://raw.githubusercontent.com/daimon3332/linux-tools-daimon/master" name target
    mkdir -p "$DAIMON_TCP_STATE_DIR" || return 1
    chmod 700 "$DAIMON_TCP_STATE_DIR" || return 1
    for name in tcp-tuning-control.py tcp-tuning-client.ps1 tcp-tuning-score.py; do
        target="$DAIMON_TCP_STATE_DIR/$name"
        daimon_download_to "$base/$name?cb=$(date +%s)" "$target" 60 || return 1
        chmod 600 "$target" || return 1
    done
    python3 -m py_compile "$DAIMON_TCP_STATE_DIR/tcp-tuning-control.py" "$DAIMON_TCP_STATE_DIR/tcp-tuning-score.py" || return 1
    command -v sha256sum >/dev/null 2>&1 || return 1
}

daimon_tcp_lab_control_open() {
    local port="$1" family="$2"
    DAIMON_TCP_LAB_FW="none"
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^Status: active'; then
        if ufw status 2>/dev/null | grep -qE "(^|[[:space:]])${port}/tcp([[:space:]]|$)"; then
            DAIMON_TCP_LAB_FW="existing"
        else
            ufw allow "$port/tcp" >/dev/null 2>&1 || return 1
            DAIMON_TCP_LAB_FW="ufw"
        fi
    elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        if firewall-cmd --query-port="$port/tcp" >/dev/null 2>&1; then
            DAIMON_TCP_LAB_FW="existing"
        else
            firewall-cmd --add-port="$port/tcp" >/dev/null 2>&1 || return 1
            DAIMON_TCP_LAB_FW="firewalld"
        fi
    elif command -v iptables >/dev/null 2>&1; then
        if [ "$family" = 6 ]; then
            if ! ip6tables -C INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1; then
                ip6tables -I INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1 || return 1
                DAIMON_TCP_LAB_FW="ip6tables"
            fi
        elif ! iptables -C INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1; then
            iptables -I INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1 || return 1
            DAIMON_TCP_LAB_FW="iptables"
        fi
    fi
}

daimon_tcp_lab_control_close() {
    local port="$1"
    case "$DAIMON_TCP_LAB_FW" in
        ufw) ufw delete allow "$port/tcp" >/dev/null 2>&1 || true ;;
        firewalld) firewall-cmd --remove-port="$port/tcp" >/dev/null 2>&1 || true ;;
        iptables) iptables -D INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1 || true ;;
        ip6tables) ip6tables -D INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1 || true ;;
    esac
    DAIMON_TCP_LAB_FW="none"
}

daimon_tcp_lab_capture() {
    local key
    : > "$DAIMON_TCP_LAB_DIR/runtime.conf" || return 1
    for key in "${DAIMON_TCP_MANAGED_KEYS[@]}"; do
        daimon_tcp_key_supported "$key" || continue
        printf '%s = %s\n' "$key" "$(daimon_tcp_read_key "$key")" >> "$DAIMON_TCP_LAB_DIR/runtime.conf" || return 1
    done
    if [ -f /etc/sysctl.conf ]; then
        cp -a /etc/sysctl.conf "$DAIMON_TCP_LAB_DIR/sysctl.conf.before" || return 1
    fi
    if [ -f "$DAIMON_TCP_TUNING_CONF" ]; then
        cp -a "$DAIMON_TCP_TUNING_CONF" "$DAIMON_TCP_LAB_DIR/tuning.conf.before" || return 1
    fi
    DAIMON_TCP_LAB_WMEM=$(daimon_tcp_read_key net.core.wmem_max)
    DAIMON_TCP_LAB_TCP_WMEM=$(daimon_tcp_read_key net.ipv4.tcp_wmem)
    [ -n "$DAIMON_TCP_LAB_WMEM" ] && [ -n "$DAIMON_TCP_LAB_TCP_WMEM" ]
}

daimon_tcp_lab_restore_runtime() {
    local key value failed=0
    while IFS='=' read -r key value; do
        key=$(printf '%s' "$key" | tr -d '[:space:]')
        value=$(printf '%s' "$value" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        [ -n "$key" ] && [ -n "$value" ] || continue
        [ "$(daimon_tcp_read_key "$key")" = "$value" ] && continue
        daimon_tcp_write_key "$key" "$value" || failed=1
    done < "$DAIMON_TCP_LAB_DIR/runtime.conf"
    return "$failed"
}

daimon_tcp_lab_apply_ceiling() {
    local ceiling="$1" min def old_max target_core target_tcp
    read -r min def old_max <<< "$DAIMON_TCP_LAB_TCP_WMEM"
    target_core="$DAIMON_TCP_LAB_WMEM"
    target_tcp="$old_max"
    [ "$ceiling" -gt "$target_core" ] && target_core="$ceiling"
    [ "$ceiling" -gt "$target_tcp" ] && target_tcp="$ceiling"
    daimon_tcp_write_key net.core.wmem_max "$target_core" || return 1
    daimon_tcp_write_key net.ipv4.tcp_wmem "$min $def $target_tcp" || return 1
    [ "$(daimon_tcp_read_key net.core.wmem_max)" = "$target_core" ] &&
        [ "$(daimon_tcp_read_key net.ipv4.tcp_wmem)" = "$min $def $target_tcp" ]
}

daimon_tcp_lab_candidate() {
    local rate="$1" rtt="$2" factor="$3" ram cap candidate old_max
    ram=$(daimon_tcp_ram_mb)
    cap=$((ram * 32768))
    [ "$cap" -gt 268435456 ] && cap=268435456
    [ "$cap" -lt 4194304 ] && cap=4194304
    candidate=$(awk -v rate="$rate" -v rtt="$rtt" -v factor="$factor" \
        'BEGIN{printf "%.0f", factor*rate*1000000/8*rtt/1000+2097152}')
    [ "$candidate" -gt "$cap" ] && candidate="$cap"
    [ "$candidate" -lt 4194304 ] && candidate=4194304
    old_max=${DAIMON_TCP_LAB_TCP_WMEM##* }
    if [ "$candidate" -le "$old_max" ] && [ "$candidate" -le "$DAIMON_TCP_LAB_WMEM" ]; then
        return 1
    fi
    printf '%s\n' "$candidate"
}

daimon_tcp_lab_stage_json() {
    local state="$1" id="$2" family="$3" host="$4" message="${5:-}"
    local tmp="$DAIMON_TCP_LAB_DIR/stage.json.new"
    printf '{"state":"%s","id":%d,"family":%d,"host":"%s","port":%d,"duration":%d,"omit":%d,"message":"%s"}\n' \
        "$state" "$id" "$family" "$host" "$DAIMON_TCP_LAB_PORT" \
        "$DAIMON_TCP_LAB_DURATION" "$DAIMON_TCP_LAB_OMIT" "$message" > "$tmp" || return 1
    mv -f "$tmp" "$DAIMON_TCP_LAB_DIR/stage.json"
}

daimon_tcp_lab_round() {
    local label="$1" family="$2" host pid log result rate bytes retrans rtt sample status deadline
    DAIMON_TCP_LAB_ROUND=$((DAIMON_TCP_LAB_ROUND + 1))
    [ "$family" = 4 ] && host="$DAIMON_TCP_LAB_IP4" || host="$DAIMON_TCP_LAB_IP6"
    log="$DAIMON_TCP_LAB_DIR/iperf-$DAIMON_TCP_LAB_ROUND.log"
    result="$DAIMON_TCP_LAB_DIR/result-$DAIMON_TCP_LAB_ROUND.json"
    daimon_tcp_lab_stage_json ready "$DAIMON_TCP_LAB_ROUND" "$family" "$host" || return 1
    iperf3 -s -1 -p "$DAIMON_TCP_LAB_PORT" --forceflush > "$log" 2>&1 &
    pid=$!
    deadline=$((SECONDS + DAIMON_TCP_LAB_WAIT))
    rtt=""
    local exited_at=""
    while [ "$SECONDS" -lt "$deadline" ]; do
        if [ -s "$DAIMON_TCP_LAB_DIR/abort.json" ]; then
            echo "客户端中止测速：$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["reason"])' "$DAIMON_TCP_LAB_DIR/abort.json")" >&2
            break
        fi
        sample=$(ss -tin state established "( sport = :$DAIMON_TCP_LAB_PORT )" 2>/dev/null |
            grep -o 'minrtt:[0-9.]*' | cut -d: -f2 | sort -n | head -1)
        if [ -n "$sample" ]; then
            if [ -z "$rtt" ] || awk -v a="$sample" -v b="$rtt" 'BEGIN{exit !(a < b)}'; then
                rtt="$sample"
            fi
        fi
        if [ -s "$result" ]; then
            break
        fi
        if ! kill -0 "$pid" 2>/dev/null; then
            [ -n "$exited_at" ] || exited_at=$SECONDS
            [ "$SECONDS" -ge "$((exited_at + 15))" ] && break
        fi
        sleep 1
    done
    [ -n "$exited_at" ] || kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    daimon_tcp_lab_stage_json processing "$DAIMON_TCP_LAB_ROUND" "$family" "$host" || true
    if [ ! -s "$result" ]; then
        echo "第 $DAIMON_TCP_LAB_ROUND 轮没有收到本地接收端结果。" >&2
        return 1
    fi
    read -r rate bytes retrans < <(python3 - "$result" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding='utf-8'))
print(data['receiver_mbps'], data['bytes'], data['retrans'])
PY
    )
    [ -n "$rtt" ] || rtt=0
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$label" "$family" "$rate" "$retrans" "$bytes" "$rtt" >> "$DAIMON_TCP_LAB_DIR/records.tsv"
    printf '  %-8s IPv%s receiver %s Mbps, retrans %s, min RTT %s ms\n' "$label" "$family" "$rate" "$retrans" "$rtt"
}

daimon_tcp_lab_profile_round() {
    local profile="$1" ceiling="$2" family
    if [ "$profile" = A ]; then
        daimon_tcp_lab_restore_runtime || return 1
    else
        daimon_tcp_lab_apply_ceiling "$ceiling" || return 1
    fi
    sleep 2
    for family in $DAIMON_TCP_LAB_FAMILIES; do
        daimon_tcp_lab_round "$profile" "$family" || return 1
    done
}

daimon_tcp_lab_score() {
    local phase="$1" profiles="$2" ceilings="${3:-}"
    python3 "$DAIMON_TCP_STATE_DIR/tcp-tuning-score.py" "$phase" \
        "$DAIMON_TCP_LAB_DIR/records.tsv" "${DAIMON_TCP_LAB_FAMILIES// /,}" \
        "$profiles" "$ceilings"
}

daimon_tcp_lab_persist() {
    local ceiling="$1" min def old_max target_core target_tcp file="$DAIMON_TCP_LAB_DIR/winner.conf"
    read -r min def old_max <<< "$DAIMON_TCP_LAB_TCP_WMEM"
    target_core="$DAIMON_TCP_LAB_WMEM"
    target_tcp="$old_max"
    [ "$ceiling" -gt "$target_core" ] && target_core="$ceiling"
    [ "$ceiling" -gt "$target_tcp" ] && target_tcp="$ceiling"
    cat > "$file" <<EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.wmem_max = $target_core
net.ipv4.tcp_wmem = $min $def $target_tcp
EOF
    DAIMON_NETWORK_PRIORITY_CONF="$DAIMON_TCP_TUNING_CONF" daimon_network_persist "$file" || return 1
    sysctl --system >/dev/null 2>&1 || return 1
    daimon_network_verify_sysctl_file "$DAIMON_TCP_TUNING_CONF" || return 1
    [ "$(daimon_tcp_read_key net.core.wmem_max)" = "$target_core" ] &&
        [ "$(daimon_tcp_read_key net.ipv4.tcp_wmem)" = "$min $def $target_tcp" ] || return 1
    echo "已验证优化参数在 sysctl --system 后仍生效。"
}

daimon_tcp_lab_restore_files() {
    if [ -f "$DAIMON_TCP_LAB_DIR/sysctl.conf.before" ]; then
        cp -a "$DAIMON_TCP_LAB_DIR/sysctl.conf.before" /etc/sysctl.conf || return 1
    fi
    if [ -f "$DAIMON_TCP_LAB_DIR/tuning.conf.before" ]; then
        cp -a "$DAIMON_TCP_LAB_DIR/tuning.conf.before" "$DAIMON_TCP_TUNING_CONF" || return 1
    else
        rm -f "$DAIMON_TCP_TUNING_CONF" || return 1
    fi
    daimon_tcp_lab_restore_runtime
}

daimon_tcp_lab_finish() {
    local status="$1" message="$2"
    daimon_tcp_lab_stage_json "$status" "$DAIMON_TCP_LAB_ROUND" 4 "$DAIMON_TCP_LAB_IP4" "$message" || true
    sleep 2
}

daimon_tcp_lab_run_inner() {
    local mode="$1" family="$2" ip candidate profile score_status winner ceiling
    local -a candidates=() profiles=()
    local scorer profile_list ceiling_list f rate rtt factor result
    DAIMON_TCP_LAB_DIR=$(mktemp -d "$DAIMON_TCP_STATE_DIR/session.XXXXXX") || return 1
    chmod 700 "$DAIMON_TCP_LAB_DIR" || return 1
    DAIMON_TCP_LAB_PORT="${DAIMON_TCP_IPERF3_PORT:-50280}"
    DAIMON_TCP_LAB_CONTROL_PORT="${DAIMON_TCP_CONTROL_PORT:-50281}"
    DAIMON_TCP_LAB_DURATION="${DAIMON_TCP_LAB_DURATION:-12}"
    DAIMON_TCP_LAB_OMIT="${DAIMON_TCP_LAB_OMIT:-2}"
    DAIMON_TCP_LAB_WAIT="${DAIMON_TCP_LAB_WAIT:-240}"
    DAIMON_TCP_LAB_ROUND=0
    DAIMON_TCP_LAB_FAMILIES="$family"
    [ "$family" = both ] && DAIMON_TCP_LAB_FAMILIES="4 6"
    if [ "$mode" != test ]; then
        daimon_network_bbr_supported || { echo "当前内核不支持 BBR，未修改配置。"; return 1; }
        if [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" != bbr ] ||
            [ "$(sysctl -n net.core.default_qdisc 2>/dev/null)" != fq ]; then
            echo "请先启用 BBR + FQ，再比较 TCP 缓冲候选，避免算法变化污染测速结果。"
            return 1
        fi
    fi
    DAIMON_TCP_LAB_IP4=""
    DAIMON_TCP_LAB_IP6=""
    for ip in $(daimon_tcp_public_ips); do
        case "$ip" in *:*) [ -n "$DAIMON_TCP_LAB_IP6" ] || DAIMON_TCP_LAB_IP6="$ip" ;;
            *) [ -n "$DAIMON_TCP_LAB_IP4" ] || DAIMON_TCP_LAB_IP4="$ip" ;; esac
    done
    for f in $DAIMON_TCP_LAB_FAMILIES; do
        if { [ "$f" = 4 ] && [ -z "$DAIMON_TCP_LAB_IP4" ]; } ||
            { [ "$f" = 6 ] && [ -z "$DAIMON_TCP_LAB_IP6" ]; }; then
            echo "缺少 IPv$f 公网地址，未修改配置。"
            return 1
        fi
    done
    daimon_tcp_lab_capture || return 1
    DAIMON_TCP_LAB_CAPTURED=1
    while ss -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${DAIMON_TCP_LAB_PORT}$"; do
        DAIMON_TCP_LAB_PORT=$((DAIMON_TCP_LAB_PORT + 1))
    done
    local control_ip="$DAIMON_TCP_LAB_IP4" bind=0.0.0.0 control_family=4
    if [ -z "$control_ip" ]; then
        control_ip="$DAIMON_TCP_LAB_IP6"; bind="::"; control_family=6
    fi
    while ss -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${DAIMON_TCP_LAB_CONTROL_PORT}$"; do
        DAIMON_TCP_LAB_CONTROL_PORT=$((DAIMON_TCP_LAB_CONTROL_PORT + 1))
    done
    daimon_tcp_lab_control_open "$DAIMON_TCP_LAB_CONTROL_PORT" "$control_family" || return 1
    DAIMON_TCP_LAB_CONTROL_OPEN=1
    daimon_tcp_fw_open "$DAIMON_TCP_LAB_PORT" || return 1
    local token client_hash endpoint helper_pid
    token=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
    client_hash=$(sha256sum "$DAIMON_TCP_STATE_DIR/tcp-tuning-client.ps1" | awk '{print $1}')
    endpoint="http://$control_ip:$DAIMON_TCP_LAB_CONTROL_PORT"
    [ "$control_family" = 6 ] && endpoint="http://[$control_ip]:$DAIMON_TCP_LAB_CONTROL_PORT"
    daimon_tcp_lab_stage_json waiting 0 4 "$control_ip" || return 1
    python3 "$DAIMON_TCP_STATE_DIR/tcp-tuning-control.py" \
        --bind "$bind" --port "$DAIMON_TCP_LAB_CONTROL_PORT" \
        --token "$token" --state-dir "$DAIMON_TCP_LAB_DIR" \
        --client "$DAIMON_TCP_STATE_DIR/tcp-tuning-client.ps1" \
        > "$DAIMON_TCP_LAB_DIR/control.log" 2>&1 &
    helper_pid=$!
    DAIMON_TCP_LAB_HELPER_PID="$helper_pid"
    sleep 1
    kill -0 "$helper_pid" 2>/dev/null || { cat "$DAIMON_TCP_LAB_DIR/control.log"; return 1; }
    echo "请在本地 PowerShell 粘贴以下整行命令，仅需执行一次："
    printf "\$u='%s';\$t='%s';\$w=New-Object Net.WebClient;\$w.Proxy=\$null;\$s=\$w.DownloadString(\"\$u/client?token=\$t\");\$h=[BitConverter]::ToString(([Security.Cryptography.SHA256]::Create()).ComputeHash([Text.Encoding]::UTF8.GetBytes(\$s))).Replace('-','').ToLower();if(\$h -ne '%s'){throw 'Client hash mismatch'};& ([ScriptBlock]::Create(\$s)) -Control \$u -Token \$t\n" \
        "$endpoint" "$token" "$client_hash"
    echo "客户端最多接收 4 GiB；本次会运行多个独立连接，不需要手动重复输入命令。"

    local rc=0
    daimon_tcp_lab_execute "$mode" || rc=$?
    [ "$rc" -eq 0 ] && daimon_tcp_lab_finish done "TCP test completed" || {
        daimon_tcp_lab_finish error "TCP test failed; restoring original settings"
    }
    return "$rc"
}

daimon_tcp_lab_cleanup() {
    local status="$1"
    if [ "$status" -ne 0 ] && [ "${DAIMON_TCP_LAB_CAPTURED:-0}" = 1 ]; then
        daimon_tcp_lab_restore_files || echo "自动恢复不完整，快照保留在 $DAIMON_TCP_LAB_DIR" >&2
    fi
    if [ -n "${DAIMON_TCP_LAB_HELPER_PID:-}" ]; then
        kill "$DAIMON_TCP_LAB_HELPER_PID" 2>/dev/null || true
        wait "$DAIMON_TCP_LAB_HELPER_PID" 2>/dev/null || true
    fi
    if [ "${DAIMON_TCP_LAB_CONTROL_OPEN:-0}" = 1 ]; then
        daimon_tcp_lab_control_close "$DAIMON_TCP_LAB_CONTROL_PORT"
    fi
    if [ "$status" -eq 0 ]; then
        [ -f "$DAIMON_TCP_LAB_DIR/records.tsv" ] &&
            cp -f "$DAIMON_TCP_LAB_DIR/records.tsv" "$DAIMON_TCP_STATE_DIR/last-rounds.tsv" 2>/dev/null || true
        case "${DAIMON_TCP_LAB_DIR:-}" in
            "$DAIMON_TCP_STATE_DIR"/session.*) rm -rf -- "$DAIMON_TCP_LAB_DIR" ;;
        esac
    fi
}

daimon_tcp_lab_run() {
    local status=0
    DAIMON_TCP_LAB_CAPTURED=0
    DAIMON_TCP_LAB_CONTROL_OPEN=0
    DAIMON_TCP_LAB_HELPER_PID=""
    daimon_tcp_lab_run_inner "$@" || status=$?
    daimon_tcp_lab_cleanup "$status"
    return "$status"
}

daimon_tcp_lab_execute() {
    local mode="$1" f rate rtt retrans candidate factor ceiling profile score_status scorer winner
    local profile_list="" ceiling_list="" choice
    local best_bdp="" best_rate="" best_rtt=""
    : > "$DAIMON_TCP_LAB_DIR/records.tsv"
    daimon_tcp_lab_profile_round A 0 || return 1
    if [ "$mode" = test ]; then
        for f in $DAIMON_TCP_LAB_FAMILIES; do
            read -r rate retrans rtt < <(awk -F '\t' -v f="$f" '$1=="A" && $2==f {print $3, $4, $6}' "$DAIMON_TCP_LAB_DIR/records.tsv")
            daimon_tcp_record_family "$f" "$rate" "$rtt" "$retrans"
        done
        echo "iperf3 本地测试完成；未修改任何 sysctl 参数。"
        return 0
    fi
    for f in $DAIMON_TCP_LAB_FAMILIES; do
        read -r rate rtt < <(awk -F '\t' -v f="$f" '$1=="A" && $2==f {print $3, $6}' "$DAIMON_TCP_LAB_DIR/records.tsv")
        if [ "$rtt" = 0 ] || [ -z "$rtt" ]; then
            echo "IPv$f 未测到真实 RTT，不能安全计算 BDP。" >&2
            return 1
        fi
        if [ "$mode" = separate ]; then
            for factor in 2; do
                candidate=$(daimon_tcp_lab_candidate "$rate" "$rtt" "$factor") || continue
                case " $ceiling_list " in *" $candidate "*) continue ;; esac
                profile="B$(( ${#candidates[@]} + 1 ))"
                candidates+=("$candidate"); profiles+=("$profile")
                ceiling_list="$ceiling_list $candidate"
            done
        else
            if [ -z "${best_bdp:-}" ] || awk -v a="$rate" -v r="$rtt" -v b="$best_bdp" 'BEGIN{exit !(a*r > b)}'; then
                best_bdp=$(awk -v a="$rate" -v r="$rtt" 'BEGIN{print a*r}')
                best_rate="$rate"; best_rtt="$rtt"
            fi
        fi
    done
    if [ "$mode" != separate ]; then
        for factor in 2 4; do
            candidate=$(daimon_tcp_lab_candidate "$best_rate" "$best_rtt" "$factor") || continue
            case " $ceiling_list " in *" $candidate "*) continue ;; esac
            profile="B$(( ${#candidates[@]} + 1 ))"
            candidates+=("$candidate"); profiles+=("$profile")
            ceiling_list="$ceiling_list $candidate"
        done
    fi
    if [ "${#candidates[@]}" -eq 0 ]; then
        echo "当前发送缓冲上限已覆盖 BDP 候选；不降低现有值，保留原配置。"
        return 0
    fi
    local i
    for ((i=0; i<${#candidates[@]}; i++)); do
        echo "探索 ${profiles[i]}: 发送缓冲上限候选 ${candidates[i]} 字节"
        daimon_tcp_lab_profile_round "${profiles[i]}" "${candidates[i]}" || return 1
    done
    daimon_tcp_lab_profile_round A 0 || return 1
    profile_list=$(IFS=,; echo "${profiles[*]}")
    ceiling_list=$(IFS=,; echo "${candidates[*]}")
    scorer=$(daimon_tcp_lab_score choose "$profile_list" "$ceiling_list") || return 1
    score_status=$(python3 -c 'import json,sys;print(json.load(sys.stdin)["status"])' <<< "$scorer")
    if [ "$score_status" != candidate ]; then
        echo "探索结论: $score_status；线路波动或收益不足，保留原配置。"
        return 0
    fi
    winner=$(python3 -c 'import json,sys;print(json.load(sys.stdin)["profile"])' <<< "$scorer")
    ceiling=$(python3 -c 'import json,sys;print(json.load(sys.stdin)["ceiling"])' <<< "$scorer")
    echo "确认候选 $winner（上限 $ceiling 字节）"
    daimon_tcp_lab_profile_round "$winner" "$ceiling" || return 1
    scorer=$(daimon_tcp_lab_score confirm "$winner") || return 1
    score_status=$(python3 -c 'import json,sys;print(json.load(sys.stdin)["status"])' <<< "$scorer")
    if [ "$score_status" != keep ]; then
        echo "确认轮未重复获得收益，恢复原配置。"
        return 0
    fi
    daimon_tcp_snapshot || return 1
    if ! daimon_tcp_lab_persist "$ceiling"; then
        echo "持久化或重载验证失败，恢复本次开始时的配置。" >&2
        return 1
    fi
    for f in $DAIMON_TCP_LAB_FAMILIES; do
        rate=$(awk -F '\t' -v p="$winner" -v f="$f" '$1==p && $2==f {v=$3} END {print v}' "$DAIMON_TCP_LAB_DIR/records.tsv")
        rtt=$(awk -F '\t' -v p="$winner" -v f="$f" '$1==p && $2==f {v=$6} END {print v}' "$DAIMON_TCP_LAB_DIR/records.tsv")
        retrans=$(awk -F '\t' -v p="$winner" -v f="$f" '$1==p && $2==f {v=$4} END {print v}' "$DAIMON_TCP_LAB_DIR/records.tsv")
        daimon_tcp_record_family "$f" "$rate" "$rtt" "$retrans"
    done
    echo "多轮确认通过：保留 $winner（发送缓冲上限 $ceiling 字节）。"
}
