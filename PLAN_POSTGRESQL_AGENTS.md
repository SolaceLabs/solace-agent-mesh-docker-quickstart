# Implementation Plan: PostgreSQL Support for Dynamic Agent Deployment

## Objective
Replace SQLite with PostgreSQL for dynamically deployed agents, supporting both managed database (compose.database.yml) and BYO database modes.

## Design Decisions

### 1. Database Naming Pattern (Matches Kubernetes)
- **Database Name**: `{namespace}_{agentId}_agent`
- **Database User**: `{namespace}_{agentId}_agent`
- **Database Password**: `{agent_app_password}` (configurable)
- **Example**: `sam_019adb94_32f3_75d3_87fa_908c0e8054a4_agent`

### 2. Init Container Pattern
Use the same pattern as Kubernetes:
- Run `postgres:18.0-trixie` image as init container
- Wait for PostgreSQL to be ready (`pg_isready`)
- Create user, database, grant privileges
- Exit before agent container starts

### 3. Deployment Modes Support

| Mode | Database | Admin Credentials | Expected Behavior |
|------|----------|-------------------|-------------------|
| **BYO Everything** | External PostgreSQL | User-provided in .env | Creates per-agent DB on external instance |
| **Managed Database** | Local PostgreSQL | Auto-created admin user | Creates per-agent DB on managed instance |
| **Hybrid** | User choice | Configured in .env | Works with either |

### 4. Cleanup Strategy
**Optional database cleanup** on agent undeploy:
- Default: **KEEP** databases (for debugging, data recovery)
- Configurable: Set `CLEANUP_AGENT_DATABASES=true` to auto-drop
- Reasoning: Safer to keep data by default, explicit deletion required

---

## Implementation Details

### File 1: `compose.yml` (Most Complex)

**Section to Modify**: deployer service (lines 53-94)

#### A. Add Environment Variables for Database Configuration

```yaml
deployer:
  environment:
    # ... existing vars ...

    # Agent Database Configuration
    AGENT_DB_HOST: ${AGENT_DB_HOST:-}
    AGENT_DB_PORT: ${AGENT_DB_PORT:-5432}
    AGENT_DB_ADMIN_USER: ${AGENT_DB_ADMIN_USER:-}
    AGENT_DB_ADMIN_PASSWORD: ${AGENT_DB_ADMIN_PASSWORD:-}
    AGENT_DB_APPLICATION_PASSWORD: ${AGENT_DB_APPLICATION_PASSWORD:-}
    USE_POSTGRESQL_FOR_AGENTS: ${USE_POSTGRESQL_FOR_AGENTS:-false}
    CLEANUP_AGENT_DATABASES: ${CLEANUP_AGENT_DATABASES:-false}
```

**Lines Added**: ~7
**Complexity**: LOW

---

#### B. Update DEPLOY_COMMAND (lines 65-73)

**Current**:
```bash
DEPLOY_COMMAND: >
  cp /app/agent.env ${HOME}/.sam-deployer/agent.env && chmod 666 ${HOME}/.sam-deployer/agent.env &&
  echo '{{ configurationFile }}' > ${HOME}/.sam-deployer/agent-{{ id }}.yaml && chmod 666 ${HOME}/.sam-deployer/agent-{{ id }}.yaml &&
  ${CONTAINER_ENGINE:-docker} run -itd --network sam
  -v ${HOME}/.sam-deployer/agent-{{ id }}.yaml:/agent.yaml
  -e DATABASE_URL=sqlite:///agent_{{ id }}.db
  --env-file ${HOME}/.sam-deployer/agent.env
  --name agent-{{ id }}
  ${SAM_IMAGE}:${SAM_TAG} run /agent.yaml
```

