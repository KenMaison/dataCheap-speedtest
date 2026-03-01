#!/bin/bash

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

PING_SAMPLES=10
DOWNLOAD_SECONDS=10
UPLOAD_SECONDS=10

PROBES_API="https://yandex.ru/internet/api/v0/get-probes"
IPV4_API="https://ipv4-internet.yandex.net/api/v0/ip"
IPV6_API="https://ipv6-internet.yandex.net/api/v0/ip"

UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36"

DEBUG=false

for arg in "$@"; do
    if [ "$arg" = "--debug" ]; then
        DEBUG=true
    fi
done

# Исправлено: гарантированное создание директории
TMPDIR_ST=""
SPINNER_PID=""

debug() {
    if $DEBUG; then
        echo "[DEBUG] $*" >&2
    fi
}

cleanup() {
    if [ -n "$TMPDIR_ST" ] && [ -d "$TMPDIR_ST" ]; then
        rm -rf "$TMPDIR_ST" 2>/dev/null
    fi
    kill $(jobs -p) 2>/dev/null || true
}

trap cleanup EXIT

start_spinner() {
    local msg=$1

    {
        local chars='|/-\'
        local i=0

        while true; do
            printf "\r  \033[0;36m%s\033[0m %s " "${chars:$i:1}" "$msg"
            i=$(( (i + 1) % 4 ))
            sleep 0.1
        done
    } &

    SPINNER_PID=$!
}

stop_spinner() {
    local msg=$1

    if [ -n "${SPINNER_PID:-}" ]; then
        kill "$SPINNER_PID" 2>/dev/null || true
        wait "$SPINNER_PID" 2>/dev/null || true
        SPINNER_PID=""
    fi

    printf "\r  \033[0;32m✓\033[0m %-40s\n" "$msg"
}

check_deps() {
    local missing=()

    for cmd in curl bc python3; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        if command -v apt-get &>/dev/null; then
            sudo apt-get install -y -qq ${missing[*]} >/dev/null 2>&1
        elif command -v yum &>/dev/null; then
            sudo yum install -y -q ${missing[*]} >/dev/null 2>&1
        elif command -v apk &>/dev/null; then
            sudo apk add --quiet ${missing[*]} >/dev/null 2>&1
        fi

        for cmd in "${missing[@]}"; do
            if ! command -v "$cmd" &>/dev/null; then
                echo -e "${RED}Failed to install: $cmd${NC}"
                exit 1
            fi
        done
    fi
}

fmt() {
    printf "%.2f" "$(echo "scale=4; $1" | bc 2>/dev/null || echo "0")"
}

format_speed() {
    local bps=$1

    if (( $(echo "$bps >= 1000000000" | bc -l) )); then
        echo "$(fmt "$bps / 1000000000") Gbit/s"
    elif (( $(echo "$bps >= 1000000" | bc -l) )); then
        echo "$(fmt "$bps / 1000000") Mbit/s"
    elif (( $(echo "$bps >= 1000" | bc -l) )); then
        echo "$(fmt "$bps / 1000") Kbit/s"
    else
        echo "$(printf "%.0f" "$(echo "$bps" | bc)") bit/s"
    fi
}

print_header() {
    echo ""
    echo -e "${BOLD}${CYAN}  ╔══════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}  ║        Yandex Internet Speed Test        ║${NC}"
    echo -e "${BOLD}${CYAN}  ║                DataCheap                 ║${NC}"
    echo -e "${BOLD}${CYAN}  ║               Mescheryakov               ║${NC}"
    echo -e "${BOLD}${CYAN}  ║                 Romanov                  ║${NC}"
    echo -e "${BOLD}${CYAN}  ╚══════════════════════════════════════════╝${NC}"
    echo ""
}

