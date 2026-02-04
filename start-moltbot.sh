#!/bin/bash
# Startup script for Moltbot in Cloudflare Sandbox
# This script:
# 1. Restores config from R2 backup if available
# 2. Configures moltbot from environment variables
# 3. Starts a background sync to backup config to R2
# 4. Starts the gateway

set -e
export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"

CLAWDBOT_BIN="$(command -v clawdbot || true)"
if [ -z "$CLAWDBOT_BIN" ]; then
  for candidate in /usr/local/bin/clawdbot /usr/bin/clawdbot /root/.local/bin/clawdbot; do
    if [ -x "$candidate" ]; then
      CLAWDBOT_BIN="$candidate"
      break
    fi
  done
fi

if [ -z "$CLAWDBOT_BIN" ]; then
  echo "clawdbot binary not found in PATH; check container build." >&2
  exit 127
fi

# Check if clawdbot gateway is already running - bail early if so
# Note: CLI is still named "clawdbot" until upstream renames it
if pgrep -f "clawdbot gateway" >/dev/null 2>&1; then
  echo "Moltbot gateway is already running, exiting."
  exit 0
fi

# Paths (clawdbot paths are used internally - upstream hasn't renamed yet)
CONFIG_DIR="/root/.clawdbot"
CONFIG_FILE="$CONFIG_DIR/clawdbot.json"
TEMPLATE_DIR="/root/.clawdbot-templates"
TEMPLATE_FILE="$TEMPLATE_DIR/moltbot.json.template"
BACKUP_DIR="/data/moltbot"

echo "Config directory: $CONFIG_DIR"
echo "Backup directory: $BACKUP_DIR"

# Create config directory
mkdir -p "$CONFIG_DIR"

# ============================================================
# RESTORE FROM R2 BACKUP
# ============================================================
# Check if R2 backup exists by looking for clawdbot.json
# The BACKUP_DIR may exist but be empty if R2 was just mounted
# Note: backup structure is $BACKUP_DIR/clawdbot/ and $BACKUP_DIR/skills/

# Helper function to check if R2 backup is newer than local
should_restore_from_r2() {
  local R2_SYNC_FILE="$BACKUP_DIR/.last-sync"
  local LOCAL_SYNC_FILE="$CONFIG_DIR/.last-sync"

  # If no R2 sync timestamp, don't restore
  if [ ! -f "$R2_SYNC_FILE" ]; then
    echo "No R2 sync timestamp found, skipping restore"
    return 1
  fi

  # If no local sync timestamp, restore from R2
  if [ ! -f "$LOCAL_SYNC_FILE" ]; then
    echo "No local sync timestamp, will restore from R2"
    return 0
  fi

  # Compare timestamps
  R2_TIME=$(cat "$R2_SYNC_FILE" 2>/dev/null)
  LOCAL_TIME=$(cat "$LOCAL_SYNC_FILE" 2>/dev/null)

  echo "R2 last sync: $R2_TIME"
  echo "Local last sync: $LOCAL_TIME"

  # Convert to epoch seconds for comparison
  R2_EPOCH=$(date -d "$R2_TIME" +%s 2>/dev/null || echo "0")
  LOCAL_EPOCH=$(date -d "$LOCAL_TIME" +%s 2>/dev/null || echo "0")

  if [ "$R2_EPOCH" -gt "$LOCAL_EPOCH" ]; then
    echo "R2 backup is newer, will restore"
    return 0
  else
    echo "Local data is newer or same, skipping restore"
    return 1
  fi
}

if [ -f "$BACKUP_DIR/clawdbot/clawdbot.json" ]; then
  if should_restore_from_r2; then
    echo "Restoring from R2 backup at $BACKUP_DIR/clawdbot..."
    if ! cp -a "$BACKUP_DIR/clawdbot/." "$CONFIG_DIR/"; then
      echo "Warning: restore copy encountered missing files; continuing"
    fi
    # Copy the sync timestamp to local so we know what version we have
    cp -f "$BACKUP_DIR/.last-sync" "$CONFIG_DIR/.last-sync" 2>/dev/null || true
    echo "Restored config from R2 backup"
  fi
