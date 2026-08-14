#!/bin/bash

set -euo pipefail

# ============================================================
# Configuration
# ============================================================

OWNER="----X----"  # Replace with your GitHub username or organization
REPO="----X----"   # Replace with your GitHub repository name
GITHUB_TOKEN="----X----"  # Replace with your GitHub Personal Access Token

read -p "Enter environment name: " ENVIRONMENT

if [[ -z "$ENVIRONMENT" ]]; then
    echo "ERROR: Environment name is required."
    exit 1
fi

# GitHub PAT should be provided through the environment.
#
# Example:
#   export GITHUB_TOKEN="github_pat_xxxxxxxxx"
#
: "${GITHUB_TOKEN:?GITHUB_TOKEN variable is required}"

API="https://api.github.com"
API_VERSION="2026-03-10"

# ============================================================
# Common headers
# ============================================================

AUTH_HEADER="Authorization: Bearer $GITHUB_TOKEN"
ACCEPT_HEADER="Accept: application/vnd.github+json"
VERSION_HEADER="X-GitHub-Api-Version: $API_VERSION"


# ============================================================
# Helper: URL encode
# ============================================================

url_encode() {
    jq -rn --arg value "$1" '$value | @uri'
}


# ============================================================
# Helper: GitHub API request
# ============================================================

github_api() {
    curl -fsSL \
        -H "$AUTH_HEADER" \
        -H "$ACCEPT_HEADER" \
        -H "$VERSION_HEADER" \
        "$@"
}


# ============================================================
# CREATE CLIENT BRANCH
# ============================================================

BASE_BRANCH="main"
BRANCH_NAME="client/$ENVIRONMENT"

echo ""
echo "=========================================="
echo "Creating client branch"
echo "=========================================="

echo "Base branch : $BASE_BRANCH"
echo "New branch  : $BRANCH_NAME"

MAIN_SHA=$(github_api \
    "$API/repos/$OWNER/$REPO/git/ref/heads/$BASE_BRANCH" \
    | jq -r '.object.sha')

if [[ -z "$MAIN_SHA" || "$MAIN_SHA" == "null" ]]; then
    echo "ERROR: Could not get SHA for $BASE_BRANCH"
    exit 1
fi

echo "Main SHA: $MAIN_SHA"

CREATE_BRANCH_RESPONSE=$(github_api \
    -X POST \
    "$API/repos/$OWNER/$REPO/git/refs" \
    -H "Content-Type: application/json" \
    -d "$(jq -n \
        --arg branch "$BRANCH_NAME" \
        --arg sha "$MAIN_SHA" \
        '{
            ref: ("refs/heads/" + $branch),
            sha: $sha
        }')")

CREATED_BRANCH=$(echo "$CREATE_BRANCH_RESPONSE" | jq -r '.ref')

if [[ "$CREATED_BRANCH" != "refs/heads/$BRANCH_NAME" ]]; then
    echo "ERROR: Failed to create branch"
    echo "$CREATE_BRANCH_RESPONSE"
    exit 1
fi

echo "✓ Branch created successfully: $BRANCH_NAME"





# ============================================================
# UPDATE docker-image.yml FROM TEMPLATE
# ============================================================

TEMPLATE_FILE="templates/docker-image.yml"
FILE_PATH=".github/workflows/docker-image.yml"

echo ""
echo "=========================================="
echo "Updating docker-image.yml"
echo "=========================================="

# ------------------------------------------------------------
# Check template exists
# ------------------------------------------------------------

if [[ ! -f "$TEMPLATE_FILE" ]]; then
    echo "ERROR: Template file not found: $TEMPLATE_FILE"
    exit 1
fi

# ------------------------------------------------------------
# Create temporary file from template
# ------------------------------------------------------------

TEMP_FILE=$(mktemp)

cp "$TEMPLATE_FILE" "$TEMP_FILE"

