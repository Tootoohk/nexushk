#!/bin/bash

set -e

GREEN='\033[0;32m'
NC='\033[0m'

NEXUS_DIR="$HOME/nexus"
BIN_DIR="$NEXUS_DIR/bin"
CFG_DIR="$NEXUS_DIR/cfg"

mkdir -p "$BIN_DIR" "$CFG_DIR"

function check_dependencies() {
    echo -e "${GREEN}>>> 检查/安装依赖${NC}"
    apt update && apt install -y curl wget jq unzip nodejs npm
    if ! command -v pm2 >/dev/null 2>&1; then
        npm install -g pm2
    fi
    echo -e "${GREEN}依赖检查完毕${NC}"
}

function detect_arch() {
    arch=$(uname -m)
    if [[ "$arch" == "x86_64" ]]; then
        echo "amd"
    elif [[ "$arch" == "aarch64" ]] || [[ "$arch" == arm* ]] || [[ "$arch" == "arm64" ]]; then
        echo "arm"
    else
        echo "amd"
    fi
}


function download_bins_and_cfgs() {
    cd "$BIN_DIR"
    arch=$(detect_arch)
    [[ ! -f "nexus_server_${arch}" ]] && wget -q -O "nexus_server_${arch}" "https://github.com/Tootoohk/nexushk/releases/download/1/nexus_server_${arch}"
    [[ ! -f "nexus_client_${arch}" ]] && wget -q -O "nexus_client_${arch}" "https://github.com/Tootoohk/nexushk/releases/download/1/nexus_client_${arch}"
    chmod +x "nexus_server_${arch}" "nexus_client_${arch}"
    cd "$CFG_DIR"
    [[ ! -f "nexus_server.txt" ]] && wget -q -O nexus_server.txt "https://github.com/Tootoohk/nexushk/releases/download/1/nexus_server.txt"
    [[ ! -f "nexus_client.txt" ]] && wget -q -O nexus_client.txt "https://github.com/Tootoohk/nexushk/releases/download/1/nexus_client.txt"
    echo -e "${GREEN}程序及配置文件下载/校验完毕${NC}"
}

function deploy_servers() {
    cd "$NEXUS_DIR"
    arch=$(detect_arch)
    if [[ ! -f "$BIN_DIR/nexus_server_${arch}" ]]; then
        echo "未检测到服务端程序，自动下载..."
        download_bins_and_cfgs
    fi
    read -p "请输入需要部署服务端实例的数量: " count
    for ((i=1;i<=count;i++)); do
        server_dir="$NEXUS_DIR/server_$i"
        mkdir -p "$server_dir"
        cp "$BIN_DIR/nexus_server_${arch}" "$server_dir/"
        cp "$CFG_DIR/nexus_server.txt" "$server_dir/nexus_server.txt"
        read -p "服务端 $i 钱包地址: " wallet
        read -p "服务端 $i 端口[默认18182]: " port
        port=${port:-18182}
        read -p "服务端 $i worker数量: " worker
        queue=$((worker*4))
        cat > "$server_dir/nexus_server.txt" <<EOF
address: $wallet
port: $port
queue: $queue
worker: $worker
EOF
        pm2 delete server_$i >/dev/null 2>&1 || true
        pm2 start "$server_dir/nexus_server_${arch}" --name server_$i --cwd "$server_dir"
    done
    echo -e "${GREEN}所有服务端已部署并启动！${NC}"
}

function deploy_clients() {
    cd "$NEXUS_DIR"
    arch=$(detect_arch)
    if [[ ! -f "$BIN_DIR/nexus_client_${arch}" ]]; then
        echo "未检测到客户端程序，自动下载..."
        download_bins_and_cfgs
    fi
    read -p "你有几套客户端配置文件需要部署？(1 或更多): " ccount
    for ((g=1;g<=ccount;g++)); do
        echo "配置第 $g 套客户端参数..."
        read -p "输入服务端IP (host) for config $g [127.0.0.1]: " host
        host=${host:-127.0.0.1}
        read -p "输入服务端端口 (port) for config $g [18182]: " port
        port=${port:-18182}
        read -p "此配置下客户端数量 [1]: " cnum
        cnum=${cnum:-1}
        for ((i=1;i<=cnum;i++)); do
            client_dir="$NEXUS_DIR/client_${g}_$i"
            mkdir -p "$client_dir"
            cp "$BIN_DIR/nexus_client_${arch}" "$client_dir/"
            cp "$CFG_DIR/nexus_client.txt" "$client_dir/nexus_client.txt"
            cat > "$client_dir/nexus_client.txt" <<EOF
host: $host
port: $port
EOF
            pm2 delete client_${g}_$i >/dev/null 2>&1 || true
            pm2 start "$client_dir/nexus_client_${arch}" --name client_${g}_$i --cwd "$client_dir"
        done
    done
    echo -e "${GREEN}所有客户端已部署并启动！${NC}"
}

