#!/bin/bash

# 定义常量
VERSION_URL="https://forums.e-hentai.org/lofiversion/index.php/t234458.html"
DOWNLOAD_BASE_URL="https://repo.e-hentai.org/hath/"
INSTALL_DIR="/opt/HentaiAtHome"
SERVICE_NAME="ehentaiathome" # 服务名称，不含后缀
CLIENT_LOGIN_DIR="${INSTALL_DIR}/data"
CLIENT_LOGIN_FILE="${CLIENT_LOGIN_DIR}/client_login"
# 日志文件路径
SERVICE_LOG_FILE="${INSTALL_DIR}/output.log"
LOCAL_VERSION_FILE="${INSTALL_DIR}/.hath_version" # 存储本地版本号的文件

# 常见的JVM优化选项：
# -Xms512m -Xmx1G: 设置初始堆内存为512MB，最大堆内存为1GB。请根据您的服务器内存大小调整。
# -XX:+UseG1GC -XX:MaxGCPauseMillis=200 -Djava.awt.headless=true
JVM_OPTS="-Xms512m -Xmx1G -XX:+UseG1GC -XX:MaxGCPauseMillis=200 -Djava.awt.headless=true"

# 全局变量，用于存储检测到的系统信息和Hath状态
PKG_MANAGER=""
JAVA_PACKAGE=""
INIT_SYSTEM=""
SERVICE_FILE_PATH=""
HATH_STATUS="未安装" # 初始状态
LOCAL_VERSION="未安装" # 本地安装的Hath版本
REMOTE_VERSION="未知" # 远程可用的Hath最新版本

# --- 辅助函数 ---

# 检查是否以root用户运行
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "错误：请以root用户运行此脚本。" >&2
        exit 1
    fi
}

# 自动检测当前Linux发行版及其包管理器和初始化系统
detect_os() {
    # 默认值，如果未检测到特定系统，则假定为Systemd
    INIT_SYSTEM="systemd"
    SERVICE_FILE_PATH="/etc/systemd/system/${SERVICE_NAME}.service"

    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "$ID" in
            debian|ubuntu)
                echo "检测到系统: $ID ($VERSION_ID)"
                PKG_MANAGER="apt"
                JAVA_PACKAGE="openjdk-17-jre-headless"
                ;;
            fedora)
                echo "检测到系统: $ID ($VERSION_ID)"
                PKG_MANAGER="dnf"
                JAVA_PACKAGE="java-17-openjdk-headless"
                ;;
            centos|rhel|rocky|almalinux) # 添加 almalinux 兼容性
                echo "检测到系统: $ID ($VERSION_ID)"
                if command -v dnf &> /dev/null; then
                    PKG_MANAGER="dnf"
                else
                    PKG_MANAGER="yum"
                fi
                JAVA_PACKAGE="java-17-openjdk-headless"
                ;;
            arch)
                echo "检测到系统: $ID ($VERSION_ID)"
                PKG_MANAGER="pacman"
                JAVA_PACKAGE="jre17-openjdk-headless"
                ;;
            alpine)
                echo "检测到系统: $ID ($VERSION_ID)"
                PKG_MANAGER="apk"
                JAVA_PACKAGE="openjdk17-jre-headless"
                INIT_SYSTEM="openrc" # Alpine 使用 OpenRC
                SERVICE_FILE_PATH="/etc/init.d/${SERVICE_NAME}" # OpenRC init script path
                ;;
            *)
                echo "警告：检测到未知系统 ($ID)。将尝试使用常见包管理器和 Systemd。" >&2
                PKG_MANAGER="" # Fallback, will rely on command -v later
                JAVA_PACKAGE=""
                ;;
        esac
    else
        echo "警告：无法检测系统信息，将尝试使用常见包管理器和 Systemd。" >&2
        PKG_MANAGER=""
        JAVA_PACKAGE=""
    fi
}