# ------------------------------------------------------------
# Replace placeholders
# ------------------------------------------------------------

sed -i "s/{{__ENVIRONMENT__}}/$ENVIRONMENT/g" "$TEMP_FILE"

# ------------------------------------------------------------
#  Check for unresolved placeholders
# ------------------------------------------------------------

if grep -q '{{__[^}]*__}}' "$TEMP_FILE"; then
    echo "ERROR: Unresolved onboarding placeholders found:"
    grep -o '{{__[^}]*__}}' "$TEMP_FILE" | sort -u
    rm -f "$TEMP_FILE"
    exit 1
fi

# ------------------------------------------------------------
# Get existing file SHA from the new branch
# ------------------------------------------------------------

FILE_RESPONSE=$(github_api \
    "$API/repos/$OWNER/$REPO/contents/$FILE_PATH?ref=$BRANCH_NAME")

FILE_SHA=$(echo "$FILE_RESPONSE" | jq -r '.sha')

if [[ -z "$FILE_SHA" || "$FILE_SHA" == "null" ]]; then
    echo "ERROR: Could not get SHA for $FILE_PATH"
    echo "$FILE_RESPONSE"
    rm -f "$TEMP_FILE"
    exit 1
fi

echo "✓ Existing file found"
echo "  Branch: $BRANCH_NAME"
echo "  File:   $FILE_PATH"

# ------------------------------------------------------------
# Base64 encode generated file
# ------------------------------------------------------------

ENCODED_CONTENT=$(base64 -w 0 "$TEMP_FILE")

# ------------------------------------------------------------
# Update file on GitHub
# ------------------------------------------------------------

UPDATE_RESPONSE=$(github_api \
    -X PUT \
    "$API/repos/$OWNER/$REPO/contents/$FILE_PATH" \
    -H "Content-Type: application/json" \
    -d "$(jq -n \
        --arg message "Configure workflow for $ENVIRONMENT" \
        --arg content "$ENCODED_CONTENT" \
        --arg sha "$FILE_SHA" \
        --arg branch "$BRANCH_NAME" \
        '{
            message: $message,
            content: $content,
            sha: $sha,
            branch: $branch
        }')")

# ------------------------------------------------------------
# Check result
# ------------------------------------------------------------

UPDATED_SHA=$(echo "$UPDATE_RESPONSE" | jq -r '.content.sha')

if [[ -z "$UPDATED_SHA" || "$UPDATED_SHA" == "null" ]]; then
    echo "ERROR: Failed to update $FILE_PATH"
    echo "$UPDATE_RESPONSE"
    rm -f "$TEMP_FILE"
    exit 1
fi

echo "✓ Successfully updated $FILE_PATH"
echo "✓ Branch: $BRANCH_NAME"
echo "✓ Commit SHA: $UPDATED_SHA"

# ------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------

rm -f "$TEMP_FILE"


# ============================================================
# Create GitHub Environment
# ============================================================

echo "=========================================="
echo "Creating GitHub environment"
echo "=========================================="

ENCODED_ENVIRONMENT=$(url_encode "$ENVIRONMENT")

github_api \
    -X PUT \
    "$API/repos/$OWNER/$REPO/environments/$ENCODED_ENVIRONMENT" \
    -o /dev/null

echo "✓ Environment created: $ENVIRONMENT"


# ============================================================
# Create / Update Environment Variable
# ============================================================

