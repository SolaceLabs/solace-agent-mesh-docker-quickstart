# Platform Service Split - Docker Quickstart Migration

## Overview

Split the single SAM service into two separate services:
- **WebUI Gateway** (port 8000) - Chat operations
- **Platform Service** (port 8001) - Agent management, connectors, deployments

## Required Changes

### 1. compose.yml

**Current**: Single `sam` service
**New**: Two services (`sam-webui` + `sam-platform`)

```yaml
services:
  # Rename 'sam' → 'sam-webui'
  sam-webui:
    image: ${SAM_IMAGE}:${SAM_TAG}
    ports:
      - "8000:8000"  # Remove 8080
    environment:
      WEB_UI_GATEWAY_DATABASE_URL: ${WEB_UI_DATABASE_URL}
      # REMOVE: PLATFORM_DATABASE_URL
      PLATFORM_SERVICE_URL: http://sam-platform:8001  # NEW!
    command:
      - "run"
      - "--system-env"
      - "/app/configs/a2a_orchestrator.yaml"
      - "/app/configs/webui_backend.yaml"
      # Remove enterprise_config if present

  # NEW SERVICE
  sam-platform:
    image: ${SAM_ENTERPRISE_IMAGE}:${SAM_ENTERPRISE_TAG}
    ports:
      - "8001:8001"
    environment:
      NAMESPACE: ${NAMESPACE}
      PLATFORM_DATABASE_URL: ${PLATFORM_DATABASE_URL}
      SOLACE_BROKER_URL: ${SOLACE_BROKER_URL_TCP}
      SOLACE_BROKER_CLIENT_USERNAME: ${SOLACE_BROKER_CLIENT_USERNAME}
      SOLACE_BROKER_CLIENT_PASSWORD: ${SOLACE_BROKER_CLIENT_PASSWORD}
      SOLACE_BROKER_VPN: ${SOLACE_BROKER_VPN}
      USE_AUTHORIZATION: "false"
    configs:
      - source: platform_service.yaml
        target: /app/configs/platform.yaml
      - source: shared_config.yaml
        target: /app/configs/shared_config.yaml
    depends_on:
      postgres:
        condition: service_healthy
      broker:
        condition: service_healthy

configs:
  # NEW
  platform_service.yaml:
    content: |
      log:
        stdout_log_level: INFO

      !include shared_config.yaml

      apps:
        - name: platform_service
          app_module: solace_agent_mesh.services.platform.app
          broker:
            broker_url: "$${SOLACE_BROKER_URL}"
            broker_username: "$${SOLACE_BROKER_CLIENT_USERNAME}"
            broker_password: "$${SOLACE_BROKER_CLIENT_PASSWORD}"
            broker_vpn: "$${SOLACE_BROKER_VPN}"
          app_config:
            namespace: "$${NAMESPACE}"
            database_url: "$${PLATFORM_DATABASE_URL}"
            fastapi_port: 8001
            use_authorization: false

  # UPDATE webui_backend.yml
  webui_backend.yml:
    content: |
      # ... existing config ...
      platform_service:  # ADD THIS
        url: "$${PLATFORM_SERVICE_URL}"
```

### 2. .env

Add new variables:

```bash
# NEW: Enterprise image for platform service
SAM_ENTERPRISE_IMAGE=gcr.io/stellar-arcadia-205014/solace-agent-mesh-enterprise
SAM_ENTERPRISE_TAG=latest

# NEW: Platform Service URL
PLATFORM_SERVICE_URL=http://sam-platform:8001
```

### 3. .env.template

Same additions as .env for documentation.

## Testing

```bash
# Start all services
docker compose -f compose.yml -f compose.broker.yml -f compose.database.yml up

# Verify both services running
docker ps | grep sam
# Should see: sam-webui and sam-platform

# Test WebUI
curl http://localhost:8000/health

# Test Platform
curl http://localhost:8001/health

# Test config endpoint
curl http://localhost:8000/api/v1/config | jq .frontend_enterprise_server_url
# Should return: "http://sam-platform:8001"
```

## Migration for Existing Users

1. Pull latest docker-quickstart
2. Update .env with new variables
3. `docker compose down`
4. `docker compose up` (will create both services)