fetch_probes() {
    # Исправлено: создаём директорию прямо перед использованием
    TMPDIR_ST=$(mktemp -d /tmp/yandex_speedtest.XXXXXX 2>/dev/null || echo "")
    if [ -z "$TMPDIR_ST" ] || [ ! -d "$TMPDIR_ST" ]; then
        TMPDIR_ST="/tmp/yandex_speedtest.$$"
        mkdir -p "$TMPDIR_ST"
    fi

    local raw
    raw=$(curl -s --max-time 10 \
        -H "User-Agent: $UA" \
        -H "Referer: https://yandex.ru/internet/" \
        -H "Accept: application/json" \
        "$PROBES_API" 2>/dev/null)

    if [ -z "$raw" ]; then
        echo -e "${RED}  Failed to fetch probe servers from Yandex${NC}" >&2
        exit 1
    fi

    echo "$raw" > "$TMPDIR_ST/probes.json"

    TMPDIR_ST="$TMPDIR_ST" python3 << 'PYEOF'
import json, os

td = os.environ["TMPDIR_ST"]

with open(f"{td}/probes.json") as f:
    d = json.load(f)

with open(f"{td}/mid", "w") as f:
    f.write(d.get("mid", ""))

with open(f"{td}/ping_urls", "w") as f:
    for p in d.get("latency", {}).get("probes", []):
        f.write(p["url"] + "\n")

with open(f"{td}/download_urls", "w") as f:
    for p in d.get("download", {}).get("probes", []):
        url = p["url"]
        if "50mb" in url:
            f.write(url + "\n")

with open(f"{td}/upload_urls", "w") as f:
    for p in d.get("upload", {}).get("probes", []):
        url = p["url"]
        if "timeout" not in url:
            f.write(url + "\n")

with open(f"{td}/upload_warmup_urls", "w") as f:
    warmup = d.get("upload", {}).get("warmup", {})
    for p in warmup.get("probes", []):
        urls = p.get("urls", [])
        if urls:
            f.write(urls[0] + "\n")

servers = set()
for section in ["latency", "download", "upload"]:
    for p in d.get(section, {}).get("probes", []):
        url = p.get("url", "")
        if url:
            host = url.split("/")[2]
            servers.add(host)

with open(f"{td}/servers", "w") as f:
    for s in sorted(servers):
        f.write(s + "\n")
PYEOF

    local server_count
    server_count=$(wc -l < "$TMPDIR_ST/servers" | tr -d ' ')

    echo -e "  ${DIM}Probe servers: ${server_count} Yandex CDN nodes${NC}"

    while IFS= read -r srv; do
        echo -e "  ${DIM}  → ${srv}${NC}"
    done < "$TMPDIR_ST/servers"

    echo ""
}

get_connection_info() {
    local ipv4
    ipv4=$(curl -s --max-time 5 -H "User-Agent: $UA" "$IPV4_API" 2>/dev/null | tr -d '"' || echo "N/A")

    local ipv6
    ipv6=$(curl -s --max-time 3 -6 -H "User-Agent: $UA" "$IPV6_API" 2>/dev/null | tr -d '"' || echo "")

    local info
    info=$(curl -s --max-time 5 "https://ipinfo.io/${ipv4}/json" 2>/dev/null || echo '{}')

    local parsed
    parsed=$(echo "$info" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d.get('city','') + '|' + d.get('region','') + '|' + d.get('country','') + '|' + d.get('org',''))
" 2>/dev/null || echo "|||")

    local city region country org

    IFS='|' read -r city region country org <<< "$parsed"

    echo -e "  ${DIM}────────────────────────────────────────${NC}"
    echo -e "  ${BOLD}Connection Info${NC}"
    echo -e "  ${DIM}────────────────────────────────────────${NC}"
    echo -e "  ${DIM}IPv4:${NC}      $ipv4"

    if [ -n "$ipv6" ] && [ "$ipv6" != "N/A" ]; then
        echo -e "  ${DIM}IPv6:${NC}      $ipv6"
    else
        echo -e "  ${DIM}IPv6:${NC}      not available"
    fi

    [ -n "$org" ]  && echo -e "  ${DIM}ISP:${NC}       $org"
    [ -n "$city" ] && echo -e "  ${DIM}Location:${NC}  ${city}${region:+, $region}${country:+, $country}"
    echo ""
}

