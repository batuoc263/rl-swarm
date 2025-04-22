#!/bin/bash

ROOT=$PWD

RED='\033[0;31m'
GREEN='\033[0;32m'
PURPLE='\033[0;95m'
BLUE='\033[0;94m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

print_step() {
    echo -e "\n${CYAN}${BOLD}Step $1: $2${NC}"
}

check_success() {
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ Success!${NC}"
    else
        echo -e "${RED}✗ Failed! Please check errors above and try again.${NC}"
        exit 1
    fi
}

# Export environment variables
export PUB_MULTI_ADDRS
export PEER_MULTI_ADDRS
export HOST_MULTI_ADDRS
export IDENTITY_PATH
export ORG_ID
export HF_HUB_DOWNLOAD_TIMEOUT=120
export CPU_ONLY=1
export CUDA_VISIBLE_DEVICES=""
# Default swarm addrs
DEFAULT_PUB_MULTI_ADDRS=""
PUB_MULTI_ADDRS=${PUB_MULTI_ADDRS:-$DEFAULT_PUB_MULTI_ADDRS}

DEFAULT_PEER_MULTI_ADDRS="/ip4/38.101.215.13/tcp/30002/p2p/QmQ2gEXoPJg6iMBSUFWGzAabS2VhnzuS782Y637hGjfsRJ"
PEER_MULTI_ADDRS=${PEER_MULTI_ADDRS:-$DEFAULT_PEER_MULTI_ADDRS}

DEFAULT_HOST_MULTI_ADDRS="/ip4/0.0.0.0/tcp/38332"
HOST_MULTI_ADDRS=${HOST_MULTI_ADDRS:-$DEFAULT_HOST_MULTI_ADDRS}

DEFAULT_IDENTITY_PATH="$ROOT"/swarm.pem
IDENTITY_PATH=${IDENTITY_PATH:-$DEFAULT_IDENTITY_PATH}

# We force frontend dev server to port 3003
export PORT=3002

if [ -f "modal-login/temp-data/userData.json" ]; then
    cd modal-login
    source ~/.bashrc

    # Install npm/node if missing
    if ! command -v npm >/dev/null 2>&1; then
        echo -e "${YELLOW}npm is not installed. Installing Node.js and npm...${NC}"
        curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
        sudo apt-get install -y nodejs
        source ~/.bashrc
    fi

    echo -e "\n${CYAN}Installing dependencies with npm. This may take a few minutes...${NC}"
    npm install --legacy-peer-deps

    echo -e "\n${CYAN}Starting the development server on port $PORT...${NC}"
    npm run dev > server.log 2>&1 &
    SERVER_PID=$!

    # Wait up to 60s for server.log to report the port
    MAX_WAIT=60; counter=0
    while [ $counter -lt $MAX_WAIT ]; do
        if grep -q "Local:        http://localhost:$PORT" server.log; then
            echo -e "${GREEN}Server is running successfully on port $PORT${NC}"
            break
        fi
        sleep 1; counter=$((counter+1))
    done

    if [ $counter -eq $MAX_WAIT ]; then
        echo -e "${RED}Timeout waiting for server to start.${NC}"
        kill $SERVER_PID 2>/dev/null || true
        exit 1
    fi
    cd ..

    # Extract ORG_ID
    ORG_ID=$(awk 'BEGIN { FS = "\"" } !/^[ \t]*[{}]/ { print $(NF - 1); exit }' modal-login/temp-data/userData.json)
    echo -e "${CYAN}ORG_ID has been set to: ${BOLD}$ORG_ID${NC}\n"

    # Cleanup on Ctrl+C
    cleanup() {
        echo -e "${YELLOW}Shutting down server...${NC}"
        kill $SERVER_PID 2>/dev/null || true
        exit 0
    }
    trap cleanup INT