# 使用对应的包管理器安装包
install_package() {
    local package_name=$1
    echo "正在尝试使用 $PKG_MANAGER 安装 $package_name..."
    case "$PKG_MANAGER" in
        apt)
            apt update && apt install -y "$package_name"
            ;;
        dnf)
            dnf install -y "$package_name"
            ;;
        yum)
            yum install -y "$package_name"
            ;;
        pacman)
            pacman -Sy --noconfirm "$package_name"
            ;;
        apk)
            apk update && apk add "$package_name"
            ;;
        *)
            # Fallback for undetected systems or specific tools like curl/unzip if pkg_manager not set
            if command -v apt &> /dev/null; then
                apt update && apt install -y "$package_name"
            elif command -v dnf &> /dev/null; then
                dnf install -y "$package_name"
            elif command -v yum &> /dev/null; then
                yum install -y "$package_name"
            elif command -v pacman &> /dev/null; then
                pacman -Sy --noconfirm "$package_name"
            elif command -v apk &> /dev/null; then
                apk update && apk add "$package_name"
            else
                echo "错误：未检测到支持的包管理器，无法安装 $package_name。请手动安装。" >&2
                return 1
            fi
            ;;
    esac
    return $?
}

# 检查并安装前置依赖
check_and_install_dependencies() {
    echo "--- 正在检查并安装所需依赖 ---"
    local required_commands=("curl" "unzip")

    # 检查 curl 和 unzip
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            echo "$cmd 未安装，正在尝试安装..."
            install_package "$cmd"
            if [ $? -ne 0 ]; then
                echo "错误：安装 $cmd 失败，请检查网络或软件源。" >&2
                exit 1
            fi
        fi
    done

    # 检查 Java
    if ! command -v java &> /dev/null; then
        echo "Java 未安装，正在尝试安装 OpenJDK 17 JRE..."
        install_package "$JAVA_PACKAGE"
        if [ $? -ne 0 ]; then
            echo "错误：安装 Java ($JAVA_PACKAGE) 失败。请检查错误信息或尝试手动安装 Java 17 JRE。" >&2
            exit 1
        fi
    fi
    echo "所有依赖（curl, unzip, java）均已安装。"
    echo "--- 依赖检查完成 ---"
}

# 获取最新版本号
get_latest_version() {
    local content
    content=$(curl -s "$VERSION_URL")
    if [ $? -ne 0 ]; then
        REMOTE_VERSION = "错误：无法获取网页内容。请检查网络连接。" >&2
        return 1
    fi

    local version
    version=$(echo "$content" | grep -A 20 "postname.*Tenboro" | grep -oP 'HentaiAtHome_\K[0-9\.]+(?=\.zip)')

    if [ -z "$version" ]; then
        REMOTE_VERSION = "错误：未找到最新版本号。" >&2
        return 1
    fi

    REMOTE_VERSION="$version" # 更新全局变量
    return 0
}

# 读取本地版本号
get_local_version() {
    if [ -f "$LOCAL_VERSION_FILE" ]; then
        LOCAL_VERSION=$(cat "$LOCAL_VERSION_FILE")
    else
        LOCAL_VERSION="未安装"
    fi
}

# 创建或修改登录配置文件
create_or_modify_login_config() {
    echo "--- 正在创建/修改登录配置文件 ---"
    echo "请在 Hentai@Home 设置页面获取 Client ID 和 Client Key。"
    echo "登录地址：https://e-hentai.org/hentaiathome.php"

    local client_id=""
    local client_key=""

    while [ -z "$client_id" ] || [ -z "$client_key" ]; do
        read -rp "请输入 Client ID: " client_id
        read -rp "请输入 Client Key: " client_key

        if [ -z "$client_id" ] || [ -z "$client_key" ]; then
            echo "错误：Client ID 或 Client Key 不能为空。请重新输入。" >&2
        fi
    done

    mkdir -p "$CLIENT_LOGIN_DIR"
    if [ $? -ne 0 ]; then
        echo "错误：无法创建目录 $CLIENT_LOGIN_DIR。" >&2
        return 1
    fi

    echo "${client_id}-${client_key}" > "$CLIENT_LOGIN_FILE"
    if [ $? -ne 0 ]; then
        echo "错误：无法写入登录配置文件 $CLIENT_LOGIN_FILE。" >&2
        return 1
    fi

    echo "登录配置文件已创建/更新：$CLIENT_LOGIN_FILE"
    echo "--- 登录配置文件创建/修改完成 ---"
    return 0
}

