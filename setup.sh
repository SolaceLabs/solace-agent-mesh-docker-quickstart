#!/bin/bash
set -euo pipefail

# =============================================================================
# SAM Setup Script
# =============================================================================
# Helps users configure their SAM deployment by:
# 1. Auto-discovering available compose files
# 2. Collecting LLM configuration
# 3. Generating .env and convenience scripts
#
# Supports both Docker Compose and Podman Compose.
#
# TO ADD A NEW SERVICE:
# 1. Create compose.<component>.yml
# 2. Add <COMPONENT>_* variables to .env.template
# 3. Done! This script auto-discovers new components.
# =============================================================================

cd "$(dirname "$0")"

# =============================================================================
# DETECT CONTAINER ENGINE
# =============================================================================

if command -v docker &> /dev/null && docker compose version &> /dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
    ENGINE_NAME="Docker"
elif command -v podman &> /dev/null && podman compose version &> /dev/null 2>&1; then
    COMPOSE_CMD="podman compose"
    ENGINE_NAME="Podman"
else
    echo "Error: Neither 'docker compose' nor 'podman compose' found"
    echo ""
    echo "Please install one of:"
    echo "  - Docker: https://docs.docker.com/get-docker/"
    echo "  - Podman: https://podman.io/getting-started/installation"
    exit 1
fi

echo "=========================================="
echo "SAM (Solace Agent Mesh) - Quick Setup"
echo "Using: $ENGINE_NAME"
echo "=========================================="
echo ""

# =============================================================================
# DISCOVER AVAILABLE COMPONENTS
# =============================================================================

component_files=()
component_names=()

for file in compose.*.yml; do
    [ -f "$file" ] || continue
    [ "$file" = "compose.yml" ] && continue

    component="${file#compose.}"
    component="${component%.yml}"
    display_name="$(tr '[:lower:]' '[:upper:]' <<< "${component:0:1}")${component:1}"

    component_files+=("$file")
    component_names+=("$display_name")
done

if [ ${#component_files[@]} -eq 0 ]; then
    echo "Error: No component compose files found (compose.*.yml)"
    exit 1
fi

# =============================================================================
# CHECK EXISTING CONFIGURATION
# =============================================================================

if [ -f .env ]; then
    echo "Warning: .env file already exists!"
    read -p "Do you want to overwrite it? (y/N): " overwrite
    if [[ ! "$overwrite" =~ ^[Yy]$ ]]; then
        echo "Setup cancelled."
        exit 0
    fi
fi

# =============================================================================
# DEPLOYMENT MODE SELECTION
# =============================================================================

component_list=""
for name in "${component_names[@]}"; do
    component_list="${component_list:+$component_list, }$name"
done

echo "Let's configure your SAM deployment."
echo ""
echo "Choose your deployment mode:"
echo "1) All-in-One (Docker Compose deploys everything - good for local dev/testing)"
echo "2) BYO Everything (use your existing cloud infrastructure)"
echo "3) Custom (mix Docker services with your cloud infrastructure)"
echo ""
read -p "Enter choice [1-3]: " mode

selected_files=()

case $mode in
    1)
        echo ""
        echo "All-in-One deployment selected"
        echo "   Docker Compose will deploy: $component_list"
        echo ""
        selected_files=("${component_files[@]}")
        ;;
    2)
        echo ""
        echo "BYO Everything selected"
        echo "   You'll use your existing: $component_list"
        echo "   You'll need to provide connection details for all services"
        echo ""
        ;;
    3)
        echo ""
        echo "Custom deployment"
        echo ""
        echo "For each service, choose:"
        echo "  Y = Docker Compose deploys it locally"
        echo "  N = Use your existing cloud/external service"
        echo ""

        for i in "${!component_files[@]}"; do
            file="${component_files[$i]}"
            name="${component_names[$i]}"

            read -p "Deploy ${name} with Docker Compose? (Y/n): " response
            if [[ ! "$response" =~ ^[Nn]$ ]]; then
                selected_files+=("$file")
            fi
        done
        ;;
    *)
        echo "Invalid choice. Exiting."
        exit 1
        ;;
esac

# =============================================================================
# CREATE .ENV FROM TEMPLATE
# =============================================================================

echo ""
echo "Creating .env file from template..."
cp .env.template .env

# =============================================================================
# CONFIGURE MANAGED SERVICES
# =============================================================================
# When managed services are selected, update .env with the correct connection
# details so that agent.env (used by deployed agents) has the right values.

broker_selected=false
for file in "${selected_files[@]}"; do
    if [ "$file" = "compose.broker.yml" ]; then
        broker_selected=true
        break
    fi