else
    cd modal-login
    source ~/.bashrc

    if ! command -v npm >/dev/null 2>&1; then
        echo -e "${YELLOW}npm is not installed. Installing Node.js and npm...${NC}"
        curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
        sudo apt-get install -y nodejs
        source ~/.bashrc
    fi

    echo -e "\n${CYAN}Installing dependencies with npm. This may take a few minutes...${NC}"
    npm install --legacy-peer-deps

    echo -e "\n${CYAN}Starting the development server on port $PORT...${NC}"
    npm run dev > server.log 2>&1 &
    SERVER_PID=$!

    MAX_WAIT=60; counter=0
    while [ $counter -lt $MAX_WAIT ]; do
        if grep -q "Local:        http://localhost:$PORT" server.log; then
            echo -e "${GREEN}Server is running successfully on port $PORT.${NC}"
            break
        fi
        sleep 1; counter=$((counter+1))
    done

    if [ $counter -eq $MAX_WAIT ]; then
        echo -e "${RED}Timeout waiting for server to start.${NC}"
        kill $SERVER_PID 2>/dev/null || true
        exit 1
    fi

    # Bước 1: detect kiến trúc
    print_step 1 "Detecting system architecture"
    ARCH=$(uname -m)
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    if [ "$ARCH" = "x86_64" ]; then
        NGROK_ARCH="amd64"; echo -e "${GREEN}Detected x86_64.${NC}"
    elif [[ "$ARCH" =~ ^(arm64|aarch64)$ ]]; then
        NGROK_ARCH="arm64"; echo -e "${GREEN}Detected ARM64.${NC}"
    elif [[ "$ARCH" =~ ^arm ]]; then
        NGROK_ARCH="arm"; echo -e "${GREEN}Detected ARM.${NC}"
    else
        echo -e "${RED}Unsupported architecture: $ARCH${NC}"
        exit 1
    fi

    # Bước 2: tải & cài ngrok
    print_step 2 "Downloading and installing ngrok"
    echo -e "${YELLOW}Downloading ngrok for $OS-$NGROK_ARCH...${NC}"
    wget -q --show-progress "https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-$OS-$NGROK_ARCH.tgz"
    check_success
    echo -e "${YELLOW}Extracting ngrok...${NC}"
    tar -xzf "ngrok-v3-stable-$OS-$NGROK_ARCH.tgz"; check_success
    echo -e "${YELLOW}Moving ngrok to /usr/local/bin/...${NC}"
    sudo mv ngrok /usr/local/bin/; check_success
    rm "ngrok-v3-stable-$OS-$NGROK_ARCH.tgz"; check_success

    # Bước 3: authenticate ngrok
    print_step 3 "Authenticating ngrok"
    while true; do
        echo -e "\n${YELLOW}Enter your ngrok authtoken (from https://dashboard.ngrok.com/get-started/your-authtoken):${NC}"
        read -p "> " NGROK_TOKEN
        [ -z "$NGROK_TOKEN" ] && echo -e "${RED}Token cannot be empty.${NC}" && continue
        pkill -f ngrok || true; sleep 1
        ngrok authtoken "$NGROK_TOKEN"
        if [ $? -eq 0 ]; then echo -e "${GREEN}✓ Authenticated!${NC}"; break; fi
        echo -e "${RED}Auth failed, try again.${NC}"
    done

    # Bước 4: chuẩn bị tunnel
    print_step 4 "Preparing ngrok tunnel"
    pkill -f ngrok || true; sleep 1
    NGROK_WEB_PORT=4040
    while lsof -i :$NGROK_WEB_PORT >/dev/null 2>&1; do
        echo -e "${YELLOW}Port $NGROK_WEB_PORT busy, trying next...${NC}"
        NGROK_WEB_PORT=$((NGROK_WEB_PORT+1))
    done
    echo -e "${GREEN}Will use ngrok web port $NGROK_WEB_PORT${NC}"

    # Bước 5: start tunnel và lấy URL
    print_step 5 "Starting ngrok tunnel on port $PORT"
    ngrok http "$PORT" --log=stdout --log-format=json --log-level=info > ngrok_output.log 2>&1 &
    NGROK_PID=$!; sleep 5

    # Các phương pháp trích URL
    get_url_from_method1() {
        grep -o '"url":"https://[^"]*' ngrok_output.log | head -1 | cut -d'"' -f4
    }
    get_url_from_method2() {
        curl -s "http://localhost:$NGROK_WEB_PORT/api/tunnels" \
         | grep -o '"public_url":"https://[^"]*' | head -1 | cut -d'"' -f4
    }
    get_url_from_method3() {
        grep -m1 "Forwarding" ngrok_output.log | grep -o "https://[^ ]*"
    }
    get_url_from_method4() {
        kill $NGROK_PID 2>/dev/null || true; sleep 2
        ngrok http --region us --log=stdout "$PORT" > ngrok_output_alt.log 2>&1 &
        NGROK_PID=$!; sleep 10
        local url=$(grep -o '"url":"https://[^"]*' ngrok_output_alt.log | head -1 | cut -d'"' -f4)
        [ -z "$url" ] && url=$(curl -s "http://localhost:$NGROK_WEB_PORT/api/tunnels" \
            | grep -o '"public_url":"https://[^"]*' | head -1 | cut -d'"' -f4)
        echo "$url"
    }

    FORWARDING_URL=$(get_url_from_method1)
    [ -z "$FORWARDING_URL" ] && FORWARDING_URL=$(get_url_from_method2)
    [ -z "$FORWARDING_URL" ] && FORWARDING_URL=$(get_url_from_method3)
    [ -z "$FORWARDING_URL" ] && FORWARDING_URL=$(get_url_from_method4)

    if [ -n "$FORWARDING_URL" ]; then
        echo -e "${GREEN}${BOLD}✓ Tunnel ready! Visit and log in:${NC} ${CYAN}${BOLD}$FORWARDING_URL${NC}"
    else
        echo -e "\n${BLUE}Failed to auto-fetch URL. Use SSH tunnel manually:${NC}"
        echo "1. Run: ssh -L 3003:localhost:$PORT $(whoami)@$(curl -s ifconfig.me)"
        echo "2. Then visit: http://localhost:3003/"
        kill $NGROK_PID 2>/dev/null || true
    fi

    cd ..
    echo -e "\n${CYAN}Waiting for login completion...${NC}"
    while [ ! -f "modal-login/temp-data/userData.json" ]; do sleep 3; done
    echo -e "${GREEN}${BOLD}✓ userData.json created. Continuing...${NC}"

    ORG_ID=$(awk 'BEGIN { FS="\"" } !/^[ \t]*[{}]/ { print $(NF-1); exit }' modal-login/temp-data/userData.json)
    echo -e "\n${CYAN}ORG_ID: ${BOLD}$ORG_ID${NC}\n"

    cleanup() {
        echo -e "${YELLOW}Shutting down server & ngrok...${NC}"
        kill $SERVER_PID $NGROK_PID 2>/dev/null || true
        exit 0
    }
    trap cleanup INT