**New (with conditional PostgreSQL init)**:
```bash
DEPLOY_COMMAND: >
  cp /app/agent.env ${HOME}/.sam-deployer/agent.env && chmod 666 ${HOME}/.sam-deployer/agent.env &&
  echo '{{ configurationFile }}' > ${HOME}/.sam-deployer/agent-{{ id }}.yaml && chmod 666 ${HOME}/.sam-deployer/agent-{{ id }}.yaml &&

  if [ "$USE_POSTGRESQL_FOR_AGENTS" = "true" ] && [ -n "$AGENT_DB_HOST" ]; then
    echo "Initializing PostgreSQL database for agent {{ id }}..." &&
    ${CONTAINER_ENGINE:-docker} run --rm --network sam
    -e PGHOST=$AGENT_DB_HOST
    -e PGPORT=$AGENT_DB_PORT
    -e PGUSER=$AGENT_DB_ADMIN_USER
    -e PGPASSWORD=$AGENT_DB_ADMIN_PASSWORD
    -e PGDATABASE=postgres
    -e DATABASE_USER=${NAMESPACE}_{{ id }}_agent
    -e DATABASE_PASSWORD=$AGENT_DB_APPLICATION_PASSWORD
    -e DATABASE_NAME=${NAMESPACE}_{{ id }}_agent
    postgres:18.0-trixie sh -c '
      until pg_isready -q; do
        echo "Waiting for PostgreSQL to be ready..."
        sleep 2
      done
      echo "Creating agent database..."
      psql -c "CREATE USER \"$DATABASE_USER\" WITH LOGIN PASSWORD '\''$DATABASE_PASSWORD'\'';" || echo "User already exists"
      psql -c "CREATE DATABASE \"$DATABASE_NAME\";" || echo "Database already exists"
      psql -c "GRANT ALL PRIVILEGES ON DATABASE \"$DATABASE_NAME\" TO \"$DATABASE_USER\";" || true
      psql -d "$DATABASE_NAME" -c "GRANT USAGE ON SCHEMA public TO \"$DATABASE_USER\";" || true
      psql -d "$DATABASE_NAME" -c "GRANT CREATE ON SCHEMA public TO \"$DATABASE_USER\";" || true
      psql -d "$DATABASE_NAME" -c "GRANT ALL ON ALL TABLES IN SCHEMA public TO \"$DATABASE_USER\";" || true
      psql -d "$DATABASE_NAME" -c "GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO \"$DATABASE_USER\";" || true
      psql -d "$DATABASE_NAME" -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO \"$DATABASE_USER\";" || true
      psql -d "$DATABASE_NAME" -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO \"$DATABASE_USER\";" || true
      echo "Database initialization complete"
    ' &&
    AGENT_DATABASE_URL="postgresql+psycopg2://${NAMESPACE}_{{ id }}_agent:$AGENT_DB_APPLICATION_PASSWORD@$AGENT_DB_HOST:$AGENT_DB_PORT/${NAMESPACE}_{{ id }}_agent"
  else
    AGENT_DATABASE_URL="sqlite:///agent_{{ id }}.db"
  fi &&

  ${CONTAINER_ENGINE:-docker} run -itd --network sam
  -v ${HOME}/.sam-deployer/agent-{{ id }}.yaml:/agent.yaml
  -e DATABASE_URL=$AGENT_DATABASE_URL
  --env-file ${HOME}/.sam-deployer/agent.env
  --name agent-{{ id }}
  ${SAM_IMAGE}:${SAM_TAG} run /agent.yaml
```

**Lines Modified**: ~15
**Lines Added**: ~30
**Complexity**: HIGH
**Challenges**:
- Shell escaping (nested quotes)
- Variable substitution (Docker Compose + shell)
- Error handling
- Conditional logic

---

#### C. Update UPDATE_COMMAND (lines 74-82)

**Logic**: Same as DEPLOY but skip database creation (database already exists)

```bash
UPDATE_COMMAND: >
  ${CONTAINER_ENGINE:-docker} stop agent-{{ id }} && ${CONTAINER_ENGINE:-docker} rm agent-{{ id }} &&
  echo '{{ configurationFile }}' > ${HOME}/.sam-deployer/agent-{{ id }}.yaml && chmod 666 ${HOME}/.sam-deployer/agent-{{ id }}.yaml &&

  if [ "$USE_POSTGRESQL_FOR_AGENTS" = "true" ] && [ -n "$AGENT_DB_HOST" ]; then
    AGENT_DATABASE_URL="postgresql+psycopg2://${NAMESPACE}_{{ id }}_agent:$AGENT_DB_APPLICATION_PASSWORD@$AGENT_DB_HOST:$AGENT_DB_PORT/${NAMESPACE}_{{ id }}_agent"
  else
    AGENT_DATABASE_URL="sqlite:///agent_{{ id }}.db"
  fi &&

  ${CONTAINER_ENGINE:-docker} run -itd --network sam
  -v ${HOME}/.sam-deployer/agent-{{ id }}.yaml:/agent.yaml
  -e DATABASE_URL=$AGENT_DATABASE_URL
  --env-file ${HOME}/.sam-deployer/agent.env
  --name agent-{{ id }}
  ${SAM_IMAGE}:${SAM_TAG} run /agent.yaml
```

