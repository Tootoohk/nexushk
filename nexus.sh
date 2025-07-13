#!/bin/bash
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

NEXUS_DIR="$PWD/nexus"
SERVER_CONFIG_URL="https://github.com/Tootoohk/nexushk/releases/download/1/nexus_server.txt"
CLIENT_CONFIG_URL="https://github.com/Tootoohk/nexushk/releases/download/1/nexus_client.txt"

SERVER_ARM_URL="https://github.com/Tootoohk/nexushk/releases/download/1/nexus_server_arm"
CLIENT_ARM_URL="https://github.com/Tootoohk/nexushk/releases/download/1/nexus_client_arm"
SERVER_AMD_URL="https://github.com/Tootoohk/nexushk/releases/download/1/nexus_server_amd"
CLIENT_AMD_URL="https://github.com/Tootoohk/nexushk/releases/download/1/nexus_client_amd"

# 检查依赖
check_and_install_deps() {
    echo -e "${GREEN}更新系统软件包...${NC}"
    sudo apt update && sudo apt install -y curl wget jq unzip nodejs npm
    if ! command -v pm2 &>/dev/null; then
        echo -e "${GREEN}正在全局安装 pm2 ...${NC}"
        sudo npm install -g pm2
    else
        echo -e "${GREEN}pm2 已安装，尝试升级 ...${NC}"
        sudo npm update -g pm2
    fi

    if [ ! -d "$NEXUS_DIR" ]; then
        mkdir -p "$NEXUS_DIR"
        echo -e "${GREEN}已创建nexus目录：$NEXUS_DIR${NC}"
    fi

    cd "$NEXUS_DIR"
    echo -e "${GREEN}检测系统架构 ...${NC}"
    ARCH=$(uname -m)
    case $ARCH in
        x86_64|amd64)
            SERVER_BIN="nexus_server_amd"
            CLIENT_BIN="nexus_client_amd"
            SERVER_URL="$SERVER_AMD_URL"
            CLIENT_URL="$CLIENT_AMD_URL"
            ;;
        aarch64|arm64)
            SERVER_BIN="nexus_server_arm"
            CLIENT_BIN="nexus_client_arm"
            SERVER_URL="$SERVER_ARM_URL"
            CLIENT_URL="$CLIENT_ARM_URL"
            ;;
        *)
            echo -e "${RED}不支持的架构: $ARCH${NC}"
            exit 1
            ;;
    esac

    echo -e "${GREEN}下载服务端和客户端二进制 ...${NC}"
    wget -q --show-progress -O "$SERVER_BIN" "$SERVER_URL"
    wget -q --show-progress -O "$CLIENT_BIN" "$CLIENT_URL"
    wget -q --show-progress -O "nexus_server.txt" "$SERVER_CONFIG_URL"
    wget -q --show-progress -O "nexus_client.txt" "$CLIENT_CONFIG_URL"

    chmod +x "$SERVER_BIN" "$CLIENT_BIN"
    echo -e "${GREEN}已设置执行权限${NC}"
}

ask() {
    local PROMPT=$1
    local DEFAULT=$2
    local VAR
    read -p "$PROMPT [$DEFAULT]: " VAR
    echo "${VAR:-$DEFAULT}"
}

deploy_server() {
    cd "$NEXUS_DIR"
    echo -e "${GREEN}请输入服务端配置参数 ...${NC}"
    read -p "请输入钱包地址（多个用空格隔开）: " WALLET_ADDRESSES
    ADDR_ARR=($WALLET_ADDRESSES)
    PORT=$(ask "输入服务端初始端口" "18182")
    WORKER=$(ask "输入每个服务端worker数量" "5")
    QUEUE=$(ask "输入queue (建议: worker数×4)" "$((WORKER * 4))")

    for i in "${!ADDR_ARR[@]}"; do
        IDX=$((i+1))
        ADDR="${ADDR_ARR[$i]}"
        CUR_PORT=$((PORT + i))
        DIR="$NEXUS_DIR/nexus_server_$IDX"
        mkdir -p "$DIR"
        cp "$SERVER_BIN" "$DIR/"
        cp "nexus_server.txt" "$DIR/"
        cat > "$DIR/nexus_server.txt" <<EOF
address: $ADDR
port: $CUR_PORT
queue: $QUEUE
worker: $WORKER
EOF
        pm2 delete "服务端$IDX" &>/dev/null || true
        pm2 start "$DIR/$SERVER_BIN" --name "服务端$IDX"
        echo -e "${GREEN}服务端$IDX 启动成功，钱包：$ADDR，端口：$CUR_PORT${NC}"
    done
    pm2 save
}

