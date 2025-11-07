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
# 2. Add EXTERNAL_<COMPONENT>_* variables to .env.template
# 3. Done! This script auto-discovers new components.
# =============================================================================

# Change to script directory to handle relative paths correctly
cd "$(dirname "$0")"

# =============================================================================
# DETECT CONTAINER ENGINE
# =============================================================================

# Detect which container engine is available (prefer docker, fallback to podman)
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

# Find all compose files except base compose.yml
# Supports: compose.broker.yml, compose.database.yml, etc.
component_files=()
component_names=()

for file in compose.*.yml; do
    [ -f "$file" ] || continue
    [ "$file" = "compose.yml" ] && continue

    # Extract component name: compose.broker.yml -> broker
    component="${file#compose.}"
    component="${component%.yml}"

    # Capitalize for display: broker -> Broker
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
    echo "⚠️  .env file already exists!"
    read -p "Do you want to overwrite it? (y/N): " overwrite
    if [[ ! "$overwrite" =~ ^[Yy]$ ]]; then
        echo "Setup cancelled."
        exit 0
    fi
fi

# =============================================================================
# DEPLOYMENT MODE SELECTION
# =============================================================================

# Build component list for display
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

# Determine which compose files to use based on mode
selected_files=()

case $mode in
    1)
        echo ""
        echo "📦 All-in-One deployment selected"
        echo "   Docker Compose will deploy: $component_list"
        echo ""
        selected_files=("${component_files[@]}")
        ;;
    2)
        echo ""
        echo "🔗 BYO Everything selected"
        echo "   You'll use your existing: $component_list"
        echo "   You'll need to provide connection details for all services"
        echo ""
        # Empty array - only base compose.yml
        ;;
    3)
        echo ""
        echo "🎛️  Custom deployment"
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
# LLM CONFIGURATION
# =============================================================================

echo ""
echo "Creating .env file from template..."
cp .env.template .env

echo ""
echo "⚙️  LLM Configuration (REQUIRED)"
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

# Update .env file (macOS and Linux compatible)
if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "s|^SAM_LLM_API_KEY=.*$|SAM_LLM_API_KEY=$llm_key|" .env
    sed -i '' "s|^SAM_MODEL_NAME=.*$|SAM_MODEL_NAME=$llm_model|" .env
    sed -i '' "s|^SAM_LLM_ENDPOINT=.*$|SAM_LLM_ENDPOINT=$llm_endpoint|" .env
else
    sed -i "s|^SAM_LLM_API_KEY=.*$|SAM_LLM_API_KEY=$llm_key|" .env
    sed -i "s|^SAM_MODEL_NAME=.*$|SAM_MODEL_NAME=$llm_model|" .env
    sed -i "s|^SAM_LLM_ENDPOINT=.*$|SAM_LLM_ENDPOINT=$llm_endpoint|" .env
fi

# Configure container engine specific settings
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

# Find which services need external configuration
external_services=()
for i in "${!component_files[@]}"; do
    file="${component_files[$i]}"
    name="${component_names[$i]}"

    # Check if this file is in selected_files
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
        # Extract component for env var prefix: compose.broker.yml -> BROKER
        component="${file#compose.}"
        component="${component%.yml}"
        component_upper="$(tr '[:lower:]' '[:upper:]' <<< "$component")"
        external_services+=("   - $name (EXTERNAL_${component_upper}_*)")
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
echo "✅ Configuration complete!"
echo ""
echo "📝 Next steps:"
echo ""

if [ ${#external_services[@]} -gt 0 ]; then
    echo "⚠️  IMPORTANT: You chose to use your existing cloud/external services for:"
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
echo "💡 Convenience scripts created:"
echo "   ./start.sh - Start SAM"
echo "   ./stop.sh  - Stop SAM"
echo "   ./logs.sh  - Follow logs"
echo ""