**Lines Modified**: ~10
**Lines Added**: ~8
**Complexity**: MEDIUM

---

#### D. Update UNDEPLOY_COMMAND (line 84)

**Add optional database cleanup**:

```bash
UNDEPLOY_COMMAND: >
  ${CONTAINER_ENGINE:-docker} stop agent-{{ id }} &&
  ${CONTAINER_ENGINE:-docker} rm agent-{{ id }} &&

  if [ "$USE_POSTGRESQL_FOR_AGENTS" = "true" ] && [ "$CLEANUP_AGENT_DATABASES" = "true" ] && [ -n "$AGENT_DB_HOST" ]; then
    echo "Cleaning up agent database..." &&
    ${CONTAINER_ENGINE:-docker} run --rm --network sam
    -e PGHOST=$AGENT_DB_HOST
    -e PGPORT=$AGENT_DB_PORT
    -e PGUSER=$AGENT_DB_ADMIN_USER
    -e PGPASSWORD=$AGENT_DB_ADMIN_PASSWORD
    -e PGDATABASE=postgres
    postgres:18.0-trixie sh -c '
      psql -c "DROP DATABASE IF EXISTS \"${NAMESPACE}_{{ id }}_agent\";" || echo "Database cleanup failed (may not exist)"
      psql -c "DROP USER IF EXISTS \"${NAMESPACE}_{{ id }}_agent\";" || echo "User cleanup failed (may not exist)"
      echo "Cleanup complete"
    ' || echo "Database cleanup failed but agent was removed"
  fi
```

**Lines Modified**: ~2
**Lines Added**: ~15
**Complexity**: MEDIUM

---

### File 2: `compose.database.yml`

#### A. Create Agent Database Admin User

**Modify init.sql** (lines 36-45):

```yaml
configs:
  init.sql:
    content: |
      -- Core service databases
      CREATE USER webui WITH PASSWORD 'webui';
      CREATE DATABASE webui OWNER webui;

      CREATE USER platform WITH PASSWORD 'platform';
      CREATE DATABASE platform OWNER platform;

      CREATE USER orchestrator WITH PASSWORD 'orchestrator';
      CREATE DATABASE orchestrator OWNER orchestrator;

      -- Agent database admin user
      CREATE USER ${POSTGRES_AGENT_ADMIN_USER} WITH PASSWORD '${POSTGRES_AGENT_ADMIN_PASSWORD}' CREATEDB;
      GRANT CREATE ON DATABASE postgres TO ${POSTGRES_AGENT_ADMIN_USER};
```

**Lines Added**: ~3
**Complexity**: LOW

---

#### B. Pass Agent Database Config to Deployer

**Add to deployer environment** (new section after sam service):

```yaml
services:
  sam:
    # ... existing config ...

  deployer:
    environment:
      # Agent database configuration for managed PostgreSQL
      AGENT_DB_HOST: postgres
      AGENT_DB_PORT: 5432
      AGENT_DB_ADMIN_USER: ${POSTGRES_AGENT_ADMIN_USER}
      AGENT_DB_ADMIN_PASSWORD: ${POSTGRES_AGENT_ADMIN_PASSWORD}
      AGENT_DB_APPLICATION_PASSWORD: ${POSTGRES_AGENT_APP_PASSWORD}
      USE_POSTGRESQL_FOR_AGENTS: true
```

**Lines Added**: ~8
**Complexity**: LOW

---

### File 3: `.env.template`

#### Add Agent Database Configuration Section

**After line 91** (after MANAGED DATABASE CONFIGURATION):

```bash
# ==========================================
# AGENT DATABASE CONFIGURATION
# Used for dynamically deployed agents
# ==========================================

# Enable PostgreSQL for agents (default: false uses SQLite)
USE_POSTGRESQL_FOR_AGENTS=false

# Managed database mode (when using compose-database.yml)
POSTGRES_AGENT_ADMIN_USER=agent_admin
POSTGRES_AGENT_ADMIN_PASSWORD=agent_admin
POSTGRES_AGENT_APP_PASSWORD=agent_password

# BYO database mode (when using compose.yml only with external database)
AGENT_DB_HOST=your-postgres-host
AGENT_DB_PORT=5432
AGENT_DB_ADMIN_USER=agent_admin
AGENT_DB_ADMIN_PASSWORD=your-admin-password
AGENT_DB_APPLICATION_PASSWORD=your-app-password

# Cleanup agent databases on undeploy (default: false to preserve data)
CLEANUP_AGENT_DATABASES=false
```