fi

# Python requirements
echo -e "${CYAN}Installing Python packages...${NC}"
pip install -q -r "$ROOT"/requirements-hivemind.txt
pip install -q -r "$ROOT"/requirements.txt

# Chọn config dựa trên GPU/CPU

CONFIG_PATH="$ROOT/hivemind_exp/configs/mac/grpo-qwen-2.5-0.5b-deepseek-r1.yaml"

echo -e "${GREEN}>>> All packages installed successfully!${NC}"


echo -e "\n${GREEN}${BOLD}Good luck in the swarm! Starting training now.${NC}\n"

while true; do
    # Chạy script Python
    if [ -n "$ORG_ID" ]; then
        python3 -m hivemind_exp.gsm8k.train_single_gpu \
            --identity_path "$IDENTITY_PATH" \
            --modal_org_id "$ORG_ID" \
            --config "$CONFIG_PATH"
    else
        python3 -m hivemind_exp.gsm8k.train_single_gpu \
            --identity_path "$IDENTITY_PATH" \
            --public_maddr "$PUB_MULTI_ADDRS" \
            --initial_peers "$PEER_MULTI_ADDRS" \
            --host_maddr "$HOST_MULTI_ADDRS" \
            --config "$CONFIG_PATH"
    fi
    
    EXIT_CODE=$?
    if [ $EXIT_CODE -eq 0 ]; then
        echo -e "\nTraining completed successfully. Exiting."
        break
    else
        echo -e "\nScript crashed with exit code $EXIT_CODE."
        echo "Restarting in 5 seconds..."
        sleep 5
    fi
done
wait