set_environment_variable() {
    local name="$1"
    local value="$2"

    echo "Setting environment variable: $name"

    # Check whether variable already exists
    local encoded_name
    encoded_name=$(url_encode "$name")

    local response
    local http_code

    response=$(curl -sS \
        -w "\n%{http_code}" \
        -H "$AUTH_HEADER" \
        -H "$ACCEPT_HEADER" \
        -H "$VERSION_HEADER" \
        "$API/repos/$OWNER/$REPO/environments/$ENCODED_ENVIRONMENT/variables/$encoded_name")

    http_code=$(echo "$response" | tail -n1)
    response=$(echo "$response" | sed '$d')

    if [[ "$http_code" == "200" ]]; then

        # Variable already exists -> UPDATE
        echo "Variable exists. Updating..."

        curl -fsSL \
            -X PATCH \
            -H "$AUTH_HEADER" \
            -H "$ACCEPT_HEADER" \
            -H "$VERSION_HEADER" \
            -H "Content-Type: application/json" \
            "$API/repos/$OWNER/$REPO/environments/$ENCODED_ENVIRONMENT/variables/$encoded_name" \
            -d "$(jq -n \
                --arg name "$name" \
                --arg value "$value" \
                '{
                    name: $name,
                    value: $value
                }')" \
            -o /dev/null

    elif [[ "$http_code" == "404" ]]; then

        # Variable doesn't exist -> CREATE
        echo "Variable does not exist. Creating..."

        curl -fsSL \
            -X POST \
            -H "$AUTH_HEADER" \
            -H "$ACCEPT_HEADER" \
            -H "$VERSION_HEADER" \
            -H "Content-Type: application/json" \
            "$API/repos/$OWNER/$REPO/environments/$ENCODED_ENVIRONMENT/variables" \
            -d "$(jq -n \
                --arg name "$name" \
                --arg value "$value" \
                '{
                    name: $name,
                    value: $value
                }')" \
            -o /dev/null

    else
        echo "ERROR: Failed to check environment variable."
        echo "HTTP status: $http_code"
        echo "$response"
        exit 1
    fi

    echo "✓ $name"
}

# ============================================================
# UUID GENERATION
# ============================================================

generate_uuid() {
    cat /proc/sys/kernel/random/uuid
}


# ============================================================
# ED25519 KEY GENERATION
# ============================================================

generate_ed25519_keys() {

    local private_key_file
    local public_key_file

    private_key_file=$(mktemp)
    public_key_file=$(mktemp)

    # Generate private key
    openssl genpkey \
        -algorithm ED25519 \
        -out "$private_key_file"

    # Generate public key
    openssl pkey \
        -in "$private_key_file" \
        -pubout \
        -out "$public_key_file"

    SERVER_PRV_KEY=$(cat "$private_key_file")
    SERVER_PUB_KEY=$(cat "$public_key_file")
    

    rm -f "$private_key_file" "$public_key_file"
}

# ============================================================
# Environment Variables
# ============================================================

echo ""
echo "=========================================="
echo "Setting environment variables"
echo "=========================================="

# Default values
FLEETMODULE_CONTAINER_PORT="45001"
FMSWS_CONTAINER_PORT="45014"
GCP_ARTIFACT_REPO="flexifleets"
GCP_PROJECT_ID="intellicar-in"
GCP_REGION="asia-south1"
GCP_VM_FMSWS_HOST_PORT="45014"
GCP_VM_HOST_PORT="45001"
GCP_VM_INSTANCE="dev1"
GCP_VM_ZONE="asia-south1-c"


# User inputs
read -p "Enter GCP_ARTIFACT_REPO [$GCP_ARTIFACT_REPO]: " input
GCP_ARTIFACT_REPO="${input:-$GCP_ARTIFACT_REPO}"

read -p "Enter GCP_PROJECT_ID [$GCP_PROJECT_ID]: " input
GCP_PROJECT_ID="${input:-$GCP_PROJECT_ID}"

read -p "Enter GCP_REGION [$GCP_REGION]: " input
GCP_REGION="${input:-$GCP_REGION}"

read -p "Enter GCP_VM_INSTANCE [$GCP_VM_INSTANCE]: " input
GCP_VM_INSTANCE="${input:-$GCP_VM_INSTANCE}"

read -p "Enter GCP_VM_ZONE [$GCP_VM_ZONE]: " input
GCP_VM_ZONE="${input:-$GCP_VM_ZONE}"