**Lines Added**: ~20
**Complexity**: LOW

---

### File 4: `README.md` (Documentation)

#### Add Agent Database Configuration Section

**After "Configuration Reference" section**:

```markdown
### Agent Database Configuration

By default, dynamically deployed agents use SQLite for session persistence. You can configure agents to use PostgreSQL instead for production-ready persistence.

#### Enable PostgreSQL for Agents

**Managed Database Mode** (with compose.database.yml):

```bash
# In .env file
USE_POSTGRESQL_FOR_AGENTS=true
POSTGRES_AGENT_ADMIN_USER=agent_admin
POSTGRES_AGENT_ADMIN_PASSWORD=agent_admin
POSTGRES_AGENT_APP_PASSWORD=agent_password
```

**BYO Database Mode**:

```bash
# In .env file
USE_POSTGRESQL_FOR_AGENTS=true
AGENT_DB_HOST=your-postgres-host.example.com
AGENT_DB_PORT=5432
AGENT_DB_ADMIN_USER=your_admin_user
AGENT_DB_ADMIN_PASSWORD=your_admin_password
AGENT_DB_APPLICATION_PASSWORD=your_app_password
```

**Requirements for BYO mode:**
- Admin user must have `CREATEDB` privilege
- Admin user must be able to create users and grant privileges

#### Database Cleanup

By default, agent databases are preserved when agents are undeployed (for debugging and data recovery).

To enable automatic cleanup:

```bash
# In .env file
CLEANUP_AGENT_DATABASES=true
```

⚠️ **Warning**: Enabling cleanup will permanently delete agent databases on undeploy.

#### Database Naming

Each agent gets a dedicated PostgreSQL database:
- Pattern: `{namespace}_{agentId}_agent`
- Example: `sam_019adb94_32f3_75d3_87fa_908c0e8054a4_agent`

To view agent databases:

```bash
docker compose exec postgres psql -U sam -c "\l" | grep _agent
```
```

**Lines Added**: ~50
**Complexity**: LOW

---

## Implementation Steps

### Phase 1: Core PostgreSQL Support (Mandatory)

**Estimated Effort**: 3-4 hours

1. ✅ Update `compose.yml`:
   - Add deployer environment variables (7 lines)
   - Modify DEPLOY_COMMAND with init container logic (30 lines)
   - Modify UPDATE_COMMAND with conditional DATABASE_URL (8 lines)

2. ✅ Update `compose.database.yml`:
   - Add agent admin user to init.sql (3 lines)
   - Add deployer environment overrides (8 lines)

3. ✅ Update `.env.template`:
   - Add agent database configuration section (20 lines)

**Total**: ~76 lines added, ~27 lines modified

---

### Phase 2: Cleanup & Error Handling (Recommended)

**Estimated Effort**: 1-2 hours

4. ✅ Update UNDEPLOY_COMMAND in `compose.yml`:
   - Add optional database cleanup logic (15 lines)
   - Add error handling and logging

**Total**: ~15 lines added

---

### Phase 3: Documentation (Mandatory)

**Estimated Effort**: 1 hour

5. ✅ Update `README.md`:
   - Add agent database configuration section (50 lines)
   - Add troubleshooting guide
   - Add examples

**Total**: ~50 lines added

---

## Technical Challenges & Solutions

### Challenge 1: Shell Escaping
**Problem**: Nested quotes in multi-line bash commands

**Solution**:
- Use `'\''` for single quotes within single-quoted strings
- Test extensively with special characters in passwords
- Document password requirements (avoid special chars initially)

### Challenge 2: Variable Substitution Order
**Problem**: Docker Compose substitutes `${VAR}` but shell also uses `$VAR`

**Solution**:
- Use `${VAR}` for Docker Compose substitution
- Use `$VAR` for shell variables (set in the command itself)
- Use `$$VAR` for escaping when needed

### Challenge 3: Init Container Failure Handling
**Problem**: If database creation fails, should agent start anyway?

**Solution**:
- Use `&&` to chain commands (fail-fast)
- Init container failure prevents agent start
- Agent undeploy should still work even if init failed