# 获取当前客户端配置套数的最大编号
get_next_client_config_id() {
    cd "$NEXUS_DIR"
    max_cfg=0
    for d in nexus_client_*_*; do
        [[ -d "$d" ]] || continue
        cfg=$(echo $d | awk -F_ '{print $3}')
        [[ $cfg =~ ^[0-9]+$ ]] && (( cfg > max_cfg )) && max_cfg=$cfg
    done
    echo $((max_cfg+1))
}

# 可用于完整部署或批量追加新配置
deploy_client_multi() {
    cd "$NEXUS_DIR"
    if [ "$1" == "append" ]; then
        next_id=$(get_next_client_config_id)
        echo -e "${GREEN}自动分配新增套数起始编号为 $next_id${NC}"
        read -p "你要新增几套客户端配置文件？(建议输入1或更多): " CONFIG_COUNT
        [[ -z "$CONFIG_COUNT" || ! "$CONFIG_COUNT" =~ ^[0-9]+$ ]] && CONFIG_COUNT=1
        start_cfg=$next_id
    else
        read -p "你有几套客户端配置文件需要部署？(1 或更多): " CONFIG_COUNT
        [[ -z "$CONFIG_COUNT" || ! "$CONFIG_COUNT" =~ ^[0-9]+$ ]] && CONFIG_COUNT=1
        # 删除历史多开（完整部署覆盖）
        for d in nexus_client_*_*; do [ -d "$d" ] && rm -rf "$d"; done
        pm2 delete $(pm2 list | grep 客户端 | awk '{print $2}') &>/dev/null || true
        start_cfg=1
    fi

    declare -A CLIENT_INFO
    for ((cfg=0;cfg<CONFIG_COUNT;cfg++)); do
        id=$((start_cfg+cfg))
        echo -e "\n${GREEN}配置第 $id 套客户端参数...${NC}"
        HOST=$(ask "输入服务端IP (host) for config $id" "127.0.0.1")
        PORT=$(ask "输入服务端端口 (port) for config $id" "18182")
        COUNT=$(ask "此配置下客户端数量" "1")
        CLIENT_INFO["$id,host"]=$HOST
        CLIENT_INFO["$id,port"]=$PORT
        CLIENT_INFO["$id,count"]=$COUNT
    done

    for ((cfg=0;cfg<CONFIG_COUNT;cfg++)); do
        id=$((start_cfg+cfg))
        HOST=${CLIENT_INFO["$id,host"]}
        PORT=${CLIENT_INFO["$id,port"]}
        COUNT=${CLIENT_INFO["$id,count"]}
        for ((i=1;i<=COUNT;i++)); do
            DIR="$NEXUS_DIR/nexus_client_${id}_$i"
            mkdir -p "$DIR"
            cp "$CLIENT_BIN" "$DIR/"
            cp "nexus_client.txt" "$DIR/"
            cat > "$DIR/nexus_client.txt" <<EOF
host: $HOST
port: $PORT
EOF
            pm2 delete "客户端${id}_$i" &>/dev/null || true
            pm2 start "$DIR/$CLIENT_BIN" --name "客户端${id}_$i"
            echo -e "${GREEN}客户端${id}_$i 启动成功，连接 $HOST:$PORT${NC}"
        done
    done
    pm2 save
}

view_logs() {
    while true; do
        echo -e "\n${GREEN}1. 查看服务端日志\n2. 查看客户端日志\n3. 返回主菜单${NC}"
        read -p "请选择: " opt
        case $opt in
            1)
                pm2 list | grep 服务端 && pm2 logs 服务端 --lines 100
                ;;
            2)
                cd "$NEXUS_DIR"
                configs=()
                for d in nexus_client_*_*; do
                    [[ -d "$d" ]] || continue
                    cfg=$(echo $d | awk -F_ '{print $3}')
                    [[ " ${configs[*]} " =~ " $cfg " ]] || configs+=($cfg)
                done
                if [ ${#configs[@]} -eq 0 ]; then
                    echo "没有发现任何客户端实例"
                    continue
                fi
                echo "现有客户端配置套数: ${#configs[@]}"
                for idx in "${!configs[@]}"; do
                    echo "$((idx+1)). 查看第${configs[$idx]}套客户端日志"
                done
                read -p "请选择要查看的套数(输入编号, 0返回): " num
                [[ "$num" == "0" ]] && continue
                cfgid=${configs[$((num-1))]}
                pm2 list | grep 客户端${cfgid}_ && pm2 logs 客户端${cfgid}_ --lines 100
                ;;
            3) break ;;
            *) echo "无效输入" ;;
        esac
        echo -e "${GREEN}\n按 CTRL+C 返回主菜单 ...${NC}"
    done
}