elif [ -f "$BACKUP_DIR/clawdbot.json" ]; then
  # Legacy backup format (flat structure)
  if should_restore_from_r2; then
    echo "Restoring from legacy R2 backup at $BACKUP_DIR..."
    if ! cp -a "$BACKUP_DIR/." "$CONFIG_DIR/"; then
      echo "Warning: legacy restore copy encountered missing files; continuing"
    fi
    cp -f "$BACKUP_DIR/.last-sync" "$CONFIG_DIR/.last-sync" 2>/dev/null || true
    echo "Restored config from legacy R2 backup"
  fi
elif [ -d "$BACKUP_DIR" ]; then
  echo "R2 mounted at $BACKUP_DIR but no backup data found yet"
else
  echo "R2 not mounted, starting fresh"
fi

# Restore skills from R2 backup if available (only if R2 is newer)
CLAWD_DIR="/root/clawd"
SKILLS_DIR="$CLAWD_DIR/skills"
if [ -d "$BACKUP_DIR/skills" ] && [ "$(ls -A $BACKUP_DIR/skills 2>/dev/null)" ]; then
  if should_restore_from_r2; then
    echo "Restoring skills from $BACKUP_DIR/skills..."
    mkdir -p "$SKILLS_DIR"
    if ! cp -a "$BACKUP_DIR/skills/." "$SKILLS_DIR/"; then
      echo "Warning: skills restore encountered missing files; continuing"
    fi
    echo "Restored skills from R2 backup"
  fi
fi

# Restore workspace data from R2 backup if available (e.g., IDENTITY.md, memory/)
if [ -d "$BACKUP_DIR/clawd" ] && [ "$(ls -A $BACKUP_DIR/clawd 2>/dev/null)" ]; then
  if should_restore_from_r2; then
    echo "Restoring workspace data from $BACKUP_DIR/clawd..."
    mkdir -p "$CLAWD_DIR"
    if ! cp -a "$BACKUP_DIR/clawd/." "$CLAWD_DIR/"; then
      echo "Warning: workspace restore encountered missing files; continuing"
    fi
    echo "Restored workspace data from R2 backup"
  fi
fi

# If config file still doesn't exist, create from template
if [ ! -f "$CONFIG_FILE" ]; then
  echo "No existing config found, initializing from template..."
  if [ -f "$TEMPLATE_FILE" ]; then
    cp "$TEMPLATE_FILE" "$CONFIG_FILE"
  else
    # Create minimal config if template doesn't exist
    cat >"$CONFIG_FILE" <<'EOFCONFIG'
{
  "agents": {
    "defaults": {
      "workspace": "/root/clawd"
    }
  },
  "gateway": {
    "port": 18789,
    "mode": "local"
  }
}
EOFCONFIG
  fi
else
  echo "Using existing config"
fi

# ============================================================
# UPDATE CONFIG FROM ENVIRONMENT VARIABLES
# ============================================================
node <<'EOFNODE'
const fs = require('fs');

const configPath = '/root/.clawdbot/clawdbot.json';
console.log('Updating config at:', configPath);
let config = {};

try {
    config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
} catch (e) {
    console.log('Starting with empty config');
}

// Ensure nested objects exist
config.agents = config.agents || {};
config.agents.defaults = config.agents.defaults || {};
config.agents.defaults.model = config.agents.defaults.model || {};
config.gateway = config.gateway || {};
config.channels = config.channels || {};
const normalizeOpenRouterModel = (value) => {
    if (!value) return null;
    const trimmed = value.trim();
    if (!trimmed) return null;
    const lower = trimmed.toLowerCase();
    if (lower.startsWith('openrouter/')) {
        const id = lower.slice('openrouter/'.length);
        return id ? { id, ref: lower } : null;
    }
    return { id: lower, ref: `openrouter/${lower}` };
};
const redactConfigForLogs = (value) => {
    const secretKeyPattern = /(apiKey|accessKey|secret|token|botToken|appToken)/i;
    if (Array.isArray(value)) {
        return value.map(redactConfigForLogs);
    }
    if (value && typeof value === 'object') {
        const result = {};
        for (const [key, child] of Object.entries(value)) {
            if (secretKeyPattern.test(key)) {
                result[key] = '[REDACTED]';
            } else {
                result[key] = redactConfigForLogs(child);
            }
        }
        return result;
    }
    return value;
};

