#!/bin/bash

api_call() {
    local method="$1"
    local url="$2"
    local data="${3:-}"
    local extra_headers="${4:-}"
    local max_time="${5:-30}"

    local cmd=(curl -sS --max-time "$max_time" --connect-timeout 5 \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "X-Requested-With: XMLHttpRequest")

    if [ -n "$extra_headers" ]; then
        IFS='|' read -ra HDRS <<< "$extra_headers"
        for h in "${HDRS[@]}"; do
            cmd+=(-H "$h")
        done
    fi

    if [ "$method" == "POST" ] && [ -n "$data" ]; then
        cmd+=(-X POST -d "$data")
    elif [ "$method" == "POST" ]; then
        cmd+=(-X POST)
    fi

    cmd+=("$url")
    "${cmd[@]}"
}

api_call_with_retry() {
    local method="$1"
    local url="$2"
    local data="${3:-}"
    local extra_headers="${4:-}"
    local max_time="${5:-30}"
    local retries="${6:-8}"
    local delay="${7:-3}"
    local attempt=1
    local response=""

    while [ "$attempt" -le "$retries" ]; do
        response=$(api_call "$method" "$url" "$data" "$extra_headers" "$max_time" 2>/dev/null)

        if response_is_successful "$response"; then
            printf '%s\n' "$response"
            return 0
        fi

        if [ "$attempt" -lt "$retries" ]; then
            warn "API call failed or panel not ready yet, retrying ${attempt}/${retries}: $url" >&2
            sleep "$delay"
        fi

        attempt=$((attempt + 1))
    done

    printf '%s\n' "$response"
    return 1
}

response_is_successful() {
    local data="$1"
    local success

    if [ -z "$data" ]; then
        return 1
    fi

    if ! echo "$data" | jq empty >/dev/null 2>&1; then
        return 1
    fi

    success=$(echo "$data" | jq -r '.success // false' 2>/dev/null)
    [ "$success" = "true" ]
}

json_is_valid() {
    local data="$1"
    echo "$data" | jq empty >/dev/null 2>&1
}

json_has_success() {
    local data="$1"
    response_is_successful "$data"
}

json_get() {
    local data="$1"
    local expr="$2"
    echo "$data" | jq -r "$expr // empty" 2>/dev/null
}