### Challenge 4: Idempotency
**Problem**: Agent redeploy with same ID should reuse database

**Solution**:
- Use `CREATE ... || true` or `CREATE IF NOT EXISTS` pattern
- Don't fail if user/database already exists
- Log warnings but continue

### Challenge 5: BYO Mode Validation
**Problem**: How to ensure BYO database credentials work?

**Solution**:
- Init container will fail with clear error if credentials wrong
- Document common issues in README
- Add troubleshooting section

---

## Testing Strategy

### Test Matrix

| Test Case | Setup | Expected Result | Priority |
|-----------|-------|-----------------|----------|
| **1. Managed DB + SQLite (default)** | USE_POSTGRESQL_FOR_AGENTS=false | Agent uses SQLite, no PostgreSQL init | P0 |
| **2. Managed DB + PostgreSQL** | USE_POSTGRESQL_FOR_AGENTS=true + compose.database.yml | Per-agent DB created, agent starts | P0 |
| **3. BYO DB + PostgreSQL** | USE_POSTGRESQL_FOR_AGENTS=true + external DB config | Per-agent DB created on external instance | P0 |
| **4. Deploy 2nd agent (managed)** | Same as test 2, deploy another agent | 2nd separate DB created | P0 |
| **5. Redeploy same agent** | Deploy, undeploy, deploy same agent | Reuses existing database | P1 |
| **6. Update agent config** | Deploy, then update | No new DB created | P1 |
| **7. Undeploy with cleanup=true** | CLEANUP_AGENT_DATABASES=true | Database dropped | P1 |
| **8. Undeploy with cleanup=false** | CLEANUP_AGENT_DATABASES=false | Database preserved | P1 |
| **9. Invalid admin credentials** | Wrong AGENT_DB_ADMIN_PASSWORD | Init container fails with clear error | P2 |
| **10. Database connection failure** | PostgreSQL down during init | Init container retries, eventually fails | P2 |
| **11. Special chars in password** | Password with quotes/spaces | Properly escaped, works | P2 |
| **12. Concurrent deploys** | Deploy 5 agents simultaneously | All get unique databases | P2 |

---

## Rollout Strategy

### Approach: **Opt-In with SQLite Default** (Safest)

**Phase 1: Initial Release**
- Default: `USE_POSTGRESQL_FOR_AGENTS=false` (SQLite)
- Users opt-in by setting `USE_POSTGRESQL_FOR_AGENTS=true`
- Document in README as optional feature
- Gather feedback from early adopters

**Phase 2: Validate & Improve** (After 2-4 weeks)
- Fix edge cases discovered
- Improve error messages
- Add monitoring/troubleshooting tools

**Phase 3: Make Default** (After proven stable)
- Change default to `USE_POSTGRESQL_FOR_AGENTS=true`
- Update README to promote PostgreSQL as recommended
- Document SQLite as fallback option

**Phase 4: Deprecate SQLite** (Long-term)
- Announce SQLite deprecation
- Provide migration guide
- Eventually remove SQLite support

---

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| **Init container fails silently** | Medium | High | Add verbose logging, keep container on failure |
| **Password escaping breaks SQL** | Medium | High | Extensive testing, document safe password patterns |
| **Connection pool exhaustion** | Low | Medium | Document max_connections tuning |
| **Database bloat from orphaned DBs** | Medium | Low | Default cleanup=false + doc cleanup procedures |
| **BYO mode credential issues** | Medium | Medium | Clear error messages, troubleshooting guide |
| **Regression: SQLite stops working** | Low | High | Test both modes in CI |

---

## Success Criteria

### Functional Requirements
- ✅ Agent deploys successfully with PostgreSQL database (managed mode)
- ✅ Agent deploys successfully with PostgreSQL database (BYO mode)
- ✅ Each agent has isolated database
- ✅ Agent can persist session data to PostgreSQL
- ✅ Backward compatibility: SQLite still works
- ✅ Database cleanup works when enabled
- ✅ Idempotent: Redeploy reuses existing database

### Non-Functional Requirements
- ✅ Clear error messages on failure
- ✅ All deployment modes supported (BYO, Managed, Hybrid)
- ✅ Documentation complete with examples
- ✅ No breaking changes to existing deployments
- ✅ Performance: Init adds <10s to deployment time

---

## Code Complexity Estimate

### Summary

