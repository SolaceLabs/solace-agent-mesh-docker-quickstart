#!/bin/bash
set -e

echo "🔍 Validating SAM deployment configuration..."
echo ""

# Check if .env exists
if [ ! -f .env ]; then
  echo "❌ ERROR: .env file not found"
  echo "   Run ./setup.sh or copy .env.template to .env"
  exit 1
fi

# Load .env
set -a
source .env
set +a

# Detect deployment mode from command line args or default to all files
COMPOSE_FILES="${@:-compose.yml compose.broker.yml compose.database.yml compose.storage.yml}"

HAS_BROKER=$(echo "$COMPOSE_FILES" | grep -c "compose.broker.yml" || true)
HAS_DATABASE=$(echo "$COMPOSE_FILES" | grep -c "compose.database.yml" || true)
HAS_STORAGE=$(echo "$COMPOSE_FILES" | grep -c "compose.storage.yml" || true)

echo "📋 Deployment Mode Detected:"
echo "   Managed Broker:   $([ "$HAS_BROKER" = "1" ] && echo "✅ Yes" || echo "❌ No (BYO)")"
echo "   Managed Database: $([ "$HAS_DATABASE" = "1" ] && echo "✅ Yes" || echo "❌ No (BYO)")"
echo "   Managed Storage:  $([ "$HAS_STORAGE" = "1" ] && echo "✅ Yes" || echo "❌ No (BYO)")"
echo ""

# Validate LLM configuration (required for all modes)
echo "🤖 Validating LLM Configuration..."
if [ -z "$SAM_LLM_API_KEY" ] || [ "$SAM_LLM_API_KEY" = "REPLACE_WITH_YOUR_API_KEY" ]; then
  echo "❌ ERROR: SAM_LLM_API_KEY is required"
  echo "   Set your LLM API key in .env file"
  exit 1
fi

if [ -z "$SAM_LLM_ENDPOINT" ]; then
  echo "❌ ERROR: SAM_LLM_ENDPOINT is required"
  exit 1
fi

if [ -z "$SAM_MODEL_NAME" ]; then
  echo "❌ ERROR: SAM_MODEL_NAME is required"
  exit 1
fi
echo "   ✅ LLM configuration valid"
echo ""

# Validate broker configuration
echo "🔌 Validating Broker Configuration..."
if [ "$HAS_BROKER" = "0" ]; then
  # BYO broker mode
  if [ -z "$EXTERNAL_BROKER_URL_WS" ] || [ "$EXTERNAL_BROKER_URL_WS" = "ws://your-broker.example.com:8008" ]; then
    echo "❌ ERROR: EXTERNAL_BROKER_URL_WS must be set for BYO broker mode"
    echo "   Example: ws://broker.solace.cloud:443"
    exit 1
  fi
  if [ -z "$EXTERNAL_BROKER_USERNAME" ] || [ "$EXTERNAL_BROKER_USERNAME" = "your-username" ]; then
    echo "❌ ERROR: EXTERNAL_BROKER_USERNAME must be set for BYO broker mode"
    exit 1
  fi
  if [ -z "$EXTERNAL_BROKER_PASSWORD" ] || [ "$EXTERNAL_BROKER_PASSWORD" = "your-password" ]; then
    echo "❌ ERROR: EXTERNAL_BROKER_PASSWORD must be set for BYO broker mode"
    exit 1
  fi
  echo "   ✅ External broker configuration valid"
else
  # Managed broker mode
  echo "   ✅ Using managed Solace broker (compose.broker.yml)"
fi
echo ""