done

database_selected=false
for file in "${selected_files[@]}"; do
    if [ "$file" = "compose.database.yml" ]; then
        database_selected=true
        break
    fi
done

storage_selected=false
for file in "${selected_files[@]}"; do
    if [ "$file" = "compose.storage.yml" ]; then
        storage_selected=true
        break
    fi
done

if $broker_selected; then
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' 's|BROKER_URL=.*|BROKER_URL=tcp://broker:55555|' .env
        sed -i '' 's|BROKER_URL_WS=.*|BROKER_URL_WS=ws://broker:8008|' .env
        sed -i '' 's|BROKER_USERNAME=.*|BROKER_USERNAME=client|' .env
        sed -i '' 's|BROKER_PASSWORD=.*|BROKER_PASSWORD=password|' .env
        sed -i '' 's|BROKER_VPN=.*|BROKER_VPN=default|' .env
    else
        sed -i 's|BROKER_URL=.*|BROKER_URL=tcp://broker:55555|' .env
        sed -i 's|BROKER_URL_WS=.*|BROKER_URL_WS=ws://broker:8008|' .env
        sed -i 's|BROKER_USERNAME=.*|BROKER_USERNAME=client|' .env
        sed -i 's|BROKER_PASSWORD=.*|BROKER_PASSWORD=password|' .env
        sed -i 's|BROKER_VPN=.*|BROKER_VPN=default|' .env
    fi
fi

if $database_selected; then
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' 's|WEB_UI_DATABASE_URL=.*|WEB_UI_DATABASE_URL=postgresql+psycopg2://webui:webui@postgres:5432/webui|' .env
        sed -i '' 's|PLATFORM_DATABASE_URL=.*|PLATFORM_DATABASE_URL=postgresql+psycopg2://platform:platform@postgres:5432/platform|' .env
        sed -i '' 's|ORCHESTRATOR_DATABASE_URL=.*|ORCHESTRATOR_DATABASE_URL=postgresql+psycopg2://orchestrator:orchestrator@postgres:5432/orchestrator|' .env
    else
        sed -i 's|WEB_UI_DATABASE_URL=.*|WEB_UI_DATABASE_URL=postgresql+psycopg2://webui:webui@postgres:5432/webui|' .env
        sed -i 's|PLATFORM_DATABASE_URL=.*|PLATFORM_DATABASE_URL=postgresql+psycopg2://platform:platform@postgres:5432/platform|' .env
        sed -i 's|ORCHESTRATOR_DATABASE_URL=.*|ORCHESTRATOR_DATABASE_URL=postgresql+psycopg2://orchestrator:orchestrator@postgres:5432/orchestrator|' .env
    fi
fi

if $storage_selected; then
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' 's|S3_BUCKET_NAME=.*|S3_BUCKET_NAME=sam-artifacts|' .env
        sed -i '' 's|S3_ENDPOINT_URL=.*|S3_ENDPOINT_URL=http://seaweedfs:8333|' .env
        sed -i '' 's|S3_REGION=.*|S3_REGION=us-east-1|' .env
        sed -i '' 's|S3_ACCESS_KEY_ID=.*|S3_ACCESS_KEY_ID=sam|' .env
        sed -i '' 's|S3_SECRET_ACCESS_KEY=.*|S3_SECRET_ACCESS_KEY=sam|' .env
    else
        sed -i 's|S3_BUCKET_NAME=.*|S3_BUCKET_NAME=sam-artifacts|' .env
        sed -i 's|S3_ENDPOINT_URL=.*|S3_ENDPOINT_URL=http://seaweedfs:8333|' .env
        sed -i 's|S3_REGION=.*|S3_REGION=us-east-1|' .env
        sed -i 's|S3_ACCESS_KEY_ID=.*|S3_ACCESS_KEY_ID=sam|' .env
        sed -i 's|S3_SECRET_ACCESS_KEY=.*|S3_SECRET_ACCESS_KEY=sam|' .env
    fi
fi

# =============================================================================
# LLM CONFIGURATION
# =============================================================================

echo ""
echo "LLM Configuration (REQUIRED)"
echo ""

read -p "Enter LLM API Key: " llm_key
if [ -z "$llm_key" ]; then
    echo "Error: LLM API Key is required"
    rm .env
    exit 1
fi

read -p "Enter LLM Model Name [gpt-4]: " llm_model
llm_model="${llm_model:-gpt-4}"