// Clean up any broken anthropic provider config from previous runs
// (older versions didn't include required 'name' field)
if (config.models?.providers?.anthropic?.models) {
    const hasInvalidModels = config.models.providers.anthropic.models.some(m => !m.name);
    if (hasInvalidModels) {
        console.log('Removing broken anthropic provider config (missing model names)');
        delete config.models.providers.anthropic;
    }
}



// Gateway configuration
config.gateway.port = 18789;
config.gateway.mode = 'local';
config.gateway.trustedProxies = ['10.1.0.0'];

// Set gateway token if provided
if (process.env.CLAWDBOT_GATEWAY_TOKEN) {
    config.gateway.auth = config.gateway.auth || {};
    config.gateway.auth.token = process.env.CLAWDBOT_GATEWAY_TOKEN;
}

// Allow insecure auth for dev mode
if (process.env.CLAWDBOT_DEV_MODE === 'true') {
    config.gateway.controlUi = config.gateway.controlUi || {};
    config.gateway.controlUi.allowInsecureAuth = true;
}

const setIfDefined = (obj, key, value) => {
    if (value === undefined || value === null || value === '') return;
    obj[key] = value;
};

// Telegram configuration (preserve existing fields like allowFrom)
if (process.env.TELEGRAM_BOT_TOKEN) {
    config.channels.telegram = config.channels.telegram || {};
    config.channels.telegram.botToken = process.env.TELEGRAM_BOT_TOKEN;
    if (config.channels.telegram.enabled === undefined) {
        config.channels.telegram.enabled = true;
    }
    setIfDefined(config.channels.telegram, 'dmPolicy', process.env.TELEGRAM_DM_POLICY);
}

// Discord configuration (preserve existing fields)
if (process.env.DISCORD_BOT_TOKEN) {
    config.channels.discord = config.channels.discord || {};
    config.channels.discord.token = process.env.DISCORD_BOT_TOKEN;
    if (config.channels.discord.enabled === undefined) {
        config.channels.discord.enabled = true;
    }
    if (process.env.DISCORD_DM_POLICY) {
        config.channels.discord.dm = config.channels.discord.dm || {};
        setIfDefined(config.channels.discord.dm, 'policy', process.env.DISCORD_DM_POLICY);
    }
}

// Slack configuration (preserve existing fields)
if (process.env.SLACK_BOT_TOKEN && process.env.SLACK_APP_TOKEN) {
    config.channels.slack = config.channels.slack || {};
    config.channels.slack.botToken = process.env.SLACK_BOT_TOKEN;
    config.channels.slack.appToken = process.env.SLACK_APP_TOKEN;
    if (config.channels.slack.enabled === undefined) {
        config.channels.slack.enabled = true;
    }
}

// OpenRouter configuration (highest priority)
const openrouterModel = normalizeOpenRouterModel(process.env.OPENROUTER_MODEL || '');
const hasOpenrouterKey = Boolean(process.env.OPENROUTER_API_KEY);
if (hasOpenrouterKey && !openrouterModel) {
    console.error('OPENROUTER_API_KEY is set but OPENROUTER_MODEL is missing; refusing to fall back to other providers');
    process.exit(1);
}
const hasOpenrouterConfig = Boolean(hasOpenrouterKey && openrouterModel);
const openrouterBaseUrl = 'https://openrouter.ai/api/v1';