| File | Lines Added | Lines Modified | Complexity | Effort |
|------|-------------|----------------|------------|--------|
| `compose.yml` | ~53 | ~27 | HIGH | 3h |
| `compose.database.yml` | ~11 | ~0 | LOW | 30m |
| `.env.template` | ~20 | ~0 | LOW | 15m |
| `README.md` | ~50 | ~10 | LOW | 1h |
| **TOTAL** | **~134** | **~37** | **MEDIUM-HIGH** | **~5h** |

### Testing Effort
- Unit testing: N/A (infrastructure code)
- Integration testing: 12 test cases × 15 min = **3h**
- Regression testing: All existing modes = **1h**

**Total Estimated Effort: 9 hours** (1 full workday + testing)

---

## Alternative Approaches Considered

### Alternative 1: Shared Database with Schemas
**Approach**: All agents use same database, different schemas

**Pros**: Much simpler (5 lines changed)
**Cons**: Less isolation, complex cleanup, schema name collisions
**Decision**: REJECTED - doesn't match Kubernetes pattern

### Alternative 2: Deployer-Managed Database Creation
**Approach**: Deployer image includes PostgreSQL client, creates DBs natively

**Pros**: Simpler DEPLOY_COMMAND, single container
**Cons**: Requires deployer image rebuild, less testable
**Decision**: REJECTED - requires image changes (out of scope for quickstart)

### Alternative 3: Keep SQLite Only
**Approach**: No changes, document as limitation

**Pros**: Zero complexity
**Cons**: Not production-ready, doesn't match Kubernetes
**Decision**: REJECTED - user explicitly requested PostgreSQL

### Alternative 4: Sidecar Init Pattern (SELECTED)
**Approach**: Run postgres image as init container before agent

**Pros**: Mirrors Kubernetes, no image changes, testable, clean separation
**Cons**: More complex DEPLOY_COMMAND, two containers per deployment
**Decision**: ACCEPTED - best balance of complexity vs functionality

---

## Implementation Plan

### Step 1: Update compose.yml (Core Logic)
1. Add environment variables to deployer service
2. Modify DEPLOY_COMMAND with conditional init logic
3. Modify UPDATE_COMMAND with conditional DATABASE_URL
4. Modify UNDEPLOY_COMMAND with conditional cleanup

### Step 2: Update compose.database.yml (Managed Support)
1. Add agent admin user to init.sql
2. Add deployer environment overrides for managed mode

### Step 3: Update .env.template (Configuration)
1. Add agent database configuration section
2. Set sensible defaults
3. Add comments explaining each variable

### Step 4: Update README.md (Documentation)
1. Add agent database configuration guide
2. Add examples for each mode
3. Add troubleshooting section
4. Update deployment mode table

### Step 5: Testing
1. Test each deployment mode
2. Test edge cases (redeploy, cleanup, invalid creds)
3. Verify backward compatibility

### Step 6: Create PRs
1. Update existing PR with these changes
2. Update PR description with new scope
3. Request review with detailed testing notes

---

## Open Questions for User

Before proceeding with implementation, I need clarification on:

1. **Default Behavior**: Should PostgreSQL be opt-in (`USE_POSTGRESQL_FOR_AGENTS=false` by default) or default (`true`)?
   - **Recommendation**: Opt-in initially for safety

2. **Database Cleanup**: Should cleanup be default-on or default-off?
   - **Recommendation**: Default-off (safer, preserves data)

3. **Password Complexity**: Should we support special characters in passwords or start simple?
   - **Recommendation**: Start simple (alphanumeric only), add escaping later

4. **Error Handling**: Should init container failure be hard-fail or soft-fail with fallback to SQLite?
   - **Recommendation**: Hard-fail (fail-fast, clear errors)

5. **Backward Compatibility**: Should we maintain SQLite support indefinitely or plan deprecation?
   - **Recommendation**: Keep both, document PostgreSQL as recommended

---

## Next Steps

1. **Get user approval** on design decisions
2. **Clarify open questions** above
3. **Implement changes** following the plan
4. **Test thoroughly** using test matrix
5. **Update PRs** with complete implementation
6. **Document Docker CLI issue** as separate known limitation

---

## Estimated Timeline

- **Planning & Design**: ✅ Complete
- **Implementation**: 5 hours
- **Testing**: 4 hours
- **Documentation**: 1 hour
- **PR Updates**: 30 minutes
- **Total**: **1.5 workdays**

Ready to proceed with implementation once design is approved!
