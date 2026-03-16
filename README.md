# OpenHands

[OpenHands](https://github.com/All-Hands-AI/OpenHands) AI coding agent packaged as an OpenNebula appliance. Web-based interface with Docker sandboxes for code execution. Works with any LLM provider.

## Quick Start

1. Import the appliance from the OpenNebula marketplace
2. Create a VM (4+ vCPU, 8+ GB RAM)
3. Wait ~2 min for Docker containers to start
4. Get your password: `ssh root@<vm-ip>` then `cat /etc/one-appliance/config`
5. Open `https://<vm-ip>` in your browser (user: `admin`)
6. Configure your LLM provider in Settings > LLM

## Configuration

All variables are set via OpenNebula context and re-read on every boot.

| Variable | Default | Description |
|----------|---------|-------------|
| `ONEAPP_OH_AUTH_PASSWORD` | (auto-generated) | Basic auth password |
| `ONEAPP_OH_TLS_DOMAIN` | (self-signed) | FQDN for Let's Encrypt |
| `ONEAPP_OH_LLM_API_KEY` | (empty) | LLM provider API key |
| `ONEAPP_OH_LLM_MODEL` | (empty) | Model ID (e.g. `anthropic/claude-sonnet-4-20250514`) |
| `ONEAPP_OH_LLM_BASE_URL` | (empty) | Custom OpenAI-compatible endpoint |

## Architecture

Browser connects via HTTPS to Caddy (port 443), which terminates TLS and enforces basic auth, then proxies to OpenHands (port 3000). OpenHands spawns isolated Docker sandbox containers for code execution, terminal access, and web browsing.

## Troubleshooting

| Problem | Fix |
|---------|-----|
| Certificate warning | Expected with self-signed TLS. Accept it, or set `ONEAPP_OH_TLS_DOMAIN` |
| 401 Unauthorized | Check password: `cat /var/lib/openhands/password` |
| OpenHands not loading | `docker logs openhands` / `systemctl restart openhands` |
| LLM not responding | Verify API key in Settings > LLM |

## License

MIT (OpenHands), Apache 2.0 (Caddy, one-apps).
