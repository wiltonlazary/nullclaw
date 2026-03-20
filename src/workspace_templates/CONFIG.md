# CONFIG.md - Generated Config Guide

This file explains the main settings that `nullclaw onboard` writes to `config.json`.

## Core Fields

- `workspace`: workspace directory used for local files and bootstrap docs.
- `models.providers.<provider>.api_key`: provider credential. Usually omitted when you rely on an env var.
- `models.providers.<provider>.base_url`: custom endpoint override. Most providers do not need this.
- `agents.defaults.model.primary`: default model route in `provider/model` format.

## Common Defaults

- `default_temperature`: defaults to `0.7` unless you change it manually.
- `agents.defaults.heartbeat.every`: defaults to `30m`.
- `agents.defaults.heartbeat.enabled`: defaults to `true`.
- `memory.backend`: backend selected during onboarding.
- `memory.profile`: derived from the backend choice.
- `memory.auto_save`: backend-specific default chosen by onboarding.
- `tunnel.provider`: one of `none`, `cloudflare`, `ngrok`, `tailscale`.

## Autonomy Settings

Onboarding maps the autonomy choice to these fields:

- `autonomy.level`: `supervised`, `full`, or `yolo`.
- `autonomy.require_approval_for_medium_risk`: `true` for supervised, otherwise `false`.
- `autonomy.block_high_risk_commands`: `true` for supervised/autonomous, `false` for fully autonomous/yolo.

## Channel Configuration

When you configure channels in the wizard, channel-specific credentials and allowlists are written under `channels`.

- credentials stay inside the relevant channel block
- `allow_from` controls who may talk to the agent
- omitted channel blocks mean the channel is not configured

## Practical Notes

- Environment variables still work even when `config.json` omits API keys.
- Unknown keys are usually ignored, but prefer keeping `config.json` minimal and explicit.
- If you change providers manually, keep `agents.defaults.model.primary` aligned with the provider entry you configured.
