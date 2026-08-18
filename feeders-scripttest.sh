#!/bin/bash

set -euo pipefail

# ============================================================
# Configuration
# ============================================================

OWNER="----X----"  # Replace with your GitHub username or organization (intellicars)
REPO="----X----"   # Replace with your GitHub repository name (feeders)
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

TEMPLATE_FILE="templates/feeders-docker-image.yml"
FILE_PATH=".github/workflows/docker-image.yml"

echo ""
echo "=========================================="
echo "Updating docker-image.yml"
echo "=========================================="

if [[ ! -f "$TEMPLATE_FILE" ]]; then
    echo "ERROR: Template file not found: $TEMPLATE_FILE"
    exit 1
fi

TEMP_FILE=$(mktemp)

cp "$TEMPLATE_FILE" "$TEMP_FILE"

sed -i "s/{{__ENVIRONMENT__}}/$ENVIRONMENT/g" "$TEMP_FILE"

if grep -q '{{__[^}]*__}}' "$TEMP_FILE"; then
    echo "ERROR: Unresolved onboarding placeholders found:"
    grep -o '{{__[^}]*__}}' "$TEMP_FILE" | sort -u
    rm -f "$TEMP_FILE"
    exit 1
fi

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

ENCODED_CONTENT=$(base64 -w 0 "$TEMP_FILE")

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

rm -f "$TEMP_FILE"


# ============================================================
# Helper: read compact JSON from a file path
# ============================================================

read_config_json() {
    local label="$1"
    local path=""

    read -p "Enter path to ${label} config JSON: " path

    if [[ -z "$path" ]]; then
        echo "ERROR: ${label} config path is required." >&2
        exit 1
    fi

    if [[ ! -f "$path" ]]; then
        echo "ERROR: ${label} config file not found: $path" >&2
        exit 1
    fi

    if ! jq -e . "$path" >/dev/null 2>&1; then
        echo "ERROR: ${label} config is not valid JSON: $path" >&2
        exit 1
    fi

    jq -c . "$path"
}


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
# Environment Variables
# ============================================================

echo ""
echo "=========================================="
echo "Setting environment variables"
echo "=========================================="

# Default values
GCP_ARTIFACT_REPO="flexifleets"
GCP_PROJECT_ID="intellicar-in"
GCP_REGION="asia-south1"
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
    "GCP_ARTIFACT_REPO" \
    "$GCP_ARTIFACT_REPO"

set_environment_variable \
    "GCP_PROJECT_ID" \
    "$GCP_PROJECT_ID"

set_environment_variable \
    "GCP_REGION" \
    "$GCP_REGION"

set_environment_variable \
    "GCP_VM_INSTANCE" \
    "$GCP_VM_INSTANCE"

set_environment_variable \
    "GCP_VM_ZONE" \
    "$GCP_VM_ZONE"


# ============================================================
# Feeder config JSON (from files)
# ============================================================

echo ""
echo "=========================================="
echo "Feeder config JSON files"
echo "=========================================="

GCP_VM_LAFCASFEEDER_CONFIG_PATH=$(read_config_json "lafcasfeeder")
GCP_VM_LAFGEOALRTFEEDER_CONFIG_PATH=$(read_config_json "lafgeoalrtfeeder")
GCP_VM_LAFRTKFEEDER_CONFIG_PATH=$(read_config_json "lafrtkfeeder")

set_environment_variable \
    "GCP_VM_LAFCASFEEDER_CONFIG_PATH" \
    "$GCP_VM_LAFCASFEEDER_CONFIG_PATH"

set_environment_variable \
    "GCP_VM_LAFGEOALRTFEEDER_CONFIG_PATH" \
    "$GCP_VM_LAFGEOALRTFEEDER_CONFIG_PATH"

set_environment_variable \
    "GCP_VM_LAFRTKFEEDER_CONFIG_PATH" \
    "$GCP_VM_LAFRTKFEEDER_CONFIG_PATH"


# ============================================================
# Get Environment Public Key
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
# Encrypt Secret
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
# Create / Update Environment Secret
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
# Secrets
# ============================================================

echo ""
echo "=========================================="
echo "Enter environment secrets"
echo "=========================================="

read -p "Enter GCP_CREDENTIALS_JSON: " GCP_CREDENTIALS_JSON

read -p "Enter GH_PRIVATE_MODULES_TOKEN: " GH_PRIVATE_MODULES_TOKEN


: "${GCP_CREDENTIALS_JSON:?GCP_CREDENTIALS_JSON is required}"

: "${GH_PRIVATE_MODULES_TOKEN:?GH_PRIVATE_MODULES_TOKEN is required}"


# ============================================================
# Create / Update Secrets
# ============================================================

echo ""
echo "=========================================="
echo "Setting environment secrets"
echo "=========================================="

set_environment_secret \
    "GCP_CREDENTIALS_JSON" \
    "$GCP_CREDENTIALS_JSON"

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
echo "  ✓ GCP_ARTIFACT_REPO"
echo "  ✓ GCP_PROJECT_ID"
echo "  ✓ GCP_REGION"
echo "  ✓ GCP_VM_INSTANCE"
echo "  ✓ GCP_VM_ZONE"
echo "  ✓ GCP_VM_LAFCASFEEDER_CONFIG_PATH"
echo "  ✓ GCP_VM_LAFGEOALRTFEEDER_CONFIG_PATH"
echo "  ✓ GCP_VM_LAFRTKFEEDER_CONFIG_PATH"
echo ""
echo "Environment secrets:"
echo "  ✓ GCP_CREDENTIALS_JSON"
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