# 管理服务 (启动/停止/重启/启用/禁用)
manage_service() {
    local action=$1 # e.g., start, stop, restart, enable, disable
    local service_name_full
    
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        service_name_full="${SERVICE_NAME}.service"
    elif [ "$INIT_SYSTEM" = "openrc" ]; then
        service_name_full="${SERVICE_NAME}" # OpenRC commands use the plain service name
    else
        echo "错误：未知的初始化系统，无法管理服务。" >&2
        return 1
    fi

    echo "正在尝试 $action HentaiAtHome 服务..."

    if [ "$INIT_SYSTEM" = "systemd" ]; then
        systemctl "$action" "$service_name_full"
        if [ $? -ne 0 ]; then
            echo "错误：Systemd 服务 $action 失败。" >&2
            return 1
        fi
    elif [ "$INIT_SYSTEM" = "openrc" ]; then
        # OpenRC services are managed by their script in /etc/init.d/
        # enable/disable use rc-update add/del
        case "$action" in
            start|stop|restart)
                "$SERVICE_FILE_PATH" "$action"
                ;;
            enable)
                rc-update add "$service_name_full" default
                ;;
            disable)
                rc-update del "$service_name_full" default
                ;;
            *)
                echo "错误：OpenRC 不支持的动作: $action" >&2
                return 1
                ;;
        esac

        if [ $? -ne 0 ]; then
            echo "错误：OpenRC 服务 $action 失败。" >&2
            return 1
        fi
    else
        echo "错误：未知的初始化系统，无法管理服务。" >&2
        return 1
    fi
    return 0
}

# 创建服务文件 (根据 Init System 类型)
create_service_file() {
    echo "正在创建服务文件 $SERVICE_FILE_PATH..."
    local service_description="EhentaiAtHome Client - v${REMOTE_VERSION:-Unknown}" # 包含版本号

    if [ "$INIT_SYSTEM" = "systemd" ]; then
        SERVICE_CONTENT="[Unit]
Description=${service_description}
Documentation=https://e-hentai.org/hentaiathome.php
After=network.target syslog.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
ExecStart=/usr/bin/java ${JVM_OPTS} -jar ${INSTALL_DIR}/HentaiAtHome.jar
KillMode=mixed
User=root
StandardOutput=file:${INSTALL_DIR}/output.log

[Install]
WantedBy=multi-user.target
"
        echo "$SERVICE_CONTENT" | tee "$SERVICE_FILE_PATH" > /dev/null
    elif [ "$INIT_SYSTEM" = "openrc" ]; then
        # OpenRC init script template
        SERVICE_CONTENT="#!/sbin/openrc-run

name=\"HentaiAtHome\"
description=\"${service_description}\"
command=\"/usr/bin/java\"
command_args=\"${JVM_OPTS} -jar ${INSTALL_DIR}/HentaiAtHome.jar\"
pidfile=\"/var/run/${SERVICE_NAME}.pid\"
command_user=\"root\"
start_stop_daemon_args=\"--background --make-pidfile --pidfile /var/run/${SERVICE_NAME}.pid --output ${SERVICE_LOG_FILE}\"

depend() {
    need net
    use logger
}
"
        echo "$SERVICE_CONTENT" | tee "$SERVICE_FILE_PATH" > /dev/null
        chmod +x "$SERVICE_FILE_PATH" # OpenRC init scripts need execute permission
    else
        echo "错误：不支持的初始化系统，无法创建服务文件。" >&2
        return 1
    fi

    if [ $? -ne 0 ]; then
        echo "错误：创建服务文件失败。" >&2
        return 1
    fi
    echo "服务文件已创建。"
    return 0
}


