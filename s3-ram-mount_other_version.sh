#!/usr/bin/env bash

set -euo pipefail

# Detect the real user even if the script is run with sudo
ACTUAL_USER="${SUDO_USER:-$USER}"
ACTUAL_HOME="$(getent passwd "$ACTUAL_USER" | cut -d: -f6)"

if [ -z "${ACTUAL_HOME:-}" ] || [ ! -d "${ACTUAL_HOME}" ]; then
    echo "Error: unable to determine the real user's home directory."
    exit 1
fi

# Configuration
S3_BUCKET="benjiworld"
ENDPOINT="https://eu-west-1.s3.fil.one"
REGION="eu-west-1"

RAM_PERCENT="80"
MIN_RAM_DISK_MIB=512
LOGFILE="${ACTUAL_HOME}/mount-s3-ram.log"

# Directories are forced into the real user's home folder
S3_MOUNTPOINT="${ACTUAL_HOME}/FiloneRAM"
RAM_DISK="${ACTUAL_HOME}/.Filone_RAM_Cache"

# Dashboard settings
DASH_REFRESH_SECONDS=1
ACTIVE_WINDOW_SECONDS=30
MAX_ACTIVE_ITEMS=5

CLEANED_UP="false"
CREATED_MOUNTPOINT="false"
CREATED_RAM_DISK="false"

USER_UID=""
USER_GID=""
RAM_DISK_KB=0
RAM_DISK_MIB=0

need_cmds() {
    for cmd in mount-s3 getent cut id sudo mountpoint mount umount rm mkdir chmod chown awk df du numfmt tput tail find sort head date sleep grep; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "Error: '$cmd' is not installed."
            exit 1
        fi
    done

    if ! command -v fusermount3 >/dev/null 2>&1 && ! command -v fusermount >/dev/null 2>&1; then
        echo "Error: neither 'fusermount3' nor 'fusermount' is installed."
        exit 1
    fi
}

pick_fuse_umount() {
    if command -v fusermount3 >/dev/null 2>&1; then
        echo "fusermount3"
    else
        echo "fusermount"
    fi
}

human_bytes() {
    numfmt --to=iec --suffix=B "${1:-0}" 2>/dev/null || echo "${1:-0}B"
}

render_bar() {
    local used="${1:-0}"
    local total="${2:-1}"
    local width="${3:-32}"
    local pct fill empty

    [ "${total}" -le 0 ] && total=1
    [ "${used}" -lt 0 ] && used=0

    pct=$(( used * 100 / total ))
    [ "${pct}" -gt 100 ] && pct=100

    fill=$(( pct * width / 100 ))
    empty=$(( width - fill ))

    printf '['
    printf '%*s' "${fill}" '' | tr ' ' '#'
    printf '%*s' "${empty}" '' | tr ' ' '.'
    printf '] %3d%%' "${pct}"
}

prepare_dirs() {
    USER_UID="$(id -u "$ACTUAL_USER")"
    USER_GID="$(id -g "$ACTUAL_USER")"

    if [ ! -d "${S3_MOUNTPOINT}" ]; then
        sudo -u "$ACTUAL_USER" mkdir -p "${S3_MOUNTPOINT}"
        CREATED_MOUNTPOINT="true"
    fi

    if [ ! -d "${RAM_DISK}" ]; then
        sudo -u "$ACTUAL_USER" mkdir -p "${RAM_DISK}"
        CREATED_RAM_DISK="true"
    fi
}