set_environment_variable \
    "FLEETMODULE_CONTAINER_PORT" \
    "$FLEETMODULE_CONTAINER_PORT"

set_environment_variable \
    "FMSWS_CONTAINER_PORT" \
    "$FMSWS_CONTAINER_PORT"

set_environment_variable \
    "GCP_ARTIFACT_REPO" \
    "$GCP_ARTIFACT_REPO"

set_environment_variable \
    "GCP_PROJECT_ID" \
    "$GCP_PROJECT_ID"

set_environment_variable \
    "GCP_REGION" \
    "$GCP_REGION"

set_environment_variable \
    "GCP_VM_FMSWS_HOST_PORT" \
    "$GCP_VM_FMSWS_HOST_PORT"

set_environment_variable \
    "GCP_VM_HOST_PORT" \
    "$GCP_VM_HOST_PORT"

set_environment_variable \
    "GCP_VM_INSTANCE" \
    "$GCP_VM_INSTANCE"

set_environment_variable \
    "GCP_VM_ZONE" \
    "$GCP_VM_ZONE"


# ============================================================
# JSON Environment Variables
# ============================================================


# ============================================================
# USER INPUT
# ============================================================

echo ""
echo "=========================================="
echo "GCP VM CONFIGURATION"
echo "=========================================="

read -p "Enter appid: " APP_ID

read -p "Enter region: " REGION

read -p "Enter accountname: " ACCOUNT_NAME

read -p "Enter PostgreSQL URL: " PG_URL

read -p "Enter socket server URL: " SOCKET_SERVER_URL


# ============================================================
# VALIDATE REQUIRED INPUTS
# ============================================================

if [[ -z "$APP_ID" ]]; then
    echo "ERROR: appid is required"
    exit 1
fi

if [[ -z "$REGION" ]]; then
    echo "ERROR: region is required"
    exit 1
fi

if [[ -z "$ACCOUNT_NAME" ]]; then
    echo "ERROR: accountname is required"
    exit 1
fi

if [[ -z "$PG_URL" ]]; then
    echo "ERROR: PostgreSQL URL is required"
    exit 1
fi

if [[ -z "$SOCKET_SERVER_URL" ]]; then
    echo "ERROR: socket server URL is required"
    exit 1
fi


# ============================================================
# GENERATED VALUES
# ============================================================

echo ""
echo "Generating UUID..."

MOBILE_API_KEY=$(generate_uuid)

echo "✓ UUID generated"


echo ""
echo "Generating Ed25519 keys..."

generate_ed25519_keys

FMSAPI_SERVER_PUB_KEY="$SERVER_PUB_KEY"
FMSAPI_SERVER_PRV_KEY="$SERVER_PRV_KEY"

echo "✓ Ed25519 keys generated"


# ============================================================
# DERIVED VALUES
# ============================================================

SCRATCH_DIR="/mnt/pssd/scratch/$ACCOUNT_NAME/fmsapi"


# ============================================================
# GENERATE GCP_VM_CONFIG_PATH
# ============================================================

