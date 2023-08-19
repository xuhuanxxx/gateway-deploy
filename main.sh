#!/bin/bash


APP_NAME="clash"
CORE_FILE="/bin/$APP_NAME"
DAEMON_FILE="/etc/systemd/system/$APP_NAME.service"
DATA_DIR="/srv/$APP_NAME"
EXT_UI="$DATA_DIR/ui"
ROUTE_FILE="$DATA_DIR/route.sh"
UDEV_FILE="/etc/udev/rules.d/99-$APP_NAME.rules"
CONF_FILE="/etc/$APP_NAME.yaml"
EXT_CTL=${EXT_CTL:-":9090"}
SECERT=${SECERT:-"123456"}
DNS_PORT=${DNS_PORT:-":1053"}
NIC_NAME=${NIC_NAME:-"enp46s0"}
PROXY="https://ghproxy.com/"
SUB_URL=${SUB_URL:-"订阅链接"}

function check_arch() {
    case "$(uname -m)" in
        "x86_64") arch="amd64-v3";;
        "i386") arch="386";;
        "i686") arch="386";;
        "armhf") arch="armv7";;
        "arm64") arch="arm64";;
        "aarch64") arch="arm64";;
        *) echo "Unknown architecture: $(uname -m)" && exit 1 ;;
esac
}

function check_env() {
    echo "EXT_CTL: $EXT_CTL"
    echo "SECERT: $SECERT"
    echo "DNS_PORT: $DNS_PORT"
    echo "NIC_NAME: $NIC_NAME"
    echo "SUB_URL: $SUB_URL"
    echo ""
}

function verify_target() {
    local path="$1"
    local type="$2"

    # result: found, conflict, missing
    local result="missing"
    if [ -e "$path" ]; then
        if [ "$type" = "file" ] && [ -f "$path" ]; then
            result="found"
        elif [ "$type" = "directory" ] && [ -d "$path" ]; then
            result="found"
        else
            result="conflict"
        fi
    fi
    echo "$result"
}

function resolve_action() {
    local command="$1"
    local component="$2"
    local verification="$3"

    case "$command" in
        status)
            case "$verification" in
                found)
                    result="check"
                    ;;
                conflict)
                    result="ignore"
                    ;;
                missing)
                    result="ignore"
                    ;;
            esac
            ;;
        remove)
            case "$verification" in
                found)
                    if grep -q "$component" <<< "$allowlist"; then
                        result="check,purge"
                    else
                        result="check"
                    fi
                    ;;
                conflict)
                    if grep -q "$component" <<< "$allowlist"; then
                        result="purge"
                    else
                        result="ignore"
                    fi
                    ;;
                missing)
                    result="ignore"
                    ;;
            esac
            ;;
        install)
            case "$verification" in
                found)
                    result="check"
                    ;;
                conflict)
                    if grep -q "$component" <<< "$allowlist"; then
                        result="purge,create"
                    else
                        result="ignore"
                    fi
                    ;;
                missing)
                    result="create"
                    ;;
            esac
            ;;
        update)
            case "$verification" in
                found)
                    if grep -q "$component" <<< "$allowlist"; then
                        result="check,purge,create"
                    else
                        result="check"
                    fi
                    ;;
                conflict)
                    if grep -q "$component" <<< "$allowlist"; then
                        result="check,purge,create"
                    else
                        result="ignore"
                    fi
                    ;;
                missing)
                    if grep -q "$component" <<< "$allowlist"; then
                        result="create"
                    else
                        result="create"
                    fi
                    ;;
            esac
            ;;
    esac

    echo "$result"

}