prepare_ram_disk() {
    local mem_available_kb
    local min_ram_kb
    local mem_available_human
    local ram_disk_human

    mem_available_kb=$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)

    if [ -z "${mem_available_kb}" ] || ! [[ "${mem_available_kb}" =~ ^[0-9]+$ ]]; then
        echo "Error: unable to read MemAvailable from /proc/meminfo"
        exit 1
    fi

    RAM_DISK_KB=$(( mem_available_kb * RAM_PERCENT / 100 ))
    min_ram_kb=$(( MIN_RAM_DISK_MIB * 1024 ))

    if [ "${RAM_DISK_KB}" -lt "${min_ram_kb}" ]; then
        RAM_DISK_KB="${min_ram_kb}"
    fi

    RAM_DISK_MIB=$(( RAM_DISK_KB / 1024 ))

    mem_available_human=$(human_bytes $(( mem_available_kb * 1024 )))
    ram_disk_human=$(human_bytes $(( RAM_DISK_KB * 1024 )))

    echo "Preparing mount-s3 RAM-backed environment for user: ${ACTUAL_USER}"
    echo "MemAvailable : ${mem_available_human}"
    echo "RAM cache    : ${ram_disk_human} (${RAM_PERCENT}% target)"
    echo "Mountpoint   : ${S3_MOUNTPOINT}"
    echo "RAM disk     : ${RAM_DISK}"
    echo "Log file     : ${LOGFILE}"

    if mountpoint -q "${RAM_DISK}" 2>/dev/null; then
        echo "RAM disk already mounted on ${RAM_DISK}, remounting with new size..."
        sudo mount -o remount,size="${RAM_DISK_KB}k",uid="${USER_UID}",gid="${USER_GID}",mode=0755 tmpfs "${RAM_DISK}"
    else
        echo "Mounting RAM disk on ${RAM_DISK} ..."
        sudo mount -t tmpfs -o "size=${RAM_DISK_KB}k,uid=${USER_UID},gid=${USER_GID},mode=0755" tmpfs "${RAM_DISK}"
    fi

    sudo chown "${USER_UID}:${USER_GID}" "${RAM_DISK}"
    chmod 0755 "${RAM_DISK}"

    if ! mountpoint -q "${RAM_DISK}" 2>/dev/null; then
        echo "Error: failed to create RAM disk."
        exit 1
    fi
}

mount_s3_bucket() {
    if mountpoint -q "${S3_MOUNTPOINT}" 2>/dev/null; then
        echo "Error: ${S3_MOUNTPOINT} is already mounted."
        exit 1
    fi

    : > "${LOGFILE}"

    echo "Mounting ${S3_BUCKET} via mount-s3 ..."
    sudo -u "$ACTUAL_USER" mount-s3 "${S3_BUCKET}" "${S3_MOUNTPOINT}" \
        --endpoint-url "${ENDPOINT}" \
        --region "${REGION}" \
        --profile default \
        --force-path-style \
        --allow-delete \
        --allow-overwrite \
        --allow-other \
        --cache "${RAM_DISK}" \
        --metadata-ttl 60 >> "${LOGFILE}" 2>&1

    sleep 2

    if ! mountpoint -q "${S3_MOUNTPOINT}" 2>/dev/null; then
        echo "Error: mountpoint failed to connect to S3. Check your credentials."
        tail -n 20 "${LOGFILE}" 2>/dev/null || true
        exit 1
    fi
}

get_recent_cache_items() {
    local now
    now=$(date +%s)

    find "${RAM_DISK}" -type f -printf '%T@|%P\n' 2>/dev/null \
        | awk -F'|' -v now="${now}" -v win="${ACTIVE_WINDOW_SECONDS}" '$1 >= now - win {print}' \
        | sort -t'|' -k1,1nr \
        | head -n "${MAX_ACTIVE_ITEMS}" \
        | cut -d'|' -f2-
}