GCP_VM_CONFIG_PATH=$(jq -n \
    --arg appid "$APP_ID" \
    --arg region "$REGION" \
    --arg accountname "$ACCOUNT_NAME" \
    --arg scratchdir "$SCRATCH_DIR" \
    --arg pgurl "$PG_URL" \
    --arg socketserverurl "$SOCKET_SERVER_URL" \
    --arg serverpubkey "$FMSAPI_SERVER_PUB_KEY" \
    --arg serverprvkey "$FMSAPI_SERVER_PRV_KEY" \
    --arg apikey "$MOBILE_API_KEY" \
    '{
        appid: $appid,
        apptype: "fmsapi",
        region: $region,
        env: "prod",
        accountname: $accountname,

        scratchdir: $scratchdir,

        instconfig: {
            maxcpu: 2,
            metricstimeout: 10000
        },

        pgdb: {
            pgurl: $pgurl
        },

        apiserver: {
            port: 45001
        },

        serverauth: {
            serverid: "fmsapi",
            serverpubkey: $serverpubkey,
            serverprvkey: $serverprvkey
        },

        consoleserverconfig: {
            serviceaccountuserid: "----X----",
            serviceaccountpubkey: "---X---",
            serviceaccountprvkey: "---X---",
            accountid: "---X---"
        },

        clickhouseconfig: {
            urls: [
                "34.100.160.127:9000",
                "34.14.189.79:9000",
                "35.244.6.244:9000"
            ],
            user: "default",
            password: "intellicar@123",
            database: "lafdatafr",
            maxexecutiontime: 60,
            dialtimeout: 30,
            maxopenconns: 10,
            maxidleconns: 10,
            connmaxlifetime: 60,
            blockbuffersize: 10,
            maxcompressionbuffer: 10240,
            cluster: "shard3_cluster",

            tablenames: {
                tripreporttable: "----X----",
                tripdailybuckettable: "----X----",
                chargereporttable: "----X----",
                chargedailybuckettable: "----X----",
                geofencerreporttable: "----X----",
                alertreporttable: "----X----",
                notificationtable: "----X----",
                eventtelemetrytable: "----X----"
            }
        },

        cqldst: {
            clusterip: [
                "34.100.254.218:9042",
                "35.244.45.2:9042",
                "34.93.203.143:9042"
            ],
            connecttimeout: 10000,
            timeout: 50000,
            streamtimeout: 600000,
            keyspace: "lafdatafr",
            numconnsperhost: 4
        },

        socketserverurl: $socketserverurl,

        mobileserverconfig: {
            apikey: $apikey
        },

        cmdapi: {
            baseurl: "https://lafcmds.intellicar.in",
            bearertoken: "eyJhbGciOiJFZERTQSIsInR5cCI6IkpXVCJ9.eyJ0eXBlIjoic3ZjYWNjdCIsIm5zaWQiOiJucy4xIiwiYWNjdG5hbWUiOiJyaXZlcnRlc3RAaW50ZWxsaWNhci5pbiIsInB1YmtleSI6Ijg2NkE1OEVDOEUwMjkyNTBEQ0JCMTBEM0RFRUY0QUNDNkFDMkQ0MUE0ODk1MTIyNzJERURCRjU5MUEyQjYyQTkiLCJpc3MiOiJpbnRjbWRzaGRsciIsImV4cCI6MTc4NTM0NjExOCwiaWF0IjoxNzg0NzQxMzE4fQ.tIbqWYymPtVqQ6QMkhEJk8sI97qt1auVyjnz8ZimthIgREc8PdsXXbU626BA-0InjVnnYbpH4IHaoAZq-2LR3Dw",
            nsid: "ns.1",
            dirpath: "/laffota/bgauss-test-albin",
            validtill: 3600000
        },

        lafcmddebug: {
            baseurl: "https://lafcmddebug.intellicar.io"
        },

        emailconfig: {
            hosturl: "https://control.msg91.com/api/v5/email/send",
            authkey: "409208ATRjpyQbxSy654364baP1",
            cookie: "PHPSESSID=c6dj5pf01280i8clh47fj0cdm5",
            domain: "msg91.intellicar.in"
        },

        fmswsauthconfig: {
            serverid: "fmsws",
            serverpubkey: "B7054F47BCBB78A7A7DDAE2123155B917BA47270775A09E3C7B77C03DC3F62B6"
        },

        taskconfig: {
            hosturl: "https://bgauss-fr.intellicar.app",
            alertemail: "infrateamalert@intellicar.in",
            fromname: "intellicarBgauss",
            fromemail: "bgauss@intellicar.in",
            supportemail: "bgauss@intellicar.in",
            inviteexpiresinlabel: "1 day",
            forgotpasswordexpiresinlabel: "10 minutes"
        },

        wspusher: {
            wshost: "----X----",
            wsport: 11884,
            prefix: "----X----",
            maxinflight: 10240,
            connecttimeout: 10000,
            connectretrytimeout: 10000,
            keepalivetimeout: 10000
        },

        gcsconfig: {
            credentialsfile: "----X----",
            bucketname: "fmsstorage"
        },

        auditstrmserverconfig: {
            wsserverurl: "----X----",
            connecttimeout: 5000,
            reconnectinterval: 3000,
            keepaliveinterval: 15000,
            readtimeout: 60000,
            maxinflightauditmsgs: 128,
            reqbuffersize: 256
        }
    }'
)


