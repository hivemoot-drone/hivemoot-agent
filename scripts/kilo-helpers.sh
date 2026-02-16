#!/usr/bin/env bash
# Shared Kilo helper functions sourced by run-once.sh, run-loop.sh,
# and run-multi.sh. Callers must define a log() function before sourcing.

# Auto-generate Kilo config if missing. Creates minimal valid config with
# permission template and provider-specific auth settings based on KILO_PROVIDER.
# Falls back to gateway mode if KILOCODE_TOKEN is set instead.
generate_kilo_config() {
  local target_home="$1"
  local config_dir="${target_home}/.config/kilo"
  local config_file="${config_dir}/config.json"

  # Skip if config already exists (respect user customization)
  if [ -f "$config_file" ]; then
    return 0
  fi

  # Skip if Kilo provider not in use
  if [ "${AGENT_PROVIDER:-}" != "kilo" ]; then
    return 0
  fi

  mkdir -p "$config_dir"

  # Start with base permission template
  if [ ! -f /opt/hivemoot-agent/scripts/kilo-config-template.json ]; then
    log "Warning: Kilo config template not found; skipping config generation"
    return 0
  fi

  cp /opt/hivemoot-agent/scripts/kilo-config-template.json "$config_file"

  # Gateway mode: no provider config needed (KILOCODE_TOKEN auth)
  if [ -n "${KILOCODE_TOKEN:-}" ]; then
    log "Generated Kilo config for gateway mode: ${config_file}"
    return 0
  fi

  # BYOK mode: add provider-specific config
  local kilo_provider="${KILO_PROVIDER:-}"
  if [ -z "$kilo_provider" ]; then
    log "Warning: KILO_PROVIDER not set; generated base config only"
    return 0
  fi

  # Determine model and provider config based on KILO_PROVIDER
  local model_default=""
  local provider_config=""
  case "$kilo_provider" in
    anthropic)
      model_default="${KILO_MODEL:-claude-sonnet-4-20250514}"
      provider_config='{"anthropic": {"options": {"apiKey": "{env:ANTHROPIC_API_KEY}"}}}'
      ;;
    openai)
      model_default="${KILO_MODEL:-gpt-4}"
      provider_config='{"openai": {"options": {"apiKey": "{env:OPENAI_API_KEY}"}}}'
      ;;
    google)
      model_default="${KILO_MODEL:-gemini-2.0-flash-exp}"
      provider_config='{"google": {"options": {"apiKey": "{env:GOOGLE_API_KEY}"}}}'
      ;;
    openrouter)
      model_default="${KILO_MODEL:-anthropic/claude-sonnet-4-20250514}"
      provider_config='{"openrouter": {"options": {"apiKey": "{env:OPENROUTER_API_KEY}"}}}'
      ;;
    *)
      # Unknown provider — generate base config and let Kilo handle errors
      log "Warning: Unknown KILO_PROVIDER=${kilo_provider}; generated base config only"
      return 0
      ;;
  esac

  # Merge provider config into template using jq
  if ! jq -s --arg model "$model_default" --argjson provider "$provider_config" \
    '.[0] * {"model": $model, "provider": $provider}' \
    "$config_file" > "${config_file}.tmp"; then
    log "Warning: jq merge failed; using base config only"
    rm -f "${config_file}.tmp"
    return 0
  fi

  mv "${config_file}.tmp" "$config_file"
  log "Generated Kilo config for provider=${kilo_provider} model=${model_default}: ${config_file}"
}