create_hysteria_inbound() {
    local base_url="https://$DOMAIN/$WEB_BASE_PATH"
    base_url="${base_url%/}"
    local cert_file="$CERT_DIR/$DOMAIN/fullchain.pem"
    local key_file="$CERT_DIR/$DOMAIN/privkey.pem"

    log "Creating Hysteria2 inbound..."
    info "  Base URL: $base_url"
    info "  Cert: $cert_file"

    # Verify certificates exist
    if [ ! -f "$cert_file" ] || [ ! -f "$key_file" ]; then
        err "Certificate files not found:"
        err "  Cert: $cert_file"
        err "  Key:  $key_file"
        return 1
    fi

    # Generate Random Port
    PORT=$(shuf -i 10000-65000 -n 1)
    log "Generated port: $PORT"

    # Generate Salamander Password
    SALAMANDER_PASS=$(openssl rand -base64 16 | tr -d '=+/' | cut -c1-16)
    log "Generated salamander password"

    # Build Config JSONs
    SETTINGS=$(jq -n '{
        "version": 2,
        "clients": []
    }')

    STREAM_SETTINGS=$(jq -n \
        --arg certFile "$cert_file" \
        --arg keyFile "$key_file" \
        --arg salamanderPass "$SALAMANDER_PASS" \
        '{
            "network": "hysteria",
            "security": "tls",
            "hysteriaSettings": {
                "version": 2,
                "udpIdleTimeout": 60,
                "masquerade": {
                    "type": "",
                    "dir": "",
                    "url": "",
                    "rewriteHost": false,
                    "insecure": false,
                    "content": "",
                    "headers": {},
                    "statusCode": 404
                }
            },
            "tlsSettings": {
                "serverName": "",
                "minVersion": "1.2",
                "maxVersion": "1.3",
                "cipherSuites": "",
                "rejectUnknownSni": false,
                "disableSystemRoot": false,
                "enableSessionResumption": false,
                "certificates": [
                    {
                        "useFile": true,
                        "certificateFile": $certFile,
                        "keyFile": $keyFile,
                        "certificate": [],
                        "key": [],
                        "ocspStapling": 0,
                        "oneTimeLoading": false,
                        "usage": "encipherment",
                        "buildChain": false
                    }
                ],
                "alpn": ["h3"],
                "echServerKeys": "",
                "settings": {
                    "fingerprint": "",
                    "echConfigList": "",
                    "pinnedPeerCertSha256": [],
                    "verifyPeerCertByName": ""
                }
            },
            "finalmask": {
                "udp": [
                    {
                        "type": "salamander",
                        "settings": {
                            "password": $salamanderPass
                        }
                    }
                ]
            }
        }')

    SNIFFING=$(jq -n '{"enabled": false}')

    # URL Encode Payload
    SETTINGS_ENC=$(echo "$SETTINGS" | jq -c . | jq -sRr @uri)
    STREAM_ENC=$(echo "$STREAM_SETTINGS" | jq -c . | jq -sRr @uri)
    SNIFFING_ENC=$(echo "$SNIFFING" | jq -c . | jq -sRr @uri)

    PAYLOAD="up=0&down=0&total=0&remark=&enable=true&expiryTime=0&trafficReset=never&lastTrafficResetTime=0&listen=&port=$PORT&protocol=hysteria&settings=$SETTINGS_ENC&streamSettings=$STREAM_ENC&sniffing=$SNIFFING_ENC&tag=in-${PORT}-udp&shareAddrStrategy=listen&shareAddr=&subSortIndex=1"

    # Create Inbound
    log "Creating Hysteria2 inbound..."
    ADD_RESP=$(api_call_with_retry POST "$base_url/panel/api/inbounds/add" "$PAYLOAD" "Content-Type: application/x-www-form-urlencoded" 60 8 3)
    ret=$?

    if [ $ret -ne 0 ] || ! json_is_valid "$ADD_RESP" || ! json_has_success "$ADD_RESP"; then
        err "Failed to create inbound. Raw response:"
        echo "$ADD_RESP"
        return 1
    fi

    INBOUND_ID=$(json_get "$ADD_RESP" '.obj.id')
    if [ -z "$INBOUND_ID" ]; then
        err "Inbound was created but its ID was not returned"
        return 1
    fi
    HYSTERIA_INBOUND_ID="$INBOUND_ID"
    printf '\nHYSTERIA_INBOUND_ID=%q\n' "$HYSTERIA_INBOUND_ID" >> /etc/x-ui/install-result.env
    log "Inbound created successfully!"
    info "  Inbound ID: ${INBOUND_ID:-N/A}"

    # Summary
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║     ✅ HYSTERIA2 INBOUND CREATED                     ║${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC}  🌐 Domain:           ${YELLOW}$DOMAIN${NC}"
    echo -e "${GREEN}║${NC}  🔌 Port:             ${YELLOW}$PORT${NC}"
    echo -e "${GREEN}║${NC}  📁 Certificate:      ${YELLOW}$cert_file${NC}"
    echo -e "${GREEN}║${NC}  🔒 Key File:         ${YELLOW}$key_file${NC}"
    echo -e "${GREEN}║${NC}  🎭 Masquerade:       ${YELLOW}404${NC}"
    echo -e "${GREEN}║${NC}  🐉 Salamander Pass:  ${YELLOW}$SALAMANDER_PASS${NC}"
    echo -e "${GREEN}║${NC}  🏷  Tag:              ${YELLOW}in-${PORT}-udp${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
}