# ============================================================
# DISPLAY GENERATED CONFIG
# ============================================================

echo ""
echo "=========================================="
echo "Generated GCP_VM_CONFIG_PATH"
echo "=========================================="

echo "$GCP_VM_CONFIG_PATH" | jq .


# ============================================================
# NOW SET IT AS GITHUB ENVIRONMENT VARIABLE
# ============================================================

set_environment_variable \
    "GCP_VM_CONFIG_PATH" \
    "$GCP_VM_CONFIG_PATH"
    

echo ""
echo "=========================================="
echo "FMSWS CONFIGURATION"
echo "=========================================="

read -p "Enter FMSWS PostgreSQL URL: " FMSWS_PG_URL
read -p "Enter FMSWS PostgreSQL schema name: " FMSWS_SCHEMA_NAME

# Optional placeholders
read -p "Enter WebSocket broker host [----X----]: " input
FMSWS_BROKER_HOST="${input:-----X----}"

read -p "Enter WS base topic [----X----]: " input
FMSWS_BASE_TOPIC="${input:-----X----}"

read -p "Enter audit stream server URL [---X---]: " input
FMSWS_AUDIT_URL="${input:----X---}"

read -p "Enter live track base path [----X----]: " input
FMSWS_LIVETRACK_BASEPATH="${input:-----X----}" 

echo "Generating FMSWS Ed25519 keys..."

generate_ed25519_keys

FMSWS_SERVER_PRV_KEY="$SERVER_PRV_KEY"
FMSWS_SERVER_PUB_KEY="$SERVER_PUB_KEY"

echo "✓ FMSWS keys generated"

FMSWS_SCRATCH_DIR="/mnt/pssd/scratch/$ACCOUNT_NAME/fmsws"

GCP_VM_FMSWS_CONFIG_PATH=$(jq -n \
    --arg accountname "$ACCOUNT_NAME" \
    --arg scratchdir "$FMSWS_SCRATCH_DIR" \
    --arg pgurl "$FMSWS_PG_URL" \
    --arg schemaname "$FMSWS_SCHEMA_NAME" \
    --arg brokerhost "$FMSWS_BROKER_HOST" \
    --arg wsbasetopic "$FMSWS_BASE_TOPIC" \
    --arg fmsapipubkey "$FMSAPI_SERVER_PUB_KEY" \
    --arg serverpubkey "$FMSWS_SERVER_PUB_KEY" \
    --arg serverprvkey "$FMSWS_SERVER_PRV_KEY" \
    --arg auditurl "$FMSWS_AUDIT_URL" \
    --arg basepath "$FMSWS_LIVETRACK_BASEPATH" \
    '{
        appid: "fmsws",
        apptype: "fmsws",

        scratchdir: $scratchdir,

        instconfig: {
            maxcpu: 2,
            metricstimeout: 10000
        },

        pgsqlconfig: {
            pgurl: $pgurl,
            schemaname: $schemaname
        },

        apiserverconfig: {
            port: 45014
        },

        wspullerrtconfig: {
            brokerHost: $brokerhost,
            brokerPort: 11884,
            connectTimeout: 10000,
            keepAliveTimeout: 10000,
            connectRetryTimeout: 10000
        },

        wsfmsconnhdlrconfig: {
            connrxdatachlen: 64
        },

        wsbasetopic: $wsbasetopic,

        fmsserverauthconfig: {
            serverid: "fmsapi",
            serverpubkey: $fmsapipubkey
        },

        serverauthconfig: {
            serverid: "fmsws",
            serverpubkey: $serverpubkey,
            serverprvkey: $serverprvkey
        },

        auditstrmserverconfig: {
            wsserverurl: $auditurl,
            connecttimeout: 5000,
            reconnectinterval: 5000,
            keepaliveinterval: 30000,
            readtimeout: 60000,
            maxinflightauditmsgs: 128,
            reqbuffersize: 128
        },

        livetracklinkconfig: {
            basepath: $basepath,
            allowedorigins: [
                "http://localhost:3000",
                "http://localhost:3001",
                "https://dev-fleet-1.intellicar.app",
                "https://fleet-1.intellicar.app",
                "https://console.intellicar.app",
                "https://fms.intellicar.app",
                "https://fms-in-20.intellicar.app",
                "http://192.168.91.3:3000",
                "https://bgauss-fr.intellicar.app"
            ]
        }
    }'
)