measure_ping() {
    local results=()

    while IFS= read -r url; do
        [ -z "$url" ] && continue

        curl -s -o /dev/null -I --max-time 5 \
            -H "User-Agent: $UA" \
            -H "Referer: https://yandex.ru/internet/" \
            "$url" 2>/dev/null || true

        for i in $(seq 1 $PING_SAMPLES); do
            local timing
            timing=$(curl -s -o /dev/null \
                -w "%{time_starttransfer} %{time_appconnect}" \
                -I --max-time 5 \
                -H "User-Agent: $UA" \
                -H "Referer: https://yandex.ru/internet/" \
                "$url" 2>/dev/null || echo "0 0")

            local ts
            ts=$(echo "$timing" | awk '{print $1}')

            local ta
            ta=$(echo "$timing" | awk '{print $2}')

            local ms
            ms=$(echo "($ts - $ta) * 1000" | bc 2>/dev/null || echo "0")

            if (( $(echo "$ms > 0" | bc -l) )); then
                results+=("$ms")
            fi
        done
    done < "$TMPDIR_ST/ping_urls"

    local count=${#results[@]}

    if [ "$count" -eq 0 ]; then
        echo "0.00|0.00|0.00|0.00"
        return
    fi

    IFS=$'\n' sorted=($(printf '%s\n' "${results[@]}" | sort -g))
    unset IFS

    local trim=$(( count / 4 ))

    local total=0
    local min=999999
    local max=0
    local trimmed_count=0

    for idx in $(seq $trim $(( count - trim - 1 ))); do
        local val=${sorted[$idx]}

        total=$(echo "$total + $val" | bc)
        trimmed_count=$((trimmed_count + 1))

        if (( $(echo "$val < $min" | bc -l) )); then
            min=$val
        fi

        if (( $(echo "$val > $max" | bc -l) )); then
            max=$val
        fi
    done

    if [ "$trimmed_count" -eq 0 ]; then
        echo "0.00|0.00|0.00|0.00"
        return
    fi

    local avg
    avg=$(fmt "$total / $trimmed_count")

    local jitter_sum=0
    local prev=""

    for idx in $(seq $trim $(( count - trim - 1 ))); do
        local val=${sorted[$idx]}

        if [ -n "$prev" ]; then
            local diff
            diff=$(echo "$val - $prev" | bc)
            diff=$(echo "${diff#-}" | bc)
            jitter_sum=$(echo "$jitter_sum + $diff" | bc)
        fi

        prev=$val
    done

    local jitter
    jitter=$(fmt "$jitter_sum / ($trimmed_count - 1)" 2>/dev/null || echo "0.00")

    min=$(fmt "$min / 1")
    max=$(fmt "$max / 1")

    echo "$avg|$min|$max|$jitter"
}

download_stream() {
    local url=$1
    local result_file=$2
    local duration=$3

    local output
    output=$(curl -s -o /dev/null \
        -w "%{size_download} %{time_total} %{speed_download}" \
        --max-time "$duration" \
        -H "User-Agent: $UA" \
        -H "Referer: https://yandex.ru/internet/" \
        "$url" 2>/dev/null) || true

    echo "${output:-0 0 0}" > "$result_file"
}

measure_download() {
    local idx=0
    local pids=()

    if $DEBUG; then
        debug "download_urls content:"
        cat "$TMPDIR_ST/download_urls" >&2
        debug "---"
    fi

    while IFS= read -r url; do
        [ -z "$url" ] && continue

        idx=$((idx + 1))
        debug "spawning download stream $idx: $url"
        download_stream "$url" "$TMPDIR_ST/dlspeed_${idx}" "$DOWNLOAD_SECONDS" &
        pids+=($!)
    done < "$TMPDIR_ST/download_urls"

    debug "waiting for ${#pids[@]} download streams..."

    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    if $DEBUG; then
        debug "all streams done, listing dlspeed files:"
        ls -la "$TMPDIR_ST"/dlspeed_* >&2 2>/dev/null || debug "no dlspeed files!"
    fi

    local total_speed=0
    local stream_count=0

    for f in "$TMPDIR_ST"/dlspeed_*; do
        [ -f "$f" ] || continue

        stream_count=$((stream_count + 1))

        local line
        line=$(cat "$f" 2>/dev/null || echo "0 0 0")

        local size time_total speed computed
        size=$(echo "$line" | awk '{print $1}')
        time_total=$(echo "$line" | awk '{print $2}')
        speed=$(echo "$line" | awk '{print $3}')

        if (( $(echo "$time_total > 0" | bc -l) )); then
            computed=$(echo "$size * 8 / $time_total" | bc)
        else
            computed=0
        fi

        total_speed=$(echo "$total_speed + $computed" | bc)
    done

    echo "$total_speed"
}

measure_upload() {
    local idx=0
    local pids=()

    if $DEBUG; then
        debug "upload_urls content:"
        cat "$TMPDIR_ST/upload_urls" >&2
        debug "---"
    fi

    while IFS= read -r url; do
        [ -z "$url" ] && continue

        idx=$((idx + 1))
        debug "spawning upload stream $idx: $url"

        (
            local data_file="$TMPDIR_ST/upload_data_${idx}"
            dd if=/dev/urandom bs=1M count=10 of="$data_file" 2>/dev/null

            local output
            output=$(curl -s -o /dev/null \
                -w "%{size_upload} %{time_total} %{speed_upload}" \
                --max-time "$UPLOAD_SECONDS" \
                -H "User-Agent: $UA" \
                -H "Referer: https://yandex.ru/internet/" \
                -F "file=@$data_file" \
                "$url" 2>/dev/null) || true

            echo "${output:-0 0 0}" > "$TMPDIR_ST/ulspeed_${idx}"
        ) &
        pids+=($!)
    done < "$TMPDIR_ST/upload_urls"

    debug "waiting for ${#pids[@]} upload streams..."

    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    if $DEBUG; then
        debug "all streams done, listing ulspeed files:"
        ls -la "$TMPDIR_ST"/ulspeed_* >&2 2>/dev/null || debug "no ulspeed files!"
    fi

    local total_speed=0
    local stream_count=0

    for f in "$TMPDIR_ST"/ulspeed_*; do
        [ -f "$f" ] || continue

        stream_count=$((stream_count + 1))

        local line
        line=$(cat "$f" 2>/dev/null || echo "0 0 0")

        local size time_total speed computed
        size=$(echo "$line" | awk '{print $1}')
        time_total=$(echo "$line" | awk '{print $2}')
        speed=$(echo "$line" | awk '{print $3}')

        if (( $(echo "$time_total > 0" | bc -l) )); then
            computed=$(echo "$size * 8 / $time_total" | bc)
        else
            computed=0
        fi

        total_speed=$(echo "$total_speed + $computed" | bc)
    done

    echo "$total_speed"
}

main() {
    print_header

    start_spinner "Checking dependencies..."
    check_deps
    stop_spinner "Dependencies checked"

    start_spinner "Fetching probe servers from Yandex..."
    fetch_probes
    stop_spinner "Probe servers fetched"

    get_connection_info

    start_spinner "Measuring ping (latency)..."
    ping_result=$(measure_ping)
    stop_spinner "Ping measurement complete"

    IFS='|' read -r ping_avg ping_min ping_max ping_jitter <<< "$ping_result"

    echo -e "  ${DIM}────────────────────────────────────────${NC}"
    echo -e "  ${BOLD}Latency${NC}"
    echo -e "  ${DIM}────────────────────────────────────────${NC}"
    printf "  ${DIM}Average:${NC}  %.2f ms\n" "$ping_avg"
    printf "  ${DIM}Min/Max:${NC}  %.2f / %.2f ms\n" "$ping_min" "$ping_max"
    printf "  ${DIM}Jitter:${NC}   %.2f ms\n" "$ping_jitter"
    echo ""

    start_spinner "Measuring download speed (${DOWNLOAD_SECONDS}s)..."
    download_speed=$(measure_download)
    stop_spinner "Download measurement complete"

    start_spinner "Measuring upload speed (${UPLOAD_SECONDS}s)..."
    upload_speed=$(measure_upload)
    stop_spinner "Upload measurement complete"

    echo -e "  ${DIM}────────────────────────────────────────${NC}"
    echo -e "  ${BOLD}Speed Test Results${NC}"
    echo -e "  ${DIM}────────────────────────────────────────${NC}"
    echo -e "  ${DIM}Download:${NC}  $(format_speed "$download_speed")"
    echo -e "  ${DIM}Upload:${NC}    $(format_speed "$upload_speed")"
    echo ""
}

main