function add_clients() {
    deploy_clients
}

function view_logs() {
    while true; do
        echo -e "\n${GREEN}1. 查看服务端日志（聚合所有服务端实例日志）"
        echo "2. 查看客户端日志（聚合选定套数所有实例日志）"
        echo "3. 返回主菜单${NC}"
        read -p "请选择: " opt
        case $opt in
            1)
                cd "$NEXUS_DIR"
                logfiles=$(ls $HOME/.pm2/logs/server-*-error.log 2>/dev/null || true)
                if [ -z "$logfiles" ]; then
                    echo "没有服务端日志文件（还未产生日志）"
                    continue
                fi
                echo -e "${GREEN}已进入所有服务端实例日志聚合模式，按 Ctrl+C 返回菜单${NC}"
                tail -F $logfiles | awk '
                    BEGIN{ORS="";}
                    {
                        split(FILENAME, arr, "/");
                        file=arr[length(arr)];
                        print "\033[1;32m["file"]\033[0m ", $0, "\n";
                    }
                '
                ;;
            2)
                cd "$NEXUS_DIR"
                configs=()
                for d in client_*_*; do
                    [[ -d "$d" ]] || continue
                    cfg=$(echo $d | awk -F_ '{print $2}')
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
                logfiles=$(ls $HOME/.pm2/logs/client-${cfgid}-*-error.log 2>/dev/null || true)
                if [ -z "$logfiles" ]; then
                    echo "没有该套客户端的日志文件（还未产生日志）"
                    continue
                fi
                echo -e "${GREEN}已进入第${cfgid}套客户端所有实例日志聚合模式，按 Ctrl+C 返回菜单${NC}"
                tail -F $logfiles | awk '
                    BEGIN{ORS="";}
                    {
                        split(FILENAME, arr, "/");
                        file=arr[length(arr)];
                        print "\033[1;31m["file"]\033[0m ", $0, "\n";
                    }
                '
                ;;
            3) break ;;
            *) echo "无效输入" ;;
        esac
    done
}