# Validate database configuration
echo "🗄️  Validating Database Configuration..."
if [ "$HAS_DATABASE" = "0" ]; then
  # BYO database mode
  if [ -z "$EXTERNAL_WEB_UI_DATABASE_URL" ] || [ "$EXTERNAL_WEB_UI_DATABASE_URL" = "postgresql+psycopg2://user:password@dbhost:5432/sam_webui" ]; then
    echo "❌ ERROR: EXTERNAL_WEB_UI_DATABASE_URL must be set for BYO database mode"
    echo "   Example: postgresql+psycopg2://user:pass@postgres.example.com:5432/sam_webui"
    exit 1
  fi
  if [ -z "$EXTERNAL_PLATFORM_DATABASE_URL" ]; then
    echo "❌ ERROR: EXTERNAL_PLATFORM_DATABASE_URL must be set for BYO database mode"
    exit 1
  fi
  if [ -z "$EXTERNAL_ORCHESTRATOR_DATABASE_URL" ]; then
    echo "❌ ERROR: EXTERNAL_ORCHESTRATOR_DATABASE_URL must be set for BYO database mode"
    exit 1
  fi
  # Validate agent database config
  if [ -z "$AGENT_DB_HOST" ] || [ "$AGENT_DB_HOST" = "your-postgres-host" ]; then
    echo "❌ ERROR: AGENT_DB_HOST must be set for BYO database mode"
    echo "   Example: postgres.example.com"
    exit 1
  fi
  if [ -z "$AGENT_DB_ADMIN_USER" ] || [ "$AGENT_DB_ADMIN_USER" = "agent_admin" ]; then
    echo "⚠️  WARNING: AGENT_DB_ADMIN_USER is using default value 'agent_admin'"
    echo "   Ensure this user exists with CREATEDB privilege on your PostgreSQL instance"
  fi
  echo "   ✅ External database configuration valid"
else
  # Managed database mode
  if [ -z "$POSTGRES_AGENT_ADMIN_USER" ]; then
    echo "❌ ERROR: POSTGRES_AGENT_ADMIN_USER must be set for managed database mode"
    echo "   Example: agent_admin"
    exit 1
  fi
  if [ -z "$POSTGRES_AGENT_APP_PASSWORD" ]; then
    echo "❌ ERROR: POSTGRES_AGENT_APP_PASSWORD must be set for managed database mode"
    exit 1
  fi
  echo "   ✅ Using managed PostgreSQL (compose.database.yml)"
fi
echo ""

# Validate storage configuration
echo "📦 Validating Storage Configuration..."
if [ "$HAS_STORAGE" = "0" ]; then
  # BYO storage mode
  if [ -z "$EXTERNAL_S3_ENDPOINT_URL" ] || [ "$EXTERNAL_S3_ENDPOINT_URL" = "https://s3.amazonaws.com" ]; then
    echo "⚠️  WARNING: EXTERNAL_S3_ENDPOINT_URL is using default AWS S3"
    echo "   Ensure your S3 bucket exists and credentials are correct"
  fi
  if [ -z "$EXTERNAL_S3_BUCKET_NAME" ] || [ "$EXTERNAL_S3_BUCKET_NAME" = "my-sam-artifacts" ]; then
    echo "❌ ERROR: EXTERNAL_S3_BUCKET_NAME must be set to your actual bucket name"
    exit 1
  fi
  echo "   ✅ External S3 configuration valid"
else
  # Managed storage mode
  echo "   ✅ Using managed SeaweedFS (compose.storage.yml)"
fi
echo ""

# Validate image configuration
echo "🐳 Validating Container Images..."
if [ -z "$SAM_IMAGE" ]; then
  echo "❌ ERROR: SAM_IMAGE not set"
  exit 1
fi
if [ -z "$SAM_TAG" ]; then
  echo "❌ ERROR: SAM_TAG not set"
  exit 1
fi
echo "   ✅ Using image: $SAM_IMAGE:$SAM_TAG"
echo ""

# Validate Docker Compose syntax
echo "🔧 Validating Docker Compose Syntax..."
if ! docker compose $(echo "$COMPOSE_FILES" | sed 's/ / -f /g' | sed 's/^/-f /') config > /dev/null 2>&1; then
  echo "❌ ERROR: Docker Compose configuration is invalid"
  echo "   Run: docker compose -f compose.yml -f ... config"
  echo "   to see detailed errors"
  exit 1
fi
echo "   ✅ Docker Compose syntax valid"
echo ""

echo "✅ All validation checks passed!"
echo ""
echo "🚀 Ready to deploy with:"
echo "   docker compose $(echo "$COMPOSE_FILES" | sed 's/ / -f /g' | sed 's/^/-f /') up -d"
echo ""