monitor_dashboard() {
    local key now prev_ts dt
    local cache_bytes prev_cache_bytes delta est_speed
    local ram_used ram_avail ram_total
    local mount_state ram_state
    local -a active_items=()

    prev_cache_bytes=$(du -sb "${RAM_DISK}" 2>/dev/null | awk '{print $1+0}')
    prev_ts=$(date +%s)

    tput civis 2>/dev/null || true

    while true; do
        mount_state="DOWN"
        ram_state="DOWN"

        if mountpoint -q "${S3_MOUNTPOINT}" 2>/dev/null; then
            mount_state="UP"
        fi

        if mountpoint -q "${RAM_DISK}" 2>/dev/null; then
            ram_state="UP"
        fi

        now=$(date +%s)
        cache_bytes=$(du -sb "${RAM_DISK}" 2>/dev/null | awk '{print $1+0}')
        read -r ram_used ram_avail ram_total < <(
            df -B1 --output=used,avail,size "${RAM_DISK}" 2>/dev/null | awk 'NR==2{print $1,$2,$3}'
        )

        dt=$(( now - prev_ts ))
        [ "${dt}" -le 0 ] && dt=1

        delta=$(( cache_bytes - prev_cache_bytes ))
        [ "${delta}" -lt 0 ] && delta=0
        est_speed=$(( delta / dt ))

        mapfile -t active_items < <(get_recent_cache_items)

        tput home 2>/dev/null || true
        tput ed 2>/dev/null || printf '\033[2J\033[H'

        echo "mount-s3 local dashboard  |  press q to quit  |  Ctrl+C cleans everything"
        echo
        echo "User       : ${ACTUAL_USER}"
        echo "Bucket     : ${S3_BUCKET}"
        echo "Endpoint   : ${ENDPOINT}"
        echo "Mountpoint : ${S3_MOUNTPOINT}"
        echo "RAM cache  : ${RAM_DISK}"
        echo

        echo "S3 mount   : ${mount_state}"
        echo "RAM tmpfs  : ${ram_state}"
        echo "Est. speed : $(human_bytes "${est_speed}")/s"
        echo "Cache data : $(human_bytes "${cache_bytes}")"
        echo

        echo "RAM tmpfs  : $(human_bytes "${ram_used:-0}") / $(human_bytes "${ram_total:-0}")"
        printf "RAM fill   : "
        render_bar "${ram_used:-0}" "${ram_total:-1}" 36
        echo
        echo "Cache data : $(human_bytes "${cache_bytes:-0}") / $(human_bytes "${ram_total:-0}")"
        printf "Cache fill : "
        render_bar "${cache_bytes:-0}" "${ram_total:-1}" 36
        echo

        echo
        echo "Recent cache activity (last ${ACTIVE_WINDOW_SECONDS}s):"
        if [ "${#active_items[@]}" -eq 0 ]; then
            echo "  (idle)"
        else
            local item
            for item in "${active_items[@]}"; do
                echo "  - ${item}"
            done
        fi

        echo
        echo "Recent log:"
        tail -n 5 "${LOGFILE}" 2>/dev/null | sed 's/^/  /'

        if [ "${mount_state}" != "UP" ]; then
            echo
            echo "Mount is no longer active."
            break
        fi

        prev_cache_bytes="${cache_bytes}"
        prev_ts="${now}"

        IFS= read -rsn1 -t "${DASH_REFRESH_SECONDS}" key || true
        if [ "${key:-}" = "q" ] || [ "${key:-}" = "Q" ]; then
            break
        fi
    done

    tput cnorm 2>/dev/null || true
}

cleanup() {
    tput cnorm 2>/dev/null || true

    if [ "${CLEANED_UP}" = "true" ]; then
        return
    fi
    CLEANED_UP="true"

    echo
    echo "Shutdown requested: cleaning up..."

    if [ -n "${S3_MOUNTPOINT:-}" ] && mountpoint -q "${S3_MOUNTPOINT}" 2>/dev/null; then
        echo "Unmounting S3 mount..."
        local fuse_umount
        fuse_umount=$(pick_fuse_umount)
        "${fuse_umount}" -u "${S3_MOUNTPOINT}" >/dev/null 2>&1 || sudo umount -l "${S3_MOUNTPOINT}" >/dev/null 2>&1 || true
        sleep 1
    fi

    if [ -n "${RAM_DISK:-}" ] && mountpoint -q "${RAM_DISK}" 2>/dev/null; then
        echo "Unmounting RAM cache..."
        sudo umount "${RAM_DISK}" >/dev/null 2>&1 || sudo umount -l "${RAM_DISK}" >/dev/null 2>&1 || true
    fi

    if [ "${CREATED_MOUNTPOINT}" = "true" ] && [ -d "${S3_MOUNTPOINT}" ]; then
        sudo rm -rf "${S3_MOUNTPOINT}" >/dev/null 2>&1 || true
    fi

    if [ "${CREATED_RAM_DISK}" = "true" ] && [ -d "${RAM_DISK}" ]; then
        sudo rm -rf "${RAM_DISK}" >/dev/null 2>&1 || true
    fi

    echo "Cleanup complete."
}

trap cleanup INT TERM EXIT

main() {
    need_cmds
    prepare_dirs
    prepare_ram_disk
    mount_s3_bucket

    echo "-------------------------------------------------------"
    echo "SUCCESS! S3 environment is live."
    echo "Files     : ${S3_MOUNTPOINT}"
    echo "RAM Cache : ${RAM_DISK}"
    echo "Press q or CTRL+C to unmount and delete created folders."
    echo "-------------------------------------------------------"

    monitor_dashboard
}

main "$@"