function modify_config() {
    while true; do
        echo -e "${GREEN}1. 修改服务端配置并重启\n2. 修改客户端配置并重启\n3. 返回${NC}"
        read -p "请选择: " opt
        case $opt in
            1)
                cd "$NEXUS_DIR"
                servers=($(ls -d server_* 2>/dev/null))
                if [ ${#servers[@]} -eq 0 ]; then
                    echo "没有已部署的服务端！"
                    continue
                fi
                echo "已部署服务端实例："
                for idx in "${!servers[@]}"; do
                    echo "$((idx+1)). ${servers[$idx]}"
                done
                read -p "请选择要修改的服务端编号(输入编号, 0返回): " num
                [[ "$num" == "0" ]] && continue
                srv=${servers[$((num-1))]}
                cfg="$NEXUS_DIR/$srv/nexus_server.txt"
                echo "当前配置如下："
                cat "$cfg"
                read -p "新钱包地址: " wallet
                read -p "新端口[默认18182]: " port
                port=${port:-18182}
                read -p "新worker数量: " worker
                queue=$((worker*4))
                cat > "$cfg" <<EOF
address: $wallet
port: $port
queue: $queue
worker: $worker
EOF
                pm2 restart $srv
                echo -e "${GREEN}服务端 $srv 配置已更新并重启${NC}"
                ;;
            2)
                cd "$NEXUS_DIR"
                configs=()
                for d in client_*_*; do
                    [[ -d "$d" ]] || continue
                    cfgid=$(echo $d | awk -F_ '{print $2}')
                    [[ " ${configs[*]} " =~ " $cfgid " ]] || configs+=($cfgid)
                done
                if [ ${#configs[@]} -eq 0 ]; then
                    echo "没有已部署的客户端！"
                    continue
                fi
                echo "已部署客户端配置套数："
                for idx in "${!configs[@]}"; do
                    echo "$((idx+1)). 第${configs[$idx]}套"
                done
                read -p "请选择要修改的客户端套数(输入编号, 0返回): " num
                [[ "$num" == "0" ]] && continue
                cfgid=${configs[$((num-1))]}
                # 结束并清理原本的所有该套实例
                for d in client_${cfgid}_*; do
                    pm2 delete $d >/dev/null 2>&1 || true
                    rm -rf "$NEXUS_DIR/$d"
                done
                # 重新部署
                echo "配置第 $cfgid 套新客户端参数..."
                read -p "新服务端IP (host) [127.0.0.1]: " host
                host=${host:-127.0.0.1}
                read -p "新服务端端口 (port) [18182]: " port
                port=${port:-18182}
                read -p "新客户端数量: " cnum
                arch=$(detect_arch)
                for ((i=1;i<=cnum;i++)); do
                    client_dir="$NEXUS_DIR/client_${cfgid}_$i"
                    mkdir -p "$client_dir"
                    cp "$BIN_DIR/nexus_client_${arch}" "$client_dir/"
                    cp "$CFG_DIR/nexus_client.txt" "$client_dir/nexus_client.txt"
                    cat > "$client_dir/nexus_client.txt" <<EOF
host: $host
port: $port
EOF
                    pm2 delete client_${cfgid}_$i >/dev/null 2>&1 || true
                    pm2 start "$client_dir/nexus_client_${arch}" --name client_${cfgid}_$i --cwd "$client_dir"
                done
                echo -e "${GREEN}第${cfgid}套客户端已全部重建并启动！${NC}"
                ;;
            3) break ;;
            *) echo "无效输入" ;;
        esac
    done
}

function delete_instances() {
    echo -e "${GREEN}1. 删除全部服务端实例\n2. 删除全部客户端实例\n3. 单独删除指定服务端/客户端\n4. 返回${NC}"
    read -p "请选择: " opt
    case $opt in
        1)
            pm2 delete $(pm2 ls | awk '/server_/ {print $4}') || true
            rm -rf $NEXUS_DIR/server_*
            echo -e "${GREEN}所有服务端已删除！${NC}"
            ;;
        2)
            pm2 delete $(pm2 ls | awk '/client_/ {print $4}') || true
            rm -rf $NEXUS_DIR/client_*
            echo -e "${GREEN}所有客户端已删除！${NC}"
            ;;
        3)
            pm2 ls
            read -p "请输入要删除的 pm2 实例名: " name
            pm2 delete $name || true
            rm -rf $NEXUS_DIR/$name
            echo -e "${GREEN}$name 已删除！${NC}"
            ;;
        4) return ;;
        *) echo "无效输入" ;;
    esac
}

function update_bin_urls() {
    echo "该功能暂略，如需支持自定义下载地址可扩展！"
}

function menu() {
    while true; do
        echo -e "\n======== Nexus 一键管理脚本 ========"
        echo "1. 依赖检查与环境准备"
        echo "2. 部署/运行服务端"
        echo "3. 部署/运行客户端（会覆盖重建所有客户端）"
        echo "4. 查看pm2日志"
        echo "5. 修改服务端/客户端配置并重启"
        echo "6. 一键删除/单独删除"
        echo "7. 更新程序下载地址"
        echo "8. 新增客户端配置套数（不中断已有多开）"
        echo "0. 退出"
        echo "==================================="
        read -p "请选择功能: " choice
        case $choice in
            1) check_dependencies; download_bins_and_cfgs ;;
            2) deploy_servers ;;
            3) deploy_clients ;;
            4) view_logs ;;
            5) modify_config ;;
            6) delete_instances ;;
            7) update_bin_urls ;;
            8) add_clients ;;
            0) exit 0 ;;
            *) echo "无效输入" ;;
        esac
    done
}

menu