edit_config() {
    echo -e "\n${GREEN}1. 修改服务端配置\n2. 修改客户端配置\n3. 返回主菜单${NC}"
    read -p "请选择: " opt
    case $opt in
        1)
            cd "$NEXUS_DIR"
            ls -d nexus_server_* 2>/dev/null || { echo "未发现服务端"; return; }
            echo "已有服务端文件夹："
            for d in nexus_server_*; do
                idx=$(echo $d | awk -F_ '{print $3}')
                WALLET=$(grep address $d/nexus_server.txt | awk '{print $2}')
                echo "$idx - 钱包: $WALLET"
            done
            read -p "输入要修改的服务端序号（如1），全部修改请输入 all: " target
            if [[ $target == "all" ]]; then
                PORT=$(ask "输入服务端初始端口" "18182")
                WORKER=$(ask "输入worker" "5")
                QUEUE=$(ask "输入queue" "$((WORKER*4))")
                idx=1
                for d in nexus_server_*; do
                    WALLET=$(grep address $d/nexus_server.txt | awk '{print $2}')
                    CUR_PORT=$((PORT+idx-1))
                    cat > "$d/nexus_server.txt" <<EOF
address: $WALLET
port: $CUR_PORT
queue: $QUEUE
worker: $WORKER
EOF
                    pm2 restart "服务端$idx"
                    idx=$((idx+1))
                done
            else
                d="nexus_server_$target"
                if [ ! -d "$d" ]; then echo "文件夹不存在"; return; fi
                ADDR=$(ask "输入新钱包地址" "$(grep address $d/nexus_server.txt | awk '{print $2}')")
                PORT=$(ask "输入端口" "$(grep port $d/nexus_server.txt | awk '{print $2}')")
                WORKER=$(ask "输入worker" "$(grep worker $d/nexus_server.txt | awk '{print $2}')")
                QUEUE=$(ask "输入queue" "$(grep queue $d/nexus_server.txt | awk '{print $2}')")
                cat > "$d/nexus_server.txt" <<EOF