function service() {
    local action="$1"
    files=$(grep -rlF "$APP_NAME" /etc/systemd/system/*.service)
    if [ -n "$files" ]; then
        for file in "$files"; do
            name=$(basename "$file" .service)
            status=$(systemctl is-active $name.service)
            if [ "$status" = "active" ]; then
                echo "找到运行$APP_NAME的服务：$file" | tee /dev/stderr
                if [ "$action" = "stop" ]; then
                    systemctl stop "$name"
                    echo "停止$name服务" | tee /dev/stderr
                fi
            fi
        done
    else
        echo "没有使用$APP_NAME的服务" | tee /dev/stderr
    fi

    pids=$(pgrep -f "$CORE_FILE")
    if [ -n "$pids" ]; then
        if [ "$action" = "stop" ]; then
            kill $pids
            echo "停止使用$CORE_FILE运行的进程：$pids" | tee /dev/stderr
        fi
    else
        echo "没有运行$CORE_FILE的进程" | tee /dev/stderr
    fi

    if [ $? -eq 0 ]; then
        echo "success"
    else
        echo "failure"
    fi
}

function create_core() {
    release_info="https://api.github.com/repos/Dreamacro/clash/releases/tags/premium"
    curl -L -s -o release_info.json $release_info

    release_url=$(jq ".assets[${i}].browser_download_url" release_info.json | tr -d '"' | grep -m1 ${APP_NAME}-linux-$arch)

    echo "release_url: $release_url" | tee /dev/stderr
    remote_version=$(jq -r ".name" release_info.json | grep -oP '(?<=Premium )\d{4}\.\d{2}\.\d{2}')
    echo "远端版本：$remote_version" | tee /dev/stderr
    curl -L -s -o "/tmp/$APP_NAME.gz" "$PROXY$release_url"
    gzip -df "/tmp/$APP_NAME.gz"
    install -m 0755 "/tmp/$APP_NAME" "$CORE_FILE"
    if [ $? -eq 0 ]; then
        echo "success"
    else
        echo "failure"
    fi
}

function create_daemon() {
    systemctl daemon-reload
    systemctl enable "$APP_NAME.service"
    if [ $? -eq 0 ]; then
        echo "success"
    else
        echo "failure"
    fi
}

function create_extui() {
    release_extui="https://github.com/Dreamacro/clash-dashboard/archive/gh-pages.zip"
    curl -L -# -o "/tmp/ui.zip" "$PROXY$release_extui"
    unzip -o "/tmp/ui.zip" -d "/tmp"
    mkdir -p "$EXT_UI"
    mv -fT "/tmp/clash-dashboard-gh-pages" "$EXT_UI"
    if [ $? -eq 0 ]; then
        echo "success"
    else
        echo "failure"
    fi
}

function create_route() {
    sed -e "s/\${NIC_NAME}/$NIC_NAME/g" \
        -e "s/\${DNS_PORT}/$DNS_PORT/g" src/route > $ROUTE_FILE

    chmod +x $ROUTE_FILE
    if [ $? -eq 0 ]; then
        echo "success"
    else
        echo "failure"
    fi
}

function create_udev() {
    sed -e "s/\${$ROUTE_FILE}/$ROUTE_FILE/g" src/udev > $UDEV_FILE

    if [ $? -eq 0 ]; then
        echo "success"
    else
        echo "failure"
    fi
}

function create_conf() {
    sed -e "s/\${SECRET}/$SECRET/g" \
        -e "s/\${NIC_NAME}/$NIC_NAME/g" \
        -e "s/\${DNS_PORT}/$DNS_PORT/g"  \
        -e "s/\${SUB_URL}/$SUB_URL/g" src/config > $DATA_DIR/config.yaml

    install -m 600 $DATA_DIR/config.yaml

    if [ $? -eq 0 ]; then
        echo "success"
    else
        echo "failure"
    fi
}

function create() {
    local component="$1"
    case "$component" in
        core)
            res=$(create_core | tail -n 1)
            echo "$res"
            ;;
        daemon)
            res=$(create_daemon | tail -n 1)
            echo "$res"
            ;;
        extui)
            res=$(create_extui | tail -n 1)
            echo "$res"
            ;;
        route)
            res=$(create_route | tail -n 1)
            echo "$res"
            ;;
        udev)
            res=$(create_udev | tail -n 1)
            echo "$res"
            ;;
        conf)
            res=$(create_conf | tail -n 1)
            echo "$res"
            ;;
        *)
            echo "Invalid component: ${component:-???}"
            exit 1
            ;;
    esac
}

function main() {

    local command="$1"
    local component="$2"

    case "$component" in
        core)
            local path="$CORE_FILE"
            local type="file"
            ;;
        daemon)
            local path="$DAEMON_FILE"
            local type="file"
            ;;
        extui)
            local path="$EXT_UI"
            local type="directory"
            ;;
        route)
            local path="$ROUTE_FILE"
            local type="file"
            ;;
        udev)
            local path="$UDEV_FILE"
            local type="file"
            ;;
        conf)
            local path="$CONF_FILE"
            local type="file"
            ;;
        *)
            echo "Invalid component: ${component:-???}"
            exit 1
            ;;
    esac

    echo "组件: $component - ${profile[$component]}"

    local verification=$(verify_target "$path" "$type")
    echo "路径: $path"

    echo "验证: $verification"

    local action=$(resolve_action "$command" "$component" "$verification")
    echo "操作: $action"

    if grep -q "check" <<< "$action"; then
        echo "检查组件..."
        local info=""
        local owner=$(stat -c "%U" "$path")
        local group=$(stat -c "%G" "$path")
        local access=$(stat -c "%A" "$path")
        local create_time=$(stat -c "%y" "$path" | cut -d. -f1)
        local modify_time=$(stat -c "%y" "$path" | cut -d. -f1)
        info+="归属: user: $owner, group: $group"
        info+="\n权限: $access"
        info+="\n创建: $create_time"
        info+="\n修改: $modify_time"
        echo -e "$info"
    fi

    if grep -q "purge" <<< "$action"; then
        echo "移除组件..."
        if [ "$type" = "file" ]; then
            rm -f "$path"
        else
            rm -rf "$path"
        fi
        if [ $? -eq 0 ]; then
            echo "移除成功"
        else
            echo "移除失败"
        fi
    fi

    if grep -q "create" <<< "$action"; then
        echo "创建组件..."
        create "$component"
    fi

    echo -e ""
}

# 开始了
check_arch
check_env

allowlist_all="core,daemon,extui,route,udev,conf"
allowlist_status="core,daemon,extui,route,udev,conf"
allowlist_remove="core,daemon,extui,route,udev"
allowlist_install="core,daemon,extui,route,udev,conf"
allowlist_update="core,extui"

COMMAND="$(echo ${1:-status} | tr [:upper:] [:lower:])"

declare -A profile
profile["core"]="执行核心"
profile["daemon"]="守护服务"
profile["extui"]="监控面板"
profile["route"]="路由规则"
profile["udev"]="udev规则"
profile["conf"]="配置文件"

case "${COMMAND}" in
    status)
        if [ "$(service "show" | tail -n 1)" != "success" ]; then
            echo "服务状态查询失败, 继续..."
        else
            echo ""
        fi
        allowlist="${2:-$allowlist_status}"
        worklist="${2:-$allowlist_all}"
        ;;
    remove)
        if [ "$(service "stop" | tail -n 1)" != "success" ]; then
            echo "停止服务失败, 无法继续..."
            exit 1
        else
            echo ""
        fi
        allowlist="${2:-$allowlist_remove}"
        worklist="${2:-$allowlist_all}"
        ;;
    install)
        if [ "$(service "stop" | tail -n 1)" != "success" ]; then
            echo "停止服务失败, 无法继续..."
            exit 1
        else
            echo ""
        fi
        allowlist="${2:-$allowlist_install}"
        worklist="${2:-$allowlist_all}"
        ;;
    update)
        if [ "$(service "stop" | tail -n 1)" != "success" ]; then
            echo "停止服务失败, 无法继续..."
            exit 1
        else
            echo ""
        fi
        allowlist="${2:-$allowlist_update}"
        worklist="${2:-$allowlist_all}"
        ;;
    *)
        echo "Invalid command: ${COMMAND:-???}"
        exit 1
        ;;
esac

IFS=',' read -ra COMPONENTS <<< "$(echo "$worklist" | sed 's/, *\(.*\)/,\1/g' | tr [:upper:] [:lower:])"
for component in "${COMPONENTS[@]}"; do
    main "$COMMAND" "$component"
done