set_environment_variable \
    "GCP_VM_FMSWS_CONFIG_PATH" \
    "$GCP_VM_FMSWS_CONFIG_PATH"


# ============================================================
# 4. Get Environment Public Key
# ============================================================

echo ""
echo "=========================================="
echo "Getting environment public key"
echo "=========================================="

PUBLIC_KEY_RESPONSE=$(github_api \
    "$API/repos/$OWNER/$REPO/environments/$ENCODED_ENVIRONMENT/secrets/public-key")

KEY_ID=$(echo "$PUBLIC_KEY_RESPONSE" | jq -r '.key_id')
PUBLIC_KEY=$(echo "$PUBLIC_KEY_RESPONSE" | jq -r '.key')

if [[ -z "$KEY_ID" || "$KEY_ID" == "null" ]]; then
    echo "ERROR: Could not get GitHub environment key ID"
    exit 1
fi

if [[ -z "$PUBLIC_KEY" || "$PUBLIC_KEY" == "null" ]]; then
    echo "ERROR: Could not get GitHub environment public key"
    exit 1
fi

echo "✓ Public key retrieved"


# ============================================================
# 5. Encrypt Secret
# ============================================================

encrypt_secret() {

    local secret_value="$1"

    python3 - "$PUBLIC_KEY" "$secret_value" <<'PY'

import sys
import base64

from nacl.public import PublicKey, SealedBox


public_key = sys.argv[1]
secret_value = sys.argv[2]

public_key = PublicKey(
    public_key.encode("utf-8"),
    # GitHub gives us a Base64 encoded key
    encoder=__import__("nacl.encoding", fromlist=["Base64Encoder"]).Base64Encoder
)

sealed_box = SealedBox(public_key)

encrypted = sealed_box.encrypt(
    secret_value.encode("utf-8")
)

print(
    base64.b64encode(encrypted).decode("utf-8")
)

PY
}


# ============================================================
# 6. Create / Update Environment Secret
# ============================================================

set_environment_secret() {

    local name="$1"
    local value="$2"

    echo "Setting environment secret: $name"

    if [[ -z "$value" ]]; then
        echo "ERROR: Secret '$name' has an empty value"
        exit 1
    fi

    local encrypted_value
    encrypted_value=$(encrypt_secret "$value")

    if [[ -z "$encrypted_value" ]]; then
        echo "ERROR: Failed to encrypt secret '$name'"
        exit 1
    fi

    local encoded_name
    encoded_name=$(url_encode "$name")

    github_api \
        -X PUT \
        "$API/repos/$OWNER/$REPO/environments/$ENCODED_ENVIRONMENT/secrets/$encoded_name" \
        -H "Content-Type: application/json" \
        -d "$(jq -n \
            --arg encrypted_value "$encrypted_value" \
            --arg key_id "$KEY_ID" \
            '{
                encrypted_value: $encrypted_value,
                key_id: $key_id
            }')" \
        -o /dev/null

    echo "✓ $name"
}