// Base URL override (e.g., for Cloudflare AI Gateway)
// Usage: Set AI_GATEWAY_BASE_URL or ANTHROPIC_BASE_URL to your endpoint like:
//   https://gateway.ai.cloudflare.com/v1/{account_id}/{gateway_id}/anthropic
//   https://gateway.ai.cloudflare.com/v1/{account_id}/{gateway_id}/openai
const baseUrl = (process.env.AI_GATEWAY_BASE_URL || process.env.ANTHROPIC_BASE_URL || '').replace(/\/+$/, '');
const isOpenAI = baseUrl.endsWith('/openai');

if (hasOpenrouterConfig) {
    const alias = process.env.OPENROUTER_MODEL_ALIAS || openrouterModel.id;
    console.log('Configuring OpenRouter provider with base URL:', openrouterBaseUrl);
    console.log('OpenRouter primary model:', openrouterModel.ref);
    config.models = config.models || {};
    config.models.providers = config.models.providers || {};
    config.models.providers.openrouter = {
        baseUrl: openrouterBaseUrl,
        api: 'openai-completions',
        models: [
            { id: openrouterModel.id, name: alias },
        ]
    };
    config.agents.defaults.models = config.agents.defaults.models || {};
    config.agents.defaults.models[openrouterModel.ref] = { alias };
    config.agents.defaults.model.primary = openrouterModel.ref;
} else if (isOpenAI) {
    // Create custom openai provider config with baseUrl override
    // Omit apiKey so moltbot falls back to OPENAI_API_KEY env var
    console.log('Configuring OpenAI provider with base URL:', baseUrl);
    config.models = config.models || {};
    config.models.providers = config.models.providers || {};
    config.models.providers.openai = {
        baseUrl: baseUrl,
        api: 'openai-responses',
        models: [
            { id: 'gpt-5.2', name: 'GPT-5.2', contextWindow: 200000 },
            { id: 'gpt-5', name: 'GPT-5', contextWindow: 200000 },
            { id: 'gpt-4.5-preview', name: 'GPT-4.5 Preview', contextWindow: 128000 },
        ]
    };
    // Add models to the allowlist so they appear in /models
    config.agents.defaults.models = config.agents.defaults.models || {};
    config.agents.defaults.models['openai/gpt-5.2'] = { alias: 'GPT-5.2' };
    config.agents.defaults.models['openai/gpt-5'] = { alias: 'GPT-5' };
    config.agents.defaults.models['openai/gpt-4.5-preview'] = { alias: 'GPT-4.5' };
    config.agents.defaults.model.primary = 'openai/gpt-5.2';
} else if (baseUrl) {
    console.log('Configuring Anthropic provider with base URL:', baseUrl);
    config.models = config.models || {};
    config.models.providers = config.models.providers || {};
    const providerConfig = {
        baseUrl: baseUrl,
        api: 'anthropic-messages',
        models: [
            { id: 'claude-opus-4-5-20251101', name: 'Claude Opus 4.5', contextWindow: 200000 },
            { id: 'claude-sonnet-4-5-20250929', name: 'Claude Sonnet 4.5', contextWindow: 200000 },
            { id: 'claude-haiku-4-5-20251001', name: 'Claude Haiku 4.5', contextWindow: 200000 },
        ]
    };
    // Include API key in provider config if set (required when using custom baseUrl)
    if (process.env.ANTHROPIC_API_KEY) {
        providerConfig.apiKey = process.env.ANTHROPIC_API_KEY;
    }
    config.models.providers.anthropic = providerConfig;
    // Add models to the allowlist so they appear in /models
    config.agents.defaults.models = config.agents.defaults.models || {};
    config.agents.defaults.models['anthropic/claude-opus-4-5-20251101'] = { alias: 'Opus 4.5' };
    config.agents.defaults.models['anthropic/claude-sonnet-4-5-20250929'] = { alias: 'Sonnet 4.5' };
    config.agents.defaults.models['anthropic/claude-haiku-4-5-20251001'] = { alias: 'Haiku 4.5' };
    config.agents.defaults.model.primary = 'anthropic/claude-opus-4-5-20251101';
} else {
    // Default to Anthropic without custom base URL (uses built-in pi-ai catalog)
    config.agents.defaults.model.primary = 'anthropic/claude-opus-4-5';
}

