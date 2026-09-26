#!/usr/bin/env bash
# DAIMON_TCP_LAB_VERSION=2

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
    DAIMON_TCP_LAB_SYSCTL_PRESENT=0
    if [ -f "${DAIMON_SYSCTL_CONF:-/etc/sysctl.conf}" ]; then
        DAIMON_TCP_LAB_SYSCTL_PATH=$(readlink -f "${DAIMON_SYSCTL_CONF:-/etc/sysctl.conf}") || return 1
        cp -a "$DAIMON_TCP_LAB_SYSCTL_PATH" "$DAIMON_TCP_LAB_DIR/sysctl.conf.before" || return 1
        DAIMON_TCP_LAB_SYSCTL_PRESENT=1
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
        [ "$(daimon_tcp_read_key "$key")" = "$value" ] || failed=1
    done < "$DAIMON_TCP_LAB_DIR/runtime.conf"
    return "$failed"
}

daimon_tcp_lab_wmem_triple() {
    local ceiling="$1" min def
    read -r min def _ <<< "$DAIMON_TCP_LAB_TCP_WMEM"
    [ "$min" -ge 4096 ] || min=4096
    [ "$ceiling" -ge "$min" ] || return 1
    [ "$def" -lt "$min" ] && def="$min"
    [ "$def" -gt "$ceiling" ] && def="$ceiling"
    printf '%s %s %s\n' "$min" "$def" "$ceiling"
}

daimon_tcp_lab_apply_ceiling() {
    local ceiling="$1" triple
    triple=$(daimon_tcp_lab_wmem_triple "$ceiling") || return 1
    daimon_tcp_write_key net.core.wmem_max "$ceiling" || return 1
    daimon_tcp_write_key net.ipv4.tcp_wmem "$triple" || return 1
    [ "$(daimon_tcp_read_key net.core.wmem_max)" = "$ceiling" ] &&
        [ "$(daimon_tcp_read_key net.ipv4.tcp_wmem)" = "$triple" ]
}

daimon_tcp_lab_cap() {
    local ram cap
    ram=$(daimon_tcp_ram_mb)
    cap=$((ram * 32768))
    [ "$cap" -gt 268435456 ] && cap=268435456
    [ "$cap" -lt 4194304 ] && cap=4194304
    printf '%s\n' "$cap"
}

daimon_tcp_lab_target() {
    local rate="$1" rtt="$2" factor="$3" cap value
    cap=$(daimon_tcp_lab_cap)
    value=$(awk -v rate="$rate" -v rtt="$rtt" -v factor="$factor" \
        'BEGIN{printf "%.0f", factor*rate*1000000/8*rtt/1000+2097152}')
    [ "$value" -gt "$cap" ] && value="$cap"
    [ "$value" -lt 4194304 ] && value=4194304
    printf '%s\n' "$value"
}

daimon_tcp_lab_current_ceiling() {
    local min def old_max
    read -r min def old_max <<< "$DAIMON_TCP_LAB_TCP_WMEM"
    [ "$old_max" -lt "$DAIMON_TCP_LAB_WMEM" ] && old_max="$DAIMON_TCP_LAB_WMEM"
    printf '%s\n' "$old_max"
}

# 与当前上限的相对差异达到 25% 才值得再花一轮测速。
daimon_tcp_lab_distinct() {
    awk -v a="$1" -v b="$2" 'BEGIN{exit !(b > 0 && ((a>b?a-b:b-a)/b) >= 0.25)}'
}