read -p "Enter LLM Endpoint [https://api.openai.com/v1]: " llm_endpoint
llm_endpoint="${llm_endpoint:-https://api.openai.com/v1}"

if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "s|^SAM_LLM_API_KEY=.*$|SAM_LLM_API_KEY=$llm_key|" .env
    sed -i '' "s|^SAM_MODEL_NAME=.*$|SAM_MODEL_NAME=$llm_model|" .env
    sed -i '' "s|^SAM_LLM_ENDPOINT=.*$|SAM_LLM_ENDPOINT=$llm_endpoint|" .env
else
    sed -i "s|^SAM_LLM_API_KEY=.*$|SAM_LLM_API_KEY=$llm_key|" .env
    sed -i "s|^SAM_MODEL_NAME=.*$|SAM_MODEL_NAME=$llm_model|" .env
    sed -i "s|^SAM_LLM_ENDPOINT=.*$|SAM_LLM_ENDPOINT=$llm_endpoint|" .env
fi

if [ "$ENGINE_NAME" = "Podman" ]; then
    echo "CONTAINER_ENGINE=podman" >> .env
    echo "CONTAINER_SOCKET=\${XDG_RUNTIME_DIR}/podman/podman.sock" >> .env
fi

# =============================================================================
# BUILD COMPOSE COMMAND
# =============================================================================

compose_cmd="$COMPOSE_CMD -f compose.yml"
if [ ${#selected_files[@]} -gt 0 ]; then
    for file in "${selected_files[@]}"; do
        compose_cmd="$compose_cmd -f $file"
    done
fi

# =============================================================================
# IDENTIFY EXTERNAL SERVICES
# =============================================================================

external_services=()
for i in "${!component_files[@]}"; do
    file="${component_files[$i]}"
    name="${component_names[$i]}"

    is_selected=false
    if [ ${#selected_files[@]} -gt 0 ]; then
        for selected in "${selected_files[@]}"; do
            if [ "$file" = "$selected" ]; then
                is_selected=true
                break
            fi
        done
    fi

    if ! $is_selected; then
        component="${file#compose.}"
        component="${component%.yml}"
        component_upper="$(tr '[:lower:]' '[:upper:]' <<< "$component")"
        external_services+=("   - $name (${component_upper}_*)")
    fi
done

# =============================================================================
# CREATE CONVENIENCE SCRIPTS
# =============================================================================

cat > start.sh << EOF
#!/bin/bash
set -e
cd "\$(dirname "\$0")"
$compose_cmd up -d
EOF
chmod +x start.sh

cat > stop.sh << EOF
#!/bin/bash
set -e
cd "\$(dirname "\$0")"
$compose_cmd down
EOF
chmod +x stop.sh

cat > logs.sh << EOF
#!/bin/bash
set -e
cd "\$(dirname "\$0")"
$compose_cmd logs -f
EOF
chmod +x logs.sh

# =============================================================================
# PRINT NEXT STEPS
# =============================================================================

echo ""
echo "Configuration complete!"
echo ""

# =============================================================================
# BUILD DEPLOYER IMAGE WITH DOCKER CLI
# =============================================================================

echo "Building deployer image with Docker CLI..."
echo "This is a one-time operation (~2 minutes)."
echo ""

set -a
source .env
set +a

if $COMPOSE_CMD build deployer; then
    echo ""
    echo "Deployer image built successfully"
else
    echo ""
    echo "Failed to build deployer image"
    echo "   Please ensure Docker BuildKit is enabled"
    exit 1
fi

echo ""
echo "Next steps:"
echo ""

if [ ${#external_services[@]} -gt 0 ]; then
    echo "IMPORTANT: You chose to use your existing cloud/external services for:"
    printf '%s\n' "${external_services[@]}"
    echo ""
    echo "1. Edit .env file and provide connection details for these services:"
    echo "   nano .env"
    echo ""
    echo "2. Start SAM:"
else
    echo "1. Start SAM:"
fi

echo "   $compose_cmd up -d"
echo ""
echo "   Or simply:"
echo "   ./start.sh"
echo ""
echo "2. Access SAM:"
echo "   Web UI: http://localhost:8000"
echo ""
echo "3. Follow logs (real-time):"
echo "   $compose_cmd logs -f"
echo "   Or simply: ./logs.sh"
echo ""
echo "4. Stop SAM:"
echo "   $compose_cmd down"
echo "   Or simply: ./stop.sh"
echo ""
echo "Convenience scripts created:"
echo "   ./start.sh - Start SAM"
echo "   ./stop.sh  - Stop SAM"
echo "   ./logs.sh  - Follow logs"
echo ""
