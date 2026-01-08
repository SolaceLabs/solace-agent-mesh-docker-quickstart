# SAM (Solace Agent Mesh) - Docker Based Deployment

Flexible Docker Compose / Podman Compose deployment for SAM that allows you to bring your own infrastructure (broker, database, storage) or use fully managed services.

## Table of Contents

- [Prerequisites](#prerequisites)
  - [Image Pull Authentication](#image-pull-authentication)
- [Quick Start](#quick-start)
  - [Interactive Setup (Recommended)](#interactive-setup-recommended)
  - [Manual Setup](#manual-setup)
- [Architecture](#architecture)
- [How It Works](#how-it-works)
- [Deployment Profiles](#deployment-profiles)
  - [Bring Your Own Broker](#bring-your-own-broker)
  - [Bring Your Own Database](#bring-your-own-database)
  - [Bring Your Own S3 Storage](#bring-your-own-s3-storage)
  - [Managed Services](#managed-services)
- [Operations](#operations)
  - [Starting SAM](#starting-sam)
  - [Viewing Logs](#viewing-logs)
  - [Checking Status](#checking-status)
  - [Stopping SAM](#stopping-sam)
  - [Cleaning Up Deployed Agents](#cleaning-up-deployed-agents)
  - [Updating Configuration](#updating-configuration)
- [Accessing SAM](#accessing-sam)
- [Troubleshooting](#troubleshooting)
- [File Structure](#file-structure)
- [Requirements](#requirements)
  - [Using Podman](#using-podman)
- [Configuration Reference](#configuration-reference)
- [Security Considerations](#security-considerations)
- [Examples](#examples)

## Prerequisites

### Image Pull Authentication

SAM container images require authentication. Choose one of the following options:

#### Option 1: Use Solace Cloud Image Pull Secret (Recommended)

1. **Download the image pull secret** from Solace Cloud:
   - Follow the instructions at: [Download Image Pull Secret](https://docs.solace.com/Cloud/private_regions_tab.htm?Highlight=create%20a%20private%20region#Download)
   - You'll receive a Kubernetes secret YAML file (e.g., `gcr-reg-secret.yaml`)

2. **Configure your container engine with the credentials**:

   **For Docker:**
   ```bash
   # Backup existing Docker config
   cp ~/.docker/config.json ~/.docker/config.json.backup

   # Extract and merge the Solace credentials
   grep '\.dockerconfigjson:' gcr-reg-secret.yaml | awk '{print $2}' | base64 -d > /tmp/solace-creds.json
   jq -s '.[0] * .[1]' ~/.docker/config.json /tmp/solace-creds.json > ~/.docker/config.json.new
   mv ~/.docker/config.json.new ~/.docker/config.json
   rm /tmp/solace-creds.json
   ```

   **For Podman:**
   ```bash
   # Podman uses the same config format, just in a different location
   mkdir -p ${XDG_RUNTIME_DIR}/containers
   cp ${XDG_RUNTIME_DIR}/containers/auth.json ${XDG_RUNTIME_DIR}/containers/auth.json.backup 2>/dev/null || true

   # Extract and merge the Solace credentials
   grep '\.dockerconfigjson:' gcr-reg-secret.yaml | awk '{print $2}' | base64 -d > /tmp/solace-creds.json

   # If auth.json exists, merge; otherwise, just copy
   if [ -f "${XDG_RUNTIME_DIR}/containers/auth.json" ]; then
       jq -s '.[0] * .[1]' ${XDG_RUNTIME_DIR}/containers/auth.json /tmp/solace-creds.json > /tmp/auth.json.new
       mv /tmp/auth.json.new ${XDG_RUNTIME_DIR}/containers/auth.json
   else
       mv /tmp/solace-creds.json ${XDG_RUNTIME_DIR}/containers/auth.json
   fi
   rm -f /tmp/solace-creds.json
   ```

#### Option 2: Use Your Own Container Registry

If you've copied SAM images to your own registry:

1. **Authenticate with your registry**:
   ```bash
   # For Docker:
   docker login your-registry.example.com

   # For Podman:
   podman login your-registry.example.com

   # Or for specific registries:
   docker login gcr.io/your-project  # or: podman login gcr.io/your-project
   docker login ghcr.io              # or: podman login ghcr.io
   ```

2. **Update image references in `.env`**:
   ```bash
   SAM_IMAGE=your-registry.example.com/sam:latest
   SAM_DEPLOYER_IMAGE=your-registry.example.com/sam-deployer:latest
   ```

**Note:** Docker/Podman Compose doesn't support per-service pull secrets. All authentication is handled at the container engine level:
- Docker: `~/.docker/config.json`
- Podman: `${XDG_RUNTIME_DIR}/containers/auth.json` (typically `/run/user/<uid>/containers/auth.json`)

## Quick Start

### Interactive Setup (Recommended)

Run the setup wizard to configure your deployment:

```bash
./setup.sh
```

The wizard will:
1. Ask about your deployment mode (Full Managed / BYO Everything / Custom)
2. Collect required LLM API credentials
3. Generate `.env` file with appropriate defaults
4. Create convenience scripts (`start.sh`, `stop.sh`, `logs.sh`)
5. Show you the exact command to start SAM

### Manual Setup

If you prefer to configure manually:

```bash
# 1. Copy template
cp .env.template .env

# 2. Edit configuration (at minimum, set SAM_LLM_API_KEY)
nano .env

# 3. Deploy based on your needs:

# BYO Everything (Minimal)
docker compose -f compose.yml up -d
# Or with Podman: podman compose -f compose.yml up -d

# Full Managed Stack (Local Development)
docker compose -f compose.yml -f compose.broker.yml -f compose.database.yml -f compose.storage.yml up -d

# Mix and Match (example: managed broker + database only)
docker compose -f compose.yml -f compose.broker.yml -f compose.database.yml up -d
```

## Architecture

SAM consists of:

- **SAM Application** - Web UI (port 8000) and orchestration engine
- **Deployer Service** - Dynamic agent deployment via container-in-container (Docker-in-Docker or Podman-in-Podman)
- **Solace Broker** - Event mesh for agent communication (managed or external)
- **PostgreSQL** - Session and metadata storage (managed or external)
- **S3 Storage** - Artifact storage and connector spec storage via SeaweedFS or external S3 (managed or external)

Each component can be **managed** (deployed by compose) or **external** (bring your own).

## How It Works

The deployment uses **compose file stacking** - you combine multiple compose files to build your deployment:

- **`compose.yml`** - Base file with SAM only, assumes BYO everything
- **`compose.broker.yml`** - Add managed Solace PubSub+ broker
- **`compose.database.yml`** - Add managed PostgreSQL
- **`compose.storage.yml`** - Add managed S3 storage (SeaweedFS)

Stack them together using multiple `-f` flags:

```bash
docker compose -f compose.yml -f compose.broker.yml -f compose.database.yml up -d
# Or with Podman:
podman compose -f compose.yml -f compose.broker.yml -f compose.database.yml up -d
```

**Benefits:**
- ✅ No templating tools required - pure compose
- ✅ Services are only included when needed
- ✅ Easy to understand and debug
- ✅ Standard compose approach
- ✅ Works with both Docker and Podman

## Deployment Profiles

### Bring Your Own Broker

```bash
# .env configuration
EXTERNAL_BROKER_URL=tcp://broker.example.com:55555
EXTERNAL_BROKER_URL_WS=ws://broker.example.com:8008
EXTERNAL_BROKER_USERNAME=sam-user
EXTERNAL_BROKER_PASSWORD=your-password
EXTERNAL_BROKER_VPN=default

# Deploy (use docker compose or podman compose)
docker compose -f compose.yml up -d
```

### Bring Your Own Database

```bash
# .env configuration
EXTERNAL_WEB_UI_DATABASE_URL=postgresql+psycopg2://user:pass@host:5432/sam_webui
EXTERNAL_ORCHESTRATOR_DATABASE_URL=postgresql+psycopg2://user:pass@host:5432/sam_orchestrator

# Deploy (use docker compose or podman compose)
docker compose -f compose.yml up -d
```

### Bring Your Own S3 Storage

SAM requires two S3 buckets:
- **Artifacts bucket**: Stores workflow artifacts and temporary files
- **Connector specs bucket**: Stores OpenAPI connector specification files (public read, private write)

```bash
# .env configuration
EXTERNAL_S3_ENDPOINT_URL=https://s3.amazonaws.com
EXTERNAL_S3_BUCKET_NAME=my-sam-artifacts
EXTERNAL_CONNECTOR_SPEC_BUCKET_NAME=my-sam-connector-specs
EXTERNAL_S3_REGION=us-east-1
EXTERNAL_S3_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
EXTERNAL_S3_SECRET_ACCESS_KEY=your-secret-key

# Deploy (use docker compose or podman compose)
docker compose -f compose.yml up -d
```

**Important - AWS S3 Bucket Policy Requirements:**

When using external AWS S3, you must create both buckets and apply a bucket policy to the connector specs bucket for public read access. Agents need to download specification files without authentication.

**Create the buckets:**
```bash
# Create artifacts bucket
aws s3 mb s3://my-sam-artifacts --region us-east-1

# Create connector specs bucket
aws s3 mb s3://my-sam-connector-specs --region us-east-1
```

**Apply public read policy to connector specs bucket:**

Save this policy as `connector-specs-policy.json`:
```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "PublicReadGetObject",
    "Effect": "Allow",
    "Principal": "*",
    "Action": "s3:GetObject",
    "Resource": "arn:aws:s3:::my-sam-connector-specs/*"
  }]
}
```

Apply the policy:
```bash
aws s3api put-bucket-policy \
  --bucket my-sam-connector-specs \
  --policy file://connector-specs-policy.json
```

The artifacts bucket should remain private (default).

### Managed Services

To use managed services, simply add the appropriate compose file:

```bash
# Managed broker (use docker compose or podman compose)
docker compose -f compose.yml -f compose.broker.yml up -d

# Managed broker + database
docker compose -f compose.yml -f compose.broker.yml -f compose.database.yml up -d

# Full managed stack
docker compose -f compose.yml -f compose.broker.yml -f compose.database.yml -f compose.storage.yml up -d
```

## Operations

**Note:** All commands below work with both `docker compose` and `podman compose`. Simply replace `docker compose` with `podman compose` if using Podman.

### Starting SAM

```bash
# Minimal - BYO everything
docker compose -f compose.yml up -d

# With managed services (example: broker + database)
docker compose -f compose.yml -f compose.broker.yml -f compose.database.yml up -d
```

### Viewing Logs

```bash
docker compose -f compose.yml logs -f sam

# Or all services
docker compose -f compose.yml -f compose.broker.yml logs -f
```

### Checking Status

```bash
docker compose -f compose.yml ps
```

### Stopping SAM

```bash
# Stop but keep data
docker compose -f compose.yml -f compose.broker.yml down

# Stop and remove all data
docker compose -f compose.yml -f compose.broker.yml down -v
```

### Cleaning Up Deployed Agents

SAM's deployer creates agent containers outside of compose:

```bash
# For Docker:
docker ps -a -q --filter "name=agent-" | xargs -r docker rm -f
rm -f ~/.sam-deployer/agent-*

# For Podman:
podman ps -a -q --filter "name=agent-" | xargs -r podman rm -f
rm -f ~/.sam-deployer/agent-*
```

### Updating Configuration

```bash
# 1. Stop SAM
docker compose -f compose.yml down

# 2. Edit configuration
nano .env

# 3. Restart SAM
docker compose -f compose.yml up -d
```

## Accessing SAM

Once started:
- **Web UI**: http://localhost:8000

## Troubleshooting

### Services Not Starting

```bash
# Check logs
docker compose -f compose.yml logs sam

# Check container engine
docker info    # For Docker
podman info    # For Podman
```

### Cannot Connect to External Services

```bash
# Test broker
nc -zv broker.example.com 55555

# Test database
psql "postgresql://user:pass@host:5432/dbname"

# Test S3
curl -v https://s3.amazonaws.com
```

### View Effective Configuration

See what services will be deployed:

```bash
docker compose -f compose.yml -f compose.broker.yml config --services
```

See full merged configuration:

```bash
docker compose -f compose.yml -f compose.broker.yml config
```

### Port Conflicts

If port 8000 is already in use, you can modify the port mappings in the compose files.

## File Structure

```
customer-compose/
├── compose.yml              # Base: SAM only (BYO everything)
├── compose.broker.yml       # Add-on: Managed broker
├── compose.database.yml     # Add-on: Managed database
├── compose.storage.yml      # Add-on: Managed storage
├── setup.sh                 # Interactive setup wizard
├── .env.template            # Configuration template
├── .env                     # Your configuration (created by setup.sh)
├── .gitignore              # Git ignore rules
└── README.md               # This file

Generated by setup.sh:
├── start.sh                 # Convenience script to start SAM
├── stop.sh                  # Convenience script to stop SAM
└── logs.sh                  # Convenience script to view logs
```

## Requirements

- **Container Engine** (choose one):
  - Docker 20.10+ with Docker Compose v2.0+
  - Podman 4.0+ with Podman Compose
- **LLM API** (OpenAI, Anthropic, or compatible endpoint)

SAM supports both Docker and Podman. The setup script will automatically detect which one is available.

### Using Podman

If using Podman, you may need to set these environment variables in your `.env` file:

```bash
CONTAINER_ENGINE=podman
CONTAINER_SOCKET=${XDG_RUNTIME_DIR}/podman/podman.sock
```

The setup script handles this automatically, but if configuring manually, uncomment these lines in `.env.template`.

## Configuration Reference

See `.env` file for all available configuration options. Key sections:

- **Image Configuration**: SAM container image tags
- **LLM Configuration**: Required for all deployments
- **External Services**: Connection details for BYO infrastructure
- **Managed Services**: Configuration for managed components

## Security Considerations

1. **Never commit** `.env` with real credentials
2. **Use secrets management** for production (Docker secrets, Vault)
3. **Change default passwords** before deploying
4. **Use HTTPS** for external endpoints
5. **Restrict network access** with firewalls/security groups

## Examples

### Development Environment

```bash
# Full managed stack for local development
# (Works with both docker compose and podman compose)
docker compose \
  -f compose.yml \
  -f compose.broker.yml \
  -f compose.database.yml \
  -f compose.storage.yml \
  up -d
```

### Production with External Infrastructure

```bash
# Configure .env with production credentials
# Deploy SAM only (use docker compose or podman compose)
docker compose -f compose.yml up -d
```

### Hybrid Deployment

```bash
# Use managed broker for simplicity, but production database and S3
# (Use docker compose or podman compose)
docker compose -f compose.yml -f compose.broker.yml up -d
```