address: $ADDR
port: $PORT
queue: $QUEUE
worker: $WORKER
EOF
                pm2 restart "服务端$target"
            fi
            pm2 save
            ;;
        2)
            cd "$NEXUS_DIR"
            configs=()
            for d in nexus_client_*_*; do
                [[ -d "$d" ]] || continue
                cfg=$(echo $d | awk -F_ '{print $3}')
                [[ " ${configs[*]} " =~ " $cfg " ]] || configs+=($cfg)
            done
            if [ ${#configs[@]} -eq 0 ]; then
                echo "未发现任何客户端配置实例"
                return
            fi
            echo "当前有${#configs[@]}套客户端配置"
            for idx in "${!configs[@]}"; do
                echo "$((idx+1)). 修改第${configs[$idx]}套客户端配置"
            done
            echo "$(( ${#configs[@]}+1 )). 重新设定全部客户端多开（删除重建）"
            echo "0. 返回主菜单"
            read -p "请选择(编号): " num
            if [[ "$num" == "0" ]]; then return; fi
            if [[ "$num" -eq $(( ${#configs[@]}+1 )) ]]; then
                pm2 delete $(pm2 list | grep 客户端 | awk '{print $2}') &>/dev/null || true
                rm -rf nexus_client_*_*
                deploy_client_multi full
                return
            fi
            cfgid=${configs[$((num-1))]}
            count=$(ls -d nexus_client_${cfgid}_* 2>/dev/null | wc -l)
            HOST=$(ask "输入host" "$(grep host nexus_client_${cfgid}_1/nexus_client.txt | awk '{print $2}')")
            PORT=$(ask "输入port" "$(grep port nexus_client_${cfgid}_1/nexus_client.txt | awk '{print $2}')")
            for ((i=1;i<=count;i++)); do
                d="nexus_client_${cfgid}_$i"
                cat > "$d/nexus_client.txt" <<EOF
host: $HOST
port: $PORT
EOF
                pm2 restart "客户端${cfgid}_$i"
            done
            pm2 save
            ;;
        3) ;;
        *) echo "无效输入" ;;
    esac
}

delete_all() {
    echo -e "${RED}1. 删除并停止所有服务端\n2. 删除并停止所有客户端\n3. 删除指定客户端配置套数\n4. 返回主菜单${NC}"
    read -p "请选择: " opt
    case $opt in
        1)
            pm2 delete $(pm2 list | grep 服务端 | awk '{print $2}') &>/dev/null || true
            rm -rf "$NEXUS_DIR"/nexus_server_*
            echo -e "${RED}服务端相关全部已删除${NC}"
            ;;
        2)
            pm2 delete $(pm2 list | grep 客户端 | awk '{print $2}') &>/dev/null || true
            rm -rf "$NEXUS_DIR"/nexus_client_*_*
            echo -e "${RED}客户端相关全部已删除${NC}"
            ;;
        3)
            cd "$NEXUS_DIR"
            configs=()
            for d in nexus_client_*_*; do
                [[ -d "$d" ]] || continue
                cfg=$(echo $d | awk -F_ '{print $3}')
                [[ " ${configs[*]} " =~ " $cfg " ]] || configs+=($cfg)
            done
            if [ ${#configs[@]} -eq 0 ]; then
                echo "未发现任何客户端配置实例"
                return
            fi
            echo "当前有${#configs[@]}套客户端配置"
            for idx in "${!configs[@]}"; do
                echo "$((idx+1)). 删除第${configs[$idx]}套客户端"
            done
            echo "0. 返回主菜单"
            read -p "请选择(编号): " num
            if [[ "$num" == "0" ]]; then return; fi
            cfgid=${configs[$((num-1))]}
            pm2 delete $(pm2 list | grep 客户端${cfgid}_ | awk '{print $2}') &>/dev/null || true
            rm -rf nexus_client_${cfgid}_*
            echo -e "${RED}第${cfgid}套客户端相关全部已删除${NC}"
            ;;
        4) ;;
        *) echo "无效输入" ;;
    esac
}

update_bin_url() {
    echo -e "${GREEN}检测系统架构 ...${NC}"
    ARCH=$(uname -m)
    echo -e "${GREEN}当前系统架构: $ARCH${NC}"
    read -p "请输入新的服务端二进制下载地址: " new_server_url
    read -p "请输入新的客户端二进制下载地址: " new_client_url
    cd "$NEXUS_DIR"
    if [[ $ARCH == "x86_64" || $ARCH == "amd64" ]]; then
        wget -q --show-progress -O nexus_server_amd "$new_server_url"
        wget -q --show-progress -O nexus_client_amd "$new_client_url"
        chmod +x nexus_server_amd nexus_client_amd
    elif [[ $ARCH == "aarch64" || $ARCH == "arm64" ]]; then
        wget -q --show-progress -O nexus_server_arm "$new_server_url"
        wget -q --show-progress -O nexus_client_arm "$new_client_url"
        chmod +x nexus_server_arm nexus_client_arm
    fi
    echo -e "${GREEN}二进制已更新${NC}"
}

main_menu() {
    while true; do
        echo -e "\n${GREEN}======== Nexus 一键管理脚本 ========
1. 依赖检查与环境准备
2. 部署/运行服务端
3. 部署/运行客户端（会覆盖重建所有客户端）
4. 查看pm2日志
5. 修改服务端/客户端配置并重启
6. 一键删除/单独删除
7. 更新程序下载地址
8. 新增客户端配置套数（不中断已有多开）
0. 退出
===================================${NC}"
        read -p "请选择功能: " choice
        case $choice in
            1) check_and_install_deps ;;
            2) deploy_server ;;
            3) deploy_client_multi full ;;
            4) view_logs ;;
            5) edit_config ;;
            6) delete_all ;;
            7) update_bin_url ;;
            8) deploy_client_multi append ;;
            0) echo "Bye~" && exit 0 ;;
            *) echo "无效输入" ;;
        esac
    done
}

main_menu