# 以实测 BDP 生成候选阶梯：现有上限偏低时给出上调候选，明显偏高时给出下调候选。
# 候选是否保留完全由多轮实测决定，绝不按理论值直接写入。
daimon_tcp_lab_candidate_list() {
    local rate="$1" rtt="$2" current cap target wider middle value seen out="" skip
    current="${3:-$(daimon_tcp_lab_current_ceiling)}"
    cap=$(daimon_tcp_lab_cap)
    target=$(daimon_tcp_lab_target "$rate" "$rtt" 2) || return 1
    wider=$(daimon_tcp_lab_target "$rate" "$rtt" 4) || return 1
    middle=$((current / 2))
    set -- "$target" "$middle" "$wider" "$((current * 2))"
    for value in "$@"; do
        [ "$value" -gt "$cap" ] && value="$cap"
        [ "$value" -lt 4194304 ] && value=4194304
        daimon_tcp_lab_distinct "$value" "$current" || continue
        skip=0
        for seen in $out; do
            daimon_tcp_lab_distinct "$value" "$seen" || skip=1
        done
        if [ "$skip" -eq 1 ]; then
            continue
        fi
        out="$out $value"
    done
    [ -n "$out" ] || return 1
    printf '%s\n' "${out# }"
}

daimon_tcp_lab_tx_bytes() {
    local file value total=0 count=0
    for file in /sys/class/net/*/statistics/tx_bytes; do
        case "$file" in */lo/*) continue ;; esac
        read -r value < "$file" 2>/dev/null || continue
        [[ "$value" =~ ^[0-9]+$ ]] || return 1
        total=$((total + value)); count=$((count + 1))
    done
    [ "$count" -gt 0 ] || return 1
    printf '%s\n' "$total"
}

daimon_tcp_lab_budget_used() {
    local now
    now=$(daimon_tcp_lab_tx_bytes) || return 1
    [ "$now" -ge "$DAIMON_TCP_LAB_TX_START" ] || return 1
    printf '%s\n' "$((now - DAIMON_TCP_LAB_TX_START))"
}

daimon_tcp_lab_can_afford() {
    local profiles="$1" used estimate
    used=$(daimon_tcp_lab_budget_used) || return 1
    estimate=$(awk -F '\t' -v n="$profiles" -v t="$((DAIMON_TCP_LAB_DURATION + DAIMON_TCP_LAB_OMIT))" \
        '{if ($3>peak[$2]) peak[$2]=$3} END {for(f in peak) sum+=peak[f]; printf "%.0f", sum*1000000/8*t*n*1.35}' "$DAIMON_TCP_LAB_DIR/records.tsv")
    [ "$((used + estimate + 536870912))" -lt "$DAIMON_TCP_LAB_BUDGET" ]
}

daimon_tcp_lab_stage_json() {
    local state="$1" id="$2" family="$3" host="$4" message="${5:-}"
    local tmp="$DAIMON_TCP_LAB_DIR/stage.json.new"
    printf '{"state":"%s","id":%d,"family":%d,"host":"%s","port":%d,"duration":%d,"omit":%d,"budget_bytes":%d,"message":"%s"}\n' \
        "$state" "$id" "$family" "$host" "$DAIMON_TCP_LAB_PORT" \
        "$DAIMON_TCP_LAB_DURATION" "$DAIMON_TCP_LAB_OMIT" "${DAIMON_TCP_LAB_BUDGET:-20000000000}" "$message" > "$tmp" || return 1
    mv -f "$tmp" "$DAIMON_TCP_LAB_DIR/stage.json"
}

daimon_tcp_lab_round() {
    local label="$1" family="$2" host pid log result rate bytes retrans rtt sample deadline used ticks=0 peer stopped=0
    DAIMON_TCP_LAB_ROUND=$((DAIMON_TCP_LAB_ROUND + 1))
    [ "$family" = 4 ] && host="$DAIMON_TCP_LAB_IP4" || host="$DAIMON_TCP_LAB_IP6"
    log="$DAIMON_TCP_LAB_DIR/iperf-$DAIMON_TCP_LAB_ROUND.log"
    result="$DAIMON_TCP_LAB_DIR/result-$DAIMON_TCP_LAB_ROUND.json"
    iperf3 -s -1 -p "$DAIMON_TCP_LAB_PORT" "-$family" --forceflush > "$log" 2>&1 &
    pid=$!
    DAIMON_TCP_LAB_IPERF_PID="$pid"
    sleep 1
    kill -0 "$pid" 2>/dev/null || { cat "$log" >&2; return 1; }
    daimon_tcp_lab_stage_json ready "$DAIMON_TCP_LAB_ROUND" "$family" "$host" "$label" || return 1
    deadline=$((SECONDS + DAIMON_TCP_LAB_WAIT))
    rtt=""
    local exited_at=""
    while [ "$SECONDS" -lt "$deadline" ]; do
        used=$(daimon_tcp_lab_budget_used) || { echo "无法可靠读取出口流量计数，停止测速。" >&2; stopped=1; break; }
        if [ "$used" -ge "$((DAIMON_TCP_LAB_BUDGET - 536870912))" ]; then
            echo "接近 20 GB 流量预算，停止测速并恢复原配置。" >&2
            stopped=1
            break
        fi
        if [ -s "$DAIMON_TCP_LAB_DIR/abort.json" ]; then
            echo "客户端中止测速：$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["reason"])' "$DAIMON_TCP_LAB_DIR/abort.json")" >&2
            stopped=1
            break
        fi
        if [ "$((ticks % 5))" -eq 0 ]; then
        sample=$(ss -tin state established "( sport = :$DAIMON_TCP_LAB_PORT )" 2>/dev/null |
            grep -o 'minrtt:[0-9.]*' | cut -d: -f2 | sort -n | head -1)
        if [ -n "$sample" ]; then
            if [ -z "$rtt" ] || awk -v a="$sample" -v b="$rtt" 'BEGIN{exit !(a < b)}'; then
                rtt="$sample"
            fi
        fi
        fi
        if [ -s "$result" ]; then
            break
        fi
        if ! kill -0 "$pid" 2>/dev/null; then
            [ -n "$exited_at" ] || exited_at=$SECONDS
            [ "$SECONDS" -ge "$((exited_at + 15))" ] && break
        fi
        ticks=$((ticks + 1))
        sleep 0.2
    done
    [ -n "$exited_at" ] || kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    DAIMON_TCP_LAB_IPERF_PID=""
    [ "$stopped" = 0 ] || return 1
    daimon_tcp_lab_stage_json processing "$DAIMON_TCP_LAB_ROUND" "$family" "$host" || true
    if [ ! -s "$result" ]; then
        echo "第 $DAIMON_TCP_LAB_ROUND 轮没有收到本地接收端结果。" >&2
        return 1
    fi
    read -r rate bytes retrans peer < <(python3 - "$result" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding='utf-8'))
print(data['receiver_mbps'], data['bytes'], data['retrans'], data.get('client', '-'))
PY
    )
    [ -n "$rtt" ] || rtt=0
    [ -n "$rate" ] && [ -n "$bytes" ] && [ -n "$retrans" ] || return 1
    DAIMON_TCP_LAB_CLIENT="$peer"
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
    local ceiling="$1" min def target_core target_tcp triple file="$DAIMON_TCP_LAB_DIR/winner.conf"
    triple=$(daimon_tcp_lab_wmem_triple "$ceiling") || return 1
    read -r min def target_tcp <<< "$triple"
    target_core="$ceiling"
    cat > "$file" <<EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.wmem_max = $target_core
net.ipv4.tcp_wmem = $min $def $target_tcp
EOF
    DAIMON_NETWORK_MERGE_EXISTING=1 DAIMON_NETWORK_PRIORITY_CONF="$DAIMON_TCP_TUNING_CONF" daimon_network_persist "$file" || return 1
    sysctl --system >/dev/null 2>&1 || return 1
    daimon_network_verify_sysctl_file "$DAIMON_TCP_TUNING_CONF" || return 1
    [ "$(daimon_tcp_read_key net.core.wmem_max)" = "$target_core" ] &&
        [ "$(daimon_tcp_read_key net.ipv4.tcp_wmem)" = "$min $def $target_tcp" ] || return 1
    echo "已验证优化参数在 sysctl --system 后仍生效。"
}

daimon_tcp_lab_restore_files() {
    if [ -f "$DAIMON_TCP_LAB_DIR/sysctl.conf.before" ]; then
        cp -a "$DAIMON_TCP_LAB_DIR/sysctl.conf.before" "${DAIMON_TCP_LAB_SYSCTL_PATH:-${DAIMON_SYSCTL_CONF:-/etc/sysctl.conf}}" || return 1
    elif [ "${DAIMON_TCP_LAB_SYSCTL_PRESENT:-1}" = 0 ]; then
        rm -f -- "${DAIMON_SYSCTL_CONF:-/etc/sysctl.conf}" || return 1
    fi
    if [ -f "$DAIMON_TCP_LAB_DIR/tuning.conf.before" ]; then
        cp -a "$DAIMON_TCP_LAB_DIR/tuning.conf.before" "$DAIMON_TCP_TUNING_CONF" || return 1
    else
        rm -f "$DAIMON_TCP_TUNING_CONF" || return 1
    fi
    return 0
}

daimon_tcp_lab_save_snapshot() {
    [ -s "$DAIMON_TCP_SNAPSHOT" ] && return 0
    local tmp
    tmp=$(mktemp "$DAIMON_TCP_STATE_DIR/.snapshot.XXXXXX") || return 1
    if ! cp -f "$DAIMON_TCP_LAB_DIR/runtime.conf" "$tmp" || ! chmod 600 "$tmp" ||
        ! mv -f "$tmp" "$DAIMON_TCP_SNAPSHOT"; then
        rm -f -- "$tmp"
        return 1
    fi
    DAIMON_TCP_LAB_NEW_SNAPSHOT=1
}

daimon_tcp_lab_save_report() {
    local status="$1" used
    [ -s "${DAIMON_TCP_LAB_DIR:-}/records.tsv" ] || return 0
    used=$(daimon_tcp_lab_budget_used) || used=0
    python3 - "$DAIMON_TCP_LAB_DIR/records.tsv" "$DAIMON_TCP_PROFILE" "$status" \
        "${DAIMON_TCP_LAB_COMMITTED:-0}" "${DAIMON_TCP_LAB_WINNER:-A}" \
        "${DAIMON_TCP_LAB_WINNING_CEILING:-0}" "$used" <<'PY'
import json, os, statistics, sys
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
data = defaultdict(lambda: defaultdict(list))
for line in Path(sys.argv[1]).read_text().splitlines():
    profile, family, rate, *_ = line.split('\t')
    data[profile][family].append(float(rate))
kept = sys.argv[4] == '1'
winner = sys.argv[5] if kept else 'A'
families = {f: {'baseline_mbps': statistics.median(data['A'][f]),
                'retained_mbps': min(rates[-2:]) if kept else statistics.median(rates)}
            for f, rates in data[winner].items()}
report = {'method': 'iperf3', 'status': 'applied' if kept else ('restored' if sys.argv[3] == '0' else 'error'),
          'profile': winner, 'ceiling_bytes': int(sys.argv[6]), 'families': families,
          'outgoing_bytes': int(sys.argv[7]), 'budget_bytes': 20000000000,
          'timestamp': datetime.now(timezone.utc).isoformat()}
target = Path(sys.argv[2])
temporary = target.with_suffix('.new')
temporary.write_text(json.dumps(report, indent=2) + '\n')
os.chmod(temporary, 0o600)
os.replace(temporary, target)
PY
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
    DAIMON_TCP_LAB_BUDGET="${DAIMON_TCP_LAB_BUDGET:-20000000000}"
    [[ "$DAIMON_TCP_LAB_BUDGET" =~ ^[0-9]+$ ]] && [ "$DAIMON_TCP_LAB_BUDGET" -le 20000000000 ] &&
        [ "$DAIMON_TCP_LAB_BUDGET" -gt 536870912 ] || { echo "流量预算必须大于 512 MiB 且不超过 20 GB。"; return 1; }
    for result in "$DAIMON_TCP_LAB_PORT" "$DAIMON_TCP_LAB_CONTROL_PORT" "$DAIMON_TCP_LAB_DURATION" "$DAIMON_TCP_LAB_OMIT" "$DAIMON_TCP_LAB_WAIT"; do
        [[ "$result" =~ ^[0-9]+$ ]] || { echo "无效的测速端口或时间参数。"; return 1; }
    done
    [ "$DAIMON_TCP_LAB_PORT" -gt 0 ] && [ "$DAIMON_TCP_LAB_CONTROL_PORT" -gt 0 ] &&
        [ "$DAIMON_TCP_LAB_PORT" -lt 65535 ] && [ "$DAIMON_TCP_LAB_CONTROL_PORT" -lt 65535 ] &&
        [ "$DAIMON_TCP_LAB_DURATION" -ge 1 ] && [ "$DAIMON_TCP_LAB_DURATION" -le 60 ] &&
        [ "$DAIMON_TCP_LAB_OMIT" -le 10 ] || return 1
    DAIMON_TCP_LAB_TX_START=$(daimon_tcp_lab_tx_bytes) || { echo "无法监测出口流量，未启动测速。"; return 1; }
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
    [ "$DAIMON_TCP_LAB_CONTROL_PORT" != "$DAIMON_TCP_LAB_PORT" ] || DAIMON_TCP_LAB_CONTROL_PORT=$((DAIMON_TCP_LAB_CONTROL_PORT + 1))
    local control_ip="$DAIMON_TCP_LAB_IP4" bind=0.0.0.0 control_family=4
    if [ "$family" = 6 ] || [ -z "$control_ip" ]; then
        control_ip="$DAIMON_TCP_LAB_IP6"; bind="::"; control_family=6
    fi
    while ss -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${DAIMON_TCP_LAB_CONTROL_PORT}$"; do
        DAIMON_TCP_LAB_CONTROL_PORT=$((DAIMON_TCP_LAB_CONTROL_PORT + 1))
    done
    # Persist the benchmark rule before opening the temporary control rule.
    daimon_tcp_fw_open "$DAIMON_TCP_LAB_PORT" "$family" || return 1
    daimon_tcp_lab_control_open "$DAIMON_TCP_LAB_CONTROL_PORT" "$control_family" || return 1
    DAIMON_TCP_LAB_CONTROL_OPEN=1
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
    echo "本次总预算 20 GB；出口计数包含预热、重传及同期业务流量，预留安全余量提前停止。"
    echo "单线程下载，每轮 ${DAIMON_TCP_LAB_DURATION}s + ${DAIMON_TCP_LAB_OMIT}s 预热，交错对照，最多 3 个探索候选及两次独立确认。"
    echo "预算不足或结果不稳定时保留原参数；无需重复输入命令，Ctrl+C 可取消。"

    local rc=0
    daimon_tcp_lab_execute "$mode" || rc=$?
    return "$rc"
}

daimon_tcp_lab_cleanup() {
    local status="$1" failed=0
    if [ -n "${DAIMON_TCP_LAB_IPERF_PID:-}" ]; then
        kill "$DAIMON_TCP_LAB_IPERF_PID" 2>/dev/null || true
        wait "$DAIMON_TCP_LAB_IPERF_PID" 2>/dev/null || true
    fi
    if [ "${DAIMON_TCP_LAB_COMMITTED:-0}" != 1 ] && [ "${DAIMON_TCP_LAB_CAPTURED:-0}" = 1 ]; then
        if [ "${DAIMON_TCP_LAB_FILES_CHANGED:-0}" = 1 ]; then
            daimon_tcp_lab_restore_files || failed=1
        fi
        daimon_tcp_lab_restore_runtime || failed=1
        if [ "$failed" = 0 ] && [ "${DAIMON_TCP_LAB_NEW_SNAPSHOT:-0}" = 1 ]; then
            rm -f -- "$DAIMON_TCP_SNAPSHOT" || failed=1
        fi
        [ "$failed" = 0 ] && echo "原运行参数已复读验证恢复；BBR + FQ 保留。"
    fi
    if [ "$failed" != 0 ]; then
        echo "自动恢复不完整，快照保留在 $DAIMON_TCP_LAB_DIR" >&2
        status=1
    fi
    [ -z "${DAIMON_TCP_PROFILE:-}" ] || daimon_tcp_lab_save_report "$status" || echo "测速汇总保存失败。" >&2
    if [ -n "${DAIMON_TCP_LAB_HELPER_PID:-}" ]; then
        if [ "$status" = 0 ]; then
            daimon_tcp_lab_finish done "${DAIMON_TCP_LAB_MESSAGE:-Original profile retained}"
        else
            daimon_tcp_lab_finish error "TCP session failed; check server rollback status"
        fi
    fi
    if [ -n "${DAIMON_TCP_LAB_HELPER_PID:-}" ]; then
        kill "$DAIMON_TCP_LAB_HELPER_PID" 2>/dev/null || true
        wait "$DAIMON_TCP_LAB_HELPER_PID" 2>/dev/null || true
    fi
    if [ "${DAIMON_TCP_LAB_CONTROL_OPEN:-0}" = 1 ]; then
        daimon_tcp_lab_control_close "$DAIMON_TCP_LAB_CONTROL_PORT"
    fi
    if [ "$status" -eq 0 ] && [ -n "${DAIMON_TCP_LAB_DIR:-}" ]; then
        [ -f "$DAIMON_TCP_LAB_DIR/records.tsv" ] &&
            cp -f "$DAIMON_TCP_LAB_DIR/records.tsv" "$DAIMON_TCP_STATE_DIR/last-rounds.tsv" 2>/dev/null || true
        case "${DAIMON_TCP_LAB_DIR:-}" in
            "$DAIMON_TCP_STATE_DIR"/session.*) rm -rf -- "$DAIMON_TCP_LAB_DIR" ;;
        esac
    fi
    return "$status"
}

daimon_tcp_lab_run() (
    local status=0
    mkdir -p "$DAIMON_TCP_STATE_DIR" || exit 1
    exec 9>"$DAIMON_TCP_STATE_DIR/session.lock" || exit 1
    flock -n 9 || { echo "已有测速或恢复操作进行中，未修改参数。"; exit 1; }
    DAIMON_TCP_LAB_CAPTURED=0
    DAIMON_TCP_LAB_CONTROL_OPEN=0
    DAIMON_TCP_LAB_HELPER_PID=""
    DAIMON_TCP_LAB_IPERF_PID=""
    DAIMON_TCP_LAB_COMMITTED=0
    DAIMON_TCP_LAB_FILES_CHANGED=0
    DAIMON_TCP_LAB_NEW_SNAPSHOT=0
    DAIMON_TCP_LAB_WINNER=A
    DAIMON_TCP_LAB_WINNING_CEILING=0
    DAIMON_TCP_LAB_MESSAGE="Original profile retained"
    trap 'status=$?; trap - EXIT; trap "" INT TERM HUP; daimon_tcp_lab_cleanup "$status"; exit "$?"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    daimon_tcp_lab_run_inner "$@" || status=$?
    exit "$status"
)

daimon_tcp_lab_record_baseline() {
    local f rate retrans rtt
    for f in $DAIMON_TCP_LAB_FAMILIES; do
        read -r rate retrans rtt < <(awk -F '\t' -v f="$f" '$1=="A" && $2==f {v3=$3; v4=$4; v6=$6} END {print v3, v4, v6}' "$DAIMON_TCP_LAB_DIR/records.tsv")
        [ -n "$rate" ] || continue
        daimon_tcp_record_family "$f" "$rate" "$rtt" "$retrans" "${DAIMON_TCP_LAB_DIR##*/}" \
            "${DAIMON_TCP_LAB_RECORDED_PROFILE:-A}" "${DAIMON_TCP_LAB_CLIENT:--}"
    done
}