# ============================================================
# 7. Secrets
# ============================================================

echo ""
echo "=========================================="
echo "Enter environment secrets"
echo "=========================================="

read -p "Enter GCP_CREDENTIALS_JSON: " GCP_CREDENTIALS_JSON

read -p "Enter GCP_GCS_CREDENTIALS_JSON: " GCP_GCS_CREDENTIALS_JSON

read -p "Enter GH_PRIVATE_MODULES_TOKEN: " GH_PRIVATE_MODULES_TOKEN


: "${GCP_CREDENTIALS_JSON:?GCP_CREDENTIALS_JSON is required}"

: "${GCP_GCS_CREDENTIALS_JSON:?GCP_GCS_CREDENTIALS_JSON is required}"

: "${GH_PRIVATE_MODULES_TOKEN:?GH_PRIVATE_MODULES_TOKEN is required}"


# ============================================================
# 8. Create / Update Secrets
# ============================================================

echo ""
echo "=========================================="
echo "Setting environment secrets"
echo "=========================================="

set_environment_secret \
    "GCP_CREDENTIALS_JSON" \
    "$GCP_CREDENTIALS_JSON"

set_environment_secret \
    "GCP_GCS_CREDENTIALS_JSON" \
    "$GCP_GCS_CREDENTIALS_JSON"

set_environment_secret \
    "GH_PRIVATE_MODULES_TOKEN" \
    "$GH_PRIVATE_MODULES_TOKEN"



# ============================================================
# Done
# ============================================================

echo ""
echo "=========================================="
echo "GitHub environment setup complete"
echo "=========================================="

echo ""
echo "Repository:   $OWNER/$REPO"
echo "Environment:  $ENVIRONMENT"
echo ""
echo "Environment variables:"
echo "  ✓ FLEETMODULE_CONTAINER_PORT"
echo "  ✓ FMSWS_CONTAINER_PORT"
echo "  ✓ GCP_ARTIFACT_REPO"
echo "  ✓ GCP_PROJECT_ID"
echo "  ✓ GCP_REGION"
echo "  ✓ GCP_VM_CONFIG_PATH"
echo "  ✓ GCP_VM_FMSWS_CONFIG_PATH"
echo "  ✓ GCP_VM_FMSWS_HOST_PORT"
echo "  ✓ GCP_VM_HOST_PORT"
echo "  ✓ GCP_VM_INSTANCE"
echo "  ✓ GCP_VM_ZONE"
echo ""
echo "Environment secrets:"
echo "  ✓ GCP_CREDENTIALS_JSON"
echo "  ✓ GCP_GCS_CREDENTIALS_JSON"
echo "  ✓ GH_PRIVATE_MODULES_TOKEN"
echo ""


read -p "Do you want to trigger the GitHub Actions workflow? (yes/no): " TRIGGER_WORKFLOW

if [[ "$TRIGGER_WORKFLOW" == "yes" ]]; then

    echo ""
    echo "=========================================="
    echo "Triggering GitHub Actions workflow"
    echo "=========================================="

    github_api \
        -X POST \
        "$API/repos/$OWNER/$REPO/actions/workflows/docker-image.yml/dispatches" \
        -H "Content-Type: application/json" \
        -d "$(jq -n \
            --arg ref "$BRANCH_NAME" \
            --arg environment "$ENVIRONMENT" \
            '{
                ref: $ref,
                inputs: {
                    deploy: "true",
                    environment: $environment
                }
            }')"

    echo "✓ GitHub Actions workflow triggered"
    echo "  Branch: $BRANCH_NAME"
    echo "  Environment: $ENVIRONMENT"

else
    echo "Skipping GitHub Actions workflow trigger."
fi