# 安装 HentaiAtHome
install_hath() {
    echo "--- 正在执行 HentaiAtHome 安装程序 ---"

    # 在安装前，先获取远程版本号，以便在重装提示中使用
    get_latest_version || return 1

    # 检查是否已安装
    if [ -d "$INSTALL_DIR" ] && [ -f "$SERVICE_FILE_PATH" ]; then
        get_local_version # 获取当前本地版本
        echo "HentaiAtHome 似乎已安装在 $INSTALL_DIR (当前版本: ${LOCAL_VERSION})。"
        read -rp "远程最新版本为 ${REMOTE_VERSION}。是否要重新安装/更新？(y/N) " reinstall_confirm
        if [[ ! "$reinstall_confirm" =~ ^[Yy]$ ]]; then
            echo "操作已取消。"
            return 0
        fi
        echo "正在执行重新安装/更新..."
        # 如果是重装，先尝试停止和禁用现有服务（即使之前安装失败，这些命令也应安全）
        manage_service "stop" "" || true
        manage_service "disable" "" || true
        if [ "$INIT_SYSTEM" = "systemd" ]; then
            systemctl daemon-reload &> /dev/null || true
        fi
    fi

    check_and_install_dependencies || return 1

    # 如果之前没有获取成功，这里再获取一次
    if [ "$REMOTE_VERSION" = "未知" ]; then
        get_latest_version || return 1
    fi

    if [ -z "$REMOTE_VERSION" ] || [ "$REMOTE_VERSION" = "未知" ]; then
        echo "错误：未能获取到有效的版本号，无法继续安装。" >&2
        return 1
    fi

    local download_url="${DOWNLOAD_BASE_URL}HentaiAtHome_${REMOTE_VERSION}.zip"
    local zip_file="/tmp/HentaiAtHome_${REMOTE_VERSION}.zip"

    echo "正在下载软件 $download_url 到 $zip_file..."
    curl -s -o "$zip_file" "$download_url"
    if [ $? -ne 0 ]; then
        echo "错误：下载软件失败。请检查网络连接或 $download_url 是否有效。" >&2
        return 1
    fi
    echo "下载完成。"

    echo "正在准备安装目录 $INSTALL_DIR..."
    # 重新安装时会清空，如果不存在则创建
    if [ -d "$INSTALL_DIR" ]; then
        echo "目录 $INSTALL_DIR 已存在，正在清空内容..."
        rm -rf "$INSTALL_DIR"/*
    else
        echo "正在创建目录 $INSTALL_DIR..."
        mkdir -p "$INSTALL_DIR"
    fi
    if [ $? -ne 0 ]; then
        echo "错误：无法创建或清空安装目录 $INSTALL_DIR。" >&2
        return 1
    fi

    echo "正在解压软件到 $INSTALL_DIR..."
    unzip -o "$zip_file" -d "$INSTALL_DIR"
    if [ $? -ne 0 ]; then
        echo "解压失败。尝试处理可能存在的子目录..." >&2
        local extracted_subdir=$(find "$INSTALL_DIR" -maxdepth 1 -type d -name "HentaiAtHome_*" -print -quit)
        if [ -n "$extracted_subdir" ] && [ -d "$extracted_subdir" ]; then
            echo "检测到解压到子目录：$extracted_subdir。正在移动内容..."
            mv "$extracted_subdir"/* "$INSTALL_DIR"/
            rmdir "$extracted_subdir"
            if [ $? -ne 0 ]; then
                echo "错误：移动解压内容失败。请手动检查 $INSTALL_DIR 目录。" >&2
                return 1
            fi
        else
            echo "错误：无法确定解压失败原因或无法自动修复解压路径。请手动检查 $INSTALL_DIR 目录和 $zip_file。" >&2
            return 1
        fi
    fi
    echo "解压完成。"

    echo "正在保存本地版本号 ${REMOTE_VERSION} 到 ${LOCAL_VERSION_FILE}..."
    echo "${REMOTE_VERSION}" > "${LOCAL_VERSION_FILE}"
    LOCAL_VERSION="${REMOTE_VERSION}" # 更新全局变量
    
    echo "正在删除临时下载文件 $zip_file..."
    rm -f "$zip_file"

    create_or_modify_login_config || return 1 # 在解压完成后创建登录配置文件

    create_service_file || return 1 # 根据检测到的init系统创建服务文件

    if [ "$INIT_SYSTEM" = "systemd" ]; then
        echo "正在重新加载Systemd守护进程..."
        systemctl daemon-reload
        if [ $? -ne 0 ]; then
            echo "错误：Systemd守护进程重新加载失败。" >&2
            return 1
        fi
    fi

    manage_service "enable" "" || return 1
    manage_service "start" "" || return 1

    echo "HentaiAtHome 服务已成功启动！"
    echo "您可以通过 'systemctl status $SERVICE_NAME' (Systemd) 或 '/etc/init.d/$SERVICE_NAME status' (OpenRC) 查看服务状态。"
    return 0
}

# 卸载 HentaiAtHome
uninstall_hath() {
    echo "--- 正在执行 HentaiAtHome 卸载程序 ---"
    read -rp "警告：此操作将停止服务，并删除所有相关文件 ($INSTALL_DIR, $SERVICE_FILE_PATH, 和临时文件)。确定要继续吗？(y/N) " confirm_first
    if [[ ! "$confirm_first" =~ ^[Yy]$ ]]; then
        echo "卸载已取消。"
        return 0
    fi

    # 第二次确认
    read -rp "再次确认：您确定要彻底卸载 HentaiAtHome 吗？客户端数据也会删除会影响 HentaiAtHome 里的质量和信任，此操作不可逆！(请输入 'yes' 继续): " confirm_second
    if [[ ! "$confirm_second" == "yes" ]]; then
        echo "卸载已取消。"
        return 0
    fi

    echo "正在停止并禁用服务 $SERVICE_NAME..."
    # 尝试停止和禁用，即使失败也不中断，因为文件可能已删除
    manage_service "stop" "" || true
    manage_service "disable" "" || true
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        systemctl daemon-reload &> /dev/null || true
    fi
    echo "服务已停止并禁用。"

    echo "正在删除服务文件 $SERVICE_FILE_PATH..."
    rm -f "$SERVICE_FILE_PATH"
    if [ $? -ne 0 ]; then
        echo "警告：删除服务文件失败，请手动检查。" >&2
    fi

    echo "正在删除安装目录 $INSTALL_DIR..."
    rm -rf "$INSTALL_DIR"
    if [ $? -ne 0 ]; then
        echo "警告：删除安装目录失败，请手动检查。" >&2
    fi

    echo "正在清理临时下载文件..."
    rm -f /tmp/HentaiAtHome_*.zip

    echo "HentaiAtHome 已成功卸载。"
    # 清除本地版本文件
    rm -f "$LOCAL_VERSION_FILE"
    LOCAL_VERSION="未知"
    return 0
}

# 修改登录配置并重启服务
modify_login_and_restart_service() {
    echo "--- 正在修改登录配置并重启服务 ---"
    if [ ! -d "$INSTALL_DIR" ] || [ ! -f "$SERVICE_FILE_PATH" ]; then
        echo "错误：HentaiAtHome 似乎未安装或安装不完整。请先执行安装操作。" >&2
        return 1
    fi

    create_or_modify_login_config || return 1

    echo "正在重启服务 $SERVICE_NAME 以应用新的配置..."
    manage_service "restart" ""
    if [ $? -ne 0 ]; then
        echo "错误：重启服务失败。请手动检查服务状态。" >&2
        echo "Systemd: 'systemctl status ${SERVICE_NAME}.service'" >&2
        echo "OpenRC: '/etc/init.d/${SERVICE_NAME} status'" >&2
        return 1
    fi

    echo "服务已成功重启，新登录配置已应用。"
    return 0
}

# 监听服务日志
monitor_service_logs() {
    echo "--- 正在监听 HentaiAtHome 服务日志 ($SERVICE_LOG_FILE) ---"
    if [ ! -f "$SERVICE_LOG_FILE" ]; then
        echo "警告：日志文件不存在或尚未创建。服务可能尚未运行或未写入日志。" >&2
        echo "请检查服务状态。" >&2
        echo "Systemd: 'systemctl status ${SERVICE_NAME}.service'" >&2
        echo "OpenRC: '/etc/init.d/${SERVICE_NAME} status'" >&2
        return 1
    fi

    echo "按 Ctrl+C 退出日志监听。"
    tail -f "$SERVICE_LOG_FILE"
    echo "--- 日志监听已退出 ---"
    return 0
}

# 获取 HentaiAtHome 服务状态
get_hath_status() {
    if [ ! -d "$INSTALL_DIR" ] || [ ! -f "$SERVICE_FILE_PATH" ]; then
        HATH_STATUS="未安装"
        return
    fi

    local status_output
    local service_name_full
    
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        service_name_full="${SERVICE_NAME}.service"
        status_output=$(systemctl is-active "$service_name_full" 2>/dev/null)
        if [ "$status_output" = "active" ]; then
            HATH_STATUS="已启动"
        else
            HATH_STATUS="已停止"
        fi
    elif [ "$INIT_SYSTEM" = "openrc" ]; then
        service_name_full="${SERVICE_NAME}"
        status_output=$(rc-service "$service_name_full" status 2>/dev/null)
        if echo "$status_output" | grep -qi "status: started"; then
            HATH_STATUS="已启动"
        else
            HATH_STATUS="已停止"
        fi
    else
        HATH_STATUS="未知状态 (Init系统不支持)"
    fi
}

# 启动 HentaiAtHome 服务
start_hath_service() {
    get_hath_status # 刷新当前状态
    if [ "$HATH_STATUS" = "已启动" ]; then
        echo "HentaiAtHome 服务已在运行中。"
        return 0
    elif [ "$HATH_STATUS" = "未安装" ]; then
        echo "HentaiAtHome 尚未安装，无法启动。请先执行安装操作。"
        return 1
    fi

    manage_service "start" ""
    if [ $? -eq 0 ]; then
        echo "HentaiAtHome 服务已成功启动。"
    else
        echo "HentaiAtHome 服务启动失败，请检查日志。"
    fi
}

# 停止 HentaiAtHome 服务
stop_hath_service() {
    get_hath_status # 刷新当前状态
    if [ "$HATH_STATUS" = "已停止" ] || [ "$HATH_STATUS" = "未安装" ]; then
        echo "HentaiAtHome 服务未在运行或未安装，无需停止。"
        return 0
    fi

    manage_service "stop" ""
    if [ $? -eq 0 ]; then
        echo "HentaiAtHome 服务已成功停止。"
    else
        echo "HentaiAtHome 服务停止失败，请检查日志。"
    fi
}

# --- 主交互逻辑 ---

check_root
detect_os # 在脚本开始时检测系统

while true; do
    clear # 清屏以刷新状态显示
    get_local_version # 获取本地版本
    get_latest_version # 获取远程版本
    get_hath_status # 每次显示菜单前更新状态

    echo "--- HentaiAtHome 跨平台管理脚本 ---"
    echo "系统: ${ID_LIKE:-$ID} (或 $ID)"
    echo "包管理器: ${PKG_MANAGER}"
    echo "Java 版本: ${JAVA_PACKAGE}"
    echo "服务管理: ${INIT_SYSTEM}"
    echo "服务文件路径: ${SERVICE_FILE_PATH}"
    echo "------------------------------------"

    echo "HentaiAtHome 服务状态: ${HATH_STATUS}" # 显示当前服务状态
    echo "本地版本: ${LOCAL_VERSION}"
    echo "最新版本: ${REMOTE_VERSION}"
    echo "------------------------------------"

    echo "请选择一个操作："
    echo "  1) 安装/更新 HentaiAtHome"
    echo "  2) 卸载 HentaiAtHome"
    echo "  3) 修改登录配置并重启服务"
    echo "  4) 监听服务日志 (排错)"

    # 根据服务状态显示启动/停止选项
    if [ "$HATH_STATUS" = "已停止" ]; then
        echo "  5) 启动 HentaiAtHome 服务"
    elif [ "$HATH_STATUS" = "已启动" ]; then
        echo "  6) 停止 HentaiAtHome 服务"
    fi
    
    echo "  7) 退出"
    read -rp "请输入您的选择: " choice

    case "$choice" in
        1)
            install_hath # 此函数现在也处理更新逻辑
            read -rp "按任意键继续..."
            ;;
        2)
            uninstall_hath
            read -rp "按任意键继续..."
            ;;
        3)
            modify_login_and_restart_service
            read -rp "按任意键继续..."
            ;;
        4)
            monitor_service_logs
            read -rp "按任意键继续..."
            ;;
        5)
            # 只有当 HATH_STATUS 为 "已停止" 时才接受 5 选项
            if [ "$HATH_STATUS" = "已停止" ]; then
                start_hath_service
                read -rp "按任意键继续..."
            else
                echo "无效的选择。服务状态不允许当前操作。"
                read -rp "按任意键继续..."
            fi
            ;;
        6)
            # 只有当 HATH_STATUS 为 "已启动" 时才接受 6 选项
            if [ "$HATH_STATUS" = "已启动" ]; then
                stop_hath_service
                read -rp "按任意键继续..."
            else
                echo "无效的选择。服务状态不允许当前操作。"
                read -rp "按任意键继续..."
            fi
            ;;
        7)
            echo "脚本已退出。"
            exit 0
            ;;
        *)
            echo "无效的选择。请根据菜单提示输入有效数字。" >&2
            read -rp "按任意键继续..."
            ;;
    esac
done