// Write updated config
fs.writeFileSync(configPath, JSON.stringify(config, null, 2));
console.log('Configuration updated successfully');
console.log('Config (redacted):', JSON.stringify(redactConfigForLogs(config), null, 2));
EOFNODE

# ============================================================
# START GATEWAY
# ============================================================
# Note: R2 backup sync is handled by the Worker's cron trigger
echo "Starting Moltbot Gateway..."
echo "Gateway will be available on port 18789"

# ============================================================
# AUTO-SYNC CONFIG TO R2 ON CHANGE
# ============================================================
is_r2_mounted() {
  mount | grep -q "s3fs on $BACKUP_DIR" 2>/dev/null
}

sync_to_r2() {
  if ! is_r2_mounted; then
    return 0
  fi
  if [ ! -f "$CONFIG_FILE" ]; then
    echo "Config file missing, skip R2 sync"
    return 0
  fi
  mkdir -p "$BACKUP_DIR/clawdbot" "$BACKUP_DIR/skills" "$BACKUP_DIR/clawd"
  if command -v rsync >/dev/null 2>&1; then
    rsync -r --no-times --delete --exclude='*.lock' --exclude='*.log' --exclude='*.tmp' "$CONFIG_DIR/" "$BACKUP_DIR/clawdbot/" || true
    if [ -d /root/clawd/skills ]; then
      rsync -r --no-times --delete /root/clawd/skills/ "$BACKUP_DIR/skills/" || true
    fi
    if [ -d /root/clawd ]; then
      rsync -r --no-times --delete --exclude='.git' --exclude='node_modules' /root/clawd/ "$BACKUP_DIR/clawd/" || true
    fi
  else
    cp -a "$CONFIG_DIR/." "$BACKUP_DIR/clawdbot/" 2>/dev/null || true
    if [ -d /root/clawd/skills ]; then
      cp -a /root/clawd/skills/. "$BACKUP_DIR/skills/" 2>/dev/null || true
    fi
    if [ -d /root/clawd ]; then
      cp -a /root/clawd/. "$BACKUP_DIR/clawd/" 2>/dev/null || true
    fi
  fi
  date -Iseconds > "$BACKUP_DIR/.last-sync" 2>/dev/null || true
}

start_auto_sync() {
  if ! is_r2_mounted; then
    echo "R2 not mounted, auto-sync disabled"
    return 0
  fi
  local interval="${AUTO_SYNC_INTERVAL:-5}"
  (
    local last_mtime=""
    while true; do
      if [ -f "$CONFIG_FILE" ]; then
        local mtime
        mtime=$(stat -c %Y "$CONFIG_FILE" 2>/dev/null || stat -f %m "$CONFIG_FILE" 2>/dev/null || echo "")
        if [ -n "$mtime" ] && [ "$mtime" != "$last_mtime" ]; then
          if [ -n "$last_mtime" ]; then
            echo "Config changed, syncing to R2..."
          fi
          sync_to_r2
          last_mtime="$mtime"
        fi
      fi
      sleep "$interval"
    done
  ) &
}

start_auto_sync

# Clean up stale lock files
rm -f /tmp/clawdbot-gateway.lock 2>/dev/null || true
rm -f "$CONFIG_DIR/gateway.lock" 2>/dev/null || true

BIND_MODE="lan"
echo "Dev mode: ${CLAWDBOT_DEV_MODE:-false}, Bind mode: $BIND_MODE"

if [ -n "$CLAWDBOT_GATEWAY_TOKEN" ]; then
  echo "Starting gateway with token auth..."
  exec "$CLAWDBOT_BIN" gateway --port 18789 --verbose --allow-unconfigured --bind "$BIND_MODE" --token "$CLAWDBOT_GATEWAY_TOKEN"
else
  echo "Starting gateway with device pairing (no token)..."
  exec "$CLAWDBOT_BIN" gateway --port 18789 --verbose --allow-unconfigured --bind "$BIND_MODE"
fi