daimon_tcp_lab_execute() {
    local mode="$1" f rate rtt retrans candidate ceiling profile score_status scorer winner="" last_winner=""
    local best_bdp="" best_rate="" best_rtt="" current_ceiling seen skip value i trials=0
    local -a queue=() candidates=() profiles=() refined=()
    : > "$DAIMON_TCP_LAB_DIR/records.tsv"
    daimon_tcp_lab_profile_round A 0 || return 1
    if [ "$mode" = test ]; then
        daimon_tcp_lab_record_baseline
        echo "iperf3 本地测试完成；未修改任何 sysctl 参数。"
        return 0
    fi
    current_ceiling=$(daimon_tcp_lab_current_ceiling)
    for f in $DAIMON_TCP_LAB_FAMILIES; do
        read -r rate rtt < <(awk -F '\t' -v f="$f" '$1=="A" && $2==f {print $3, $6}' "$DAIMON_TCP_LAB_DIR/records.tsv")
        if [ "$rtt" = 0 ] || [ -z "$rtt" ]; then
            echo "IPv$f 未测到真实 RTT，不能安全计算 BDP。" >&2
            return 1
        fi
        if [ "$mode" = separate ]; then
            for candidate in $(daimon_tcp_lab_candidate_list "$rate" "$rtt" || true); do
                queue+=("$candidate")
            done
        elif [ -z "${best_bdp:-}" ] || awk -v a="$rate" -v r="$rtt" -v b="$best_bdp" 'BEGIN{exit !(a*r > b)}'; then
            best_bdp=$(awk -v a="$rate" -v r="$rtt" 'BEGIN{print a*r}')
            best_rate="$rate"; best_rtt="$rtt"
        fi
    done
    if [ "$mode" != separate ]; then
        read -r -a queue <<< "$(daimon_tcp_lab_candidate_list "$best_rate" "$best_rtt" || true)"
    fi
    if [ "${#queue[@]}" -eq 0 ]; then
        echo "没有合法的不同候选，保留原配置。"
        daimon_tcp_lab_record_baseline
        return 0
    fi
    while [ "${#queue[@]}" -gt 0 ] && [ "$trials" -lt 3 ]; do
        candidate="${queue[0]}"; queue=("${queue[@]:1}")
        daimon_tcp_lab_distinct "$candidate" "$current_ceiling" || continue
        skip=0
        for seen in "${candidates[@]}"; do
            daimon_tcp_lab_distinct "$candidate" "$seen" || skip=1
        done
        [ "$skip" = 0 ] || continue
        if ! daimon_tcp_lab_can_afford 6; then
            echo "剩余预算优先留给两次独立确认，结束候选探索。"
            break
        fi
        candidates+=("$candidate"); profiles+=("B${#candidates[@]}")
        profile="${profiles[${#profiles[@]}-1]}"
        trials=$((trials + 1))
        echo "探索 $profile: 上限 $candidate 字节（原值 $current_ceiling），随后恢复 A 对照。"
        daimon_tcp_lab_profile_round "$profile" "$candidate" || return 1
        daimon_tcp_lab_profile_round A 0 || return 1
        scorer=$(daimon_tcp_lab_score choose "$(IFS=,; echo "${profiles[*]}")" "$(IFS=,; echo "${candidates[*]}")") || return 1
        score_status=$(python3 -c 'import json,sys;print(json.load(sys.stdin)["status"])' <<< "$scorer")
        [ "$score_status" != unstable ] || { echo "A 对照漂移过大，不能区分参数收益与线路波动。"; break; }
        if [ "$score_status" = candidate ]; then
            winner=$(python3 -c 'import json,sys;print(json.load(sys.stdin)["profile"])' <<< "$scorer")
            ceiling=$(python3 -c 'import json,sys;print(json.load(sys.stdin)["ceiling"])' <<< "$scorer")
            if [ "$winner" != "$last_winner" ]; then
                refined=()
                for f in $DAIMON_TCP_LAB_FAMILIES; do
                    read -r rate rtt < <(awk -F '\t' -v p="$winner" -v f="$f" '$1==p && $2==f {a=$3;b=$6} END {print a,b}' "$DAIMON_TCP_LAB_DIR/records.tsv")
                    for value in $(daimon_tcp_lab_candidate_list "$rate" "$rtt" "$ceiling" || true); do
                        refined+=("$value")
                    done
                done
                queue=("${refined[@]}" "${queue[@]}")
                last_winner="$winner"
            fi
        fi
    done
    if [ "${score_status:-}" != candidate ] || [ -z "$winner" ]; then
        echo "没有可重复确认的收益，保留原配置（上限 $current_ceiling 字节）。"
        daimon_tcp_lab_record_baseline
        return 0
    fi
    daimon_tcp_lab_can_afford 4 || { echo "预算不足以完成两次独立确认，保留原参数。"; return 0; }
    for i in 1 2; do
        echo "独立确认 $i/2: $winner（上限 $ceiling 字节）及 A 对照"
        daimon_tcp_lab_profile_round "$winner" "$ceiling" || return 1
        daimon_tcp_lab_profile_round A 0 || return 1
    done
    scorer=$(daimon_tcp_lab_score confirm "$winner") || return 1
    score_status=$(python3 -c 'import json,sys;print(json.load(sys.stdin)["status"])' <<< "$scorer")
    if [ "$score_status" != keep ]; then
        echo "确认轮未重复获得收益，恢复原配置。"
        daimon_tcp_lab_record_baseline
        return 0
    fi
    daimon_tcp_lab_save_snapshot || return 1
    DAIMON_TCP_LAB_FILES_CHANGED=1
    if ! daimon_tcp_lab_persist "$ceiling"; then
        echo "持久化或重载验证失败，恢复本次开始时的配置。" >&2
        return 1
    fi
    DAIMON_TCP_LAB_COMMITTED=1
    DAIMON_TCP_LAB_WINNER="$winner"
    DAIMON_TCP_LAB_WINNING_CEILING="$ceiling"
    for f in $DAIMON_TCP_LAB_FAMILIES; do
        rate=$(awk -F '\t' -v p="$winner" -v f="$f" '$1==p && $2==f {v=$3} END {print v}' "$DAIMON_TCP_LAB_DIR/records.tsv")
        rtt=$(awk -F '\t' -v p="$winner" -v f="$f" '$1==p && $2==f {v=$6} END {print v}' "$DAIMON_TCP_LAB_DIR/records.tsv")
        retrans=$(awk -F '\t' -v p="$winner" -v f="$f" '$1==p && $2==f {v=$4} END {print v}' "$DAIMON_TCP_LAB_DIR/records.tsv")
        daimon_tcp_record_family "$f" "$rate" "$rtt" "$retrans" "${DAIMON_TCP_LAB_DIR##*/}" "$winner:$ceiling" "${DAIMON_TCP_LAB_CLIENT:--}"
    done
    python3 - "$DAIMON_TCP_LAB_DIR/records.tsv" "$winner" <<'PY'
import sys, statistics
from collections import defaultdict
data = defaultdict(lambda: defaultdict(list))
for line in open(sys.argv[1], encoding='utf-8'):
    profile, family, rate, *_ = line.split('\t')
    data[profile][family].append(float(rate))
for family in data[sys.argv[2]]:
    before = statistics.median(data['A'][family])
    after = min(data[sys.argv[2]][family][-2:])
    print(f'IPv{family}: A median {before:.2f} Mbps -> confirmation minimum {after:.2f} Mbps')
PY
    DAIMON_TCP_LAB_MESSAGE="Confirmed profile $winner; ceiling $ceiling bytes"
    echo "两次独立确认均通过，已持久化 $winner（发送缓冲上限 $ceiling 字节）。"
}
