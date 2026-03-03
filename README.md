# OpenHands: AI Coding Agent for OpenNebula

[OpenHands](https://github.com/All-Hands-AI/OpenHands) is an open-source AI coding agent that provides a web-based interface for AI-assisted software development, with Docker-based sandboxes for code execution, terminal access, and web browsing. This appliance packages OpenHands as a one-click OpenNebula marketplace image with HTTPS, authentication, and support for any LLM provider.

| | |
|---|---|
| **Agent** | OpenHands 1.4 (open-source AI coding agent) |
| **Execution** | Docker-based sandboxes (code, terminal, browser) |
| **Security** | HTTPS + HTTP basic auth via Caddy reverse proxy |
| **LLM** | Any provider (Claude, GPT, Gemini) or OpenAI-compatible endpoint |
| **License** | MIT (OpenHands), Apache 2.0 (Caddy) |

## Architecture

```
Developer Browser            OpenNebula VM (8+ GB RAM, 4+ vCPU)
+------------------+         +------------------------------------------+
| Web Browser      |  HTTPS  | Caddy (TLS + Basic Auth)          :443  |
|                  |-------->|   |                                      |
+------------------+         |   v                                      |
                             | OpenHands (Web UI + Agent)        :3000  |
                             |   |                                      |
                             |   v                                      |
                             | Docker Sandbox Containers                |
                             | (code execution, terminal, browser)      |
                             +------------------------------------------+
```

Browser connects via HTTPS to Caddy on port 443. Caddy terminates TLS, enforces HTTP basic authentication (username "admin"), and proxies to OpenHands on localhost:3000. OpenHands spawns Docker sandbox containers via the mounted Docker socket for isolated code execution, terminal access, and web browsing.

## Quick Start

### Prerequisites

- OpenNebula 6.10+ with KVM hypervisor
- VM template: 4+ vCPU, 8+ GB RAM, 30+ GB disk
- Network: port 443 open (and port 80 if using Let's Encrypt)

### Example VM template

If importing from the marketplace, the template is created automatically. For manual setup or customization:

```
CPU     = "4"
MEMORY  = "8192"
VCPU    = "4"

CONTEXT = [
    NETWORK                    = "YES",
    SSH_PUBLIC_KEY              = "$USER[SSH_PUBLIC_KEY]",
    ONEAPP_OH_LLM_API_KEY      = "",
    ONEAPP_OH_LLM_MODEL        = "",
    ONEAPP_OH_LLM_BASE_URL     = "",
    ONEAPP_OH_AUTH_PASSWORD     = "",
    ONEAPP_OH_TLS_DOMAIN       = ""
]

DISK = [ IMAGE = "OpenHands" ]
NIC = [ NETWORK = "your-network" ]
NIC_DEFAULT = [ MODEL = "virtio" ]
GRAPHICS = [ LISTEN = "0.0.0.0", TYPE = "VNC" ]
```

Leave `ONEAPP_OH_AUTH_PASSWORD` empty for auto-generation.

### Steps

1. **Import** the appliance from the OpenNebula marketplace (or build from source with `make build`)
2. **Create a VM** from the template, optionally setting the LLM API key and model
3. **Wait for boot** -- service startup takes approximately 2 minutes (Docker container initialization)
4. **Check connection details** by SSHing into the VM:
   ```bash
   cat /etc/one-appliance/config
   ```
5. **Open** `https://<vm-ip>` in your browser, log in with username "admin" and the password from the report file
6. **Validate** the deployment:
   ```bash
   make test ENDPOINT=https://<vm-ip> PASSWORD=<password>
   ```

## Accessing OpenHands

### Same network

If your laptop is on the same network as the VM, open `https://<vm-ip>` directly in your browser.

### Remote access via SSH tunnel

When the VM is behind a private network or firewall, create an SSH tunnel through the hypervisor host:

```bash
ssh -L 8443:<vm-ip>:443 user@hypervisor-host
```

Then open `https://localhost:8443` in your browser. Accept the self-signed certificate warning.

### Port forwarding / NAT

To expose the VM externally, forward a public port to the VM's port 443:

```bash
# On the host/gateway (example using iptables)
iptables -t nat -A PREROUTING -p tcp --dport 9443 -j DNAT --to-destination <vm-ip>:443
iptables -A FORWARD -p tcp -d <vm-ip> --dport 443 -j ACCEPT
```

Then access via `https://<host-public-ip>:9443`.

### Web preview and code editor

The sandbox web preview (ports 8011/8012) and the built-in code editor (VSCode) are proxied through the same HTTPS URL, so they work without additional port forwarding or cross-origin issues.

## Configuration

All configuration is via OpenNebula context variables, set in the VM template. All variables are re-read on every boot -- change a value and reboot to apply.

| Variable | Default | Description |
|----------|---------|-------------|
| `ONEAPP_OH_AUTH_PASSWORD` | *(auto-generated)* | Basic auth password. Auto-generated 16-char alphanumeric if empty |
| `ONEAPP_OH_TLS_DOMAIN` | *(empty)* | FQDN for Let's Encrypt certificate. Self-signed if empty |
| `ONEAPP_OH_LLM_API_KEY` | *(empty)* | LLM provider API key (Anthropic, OpenAI, etc.) |
| `ONEAPP_OH_LLM_MODEL` | *(empty)* | LLM model identifier (e.g. `anthropic/claude-sonnet-4-20250514`) |
| `ONEAPP_OH_LLM_BASE_URL` | *(empty)* | Custom endpoint (OpenAI-compatible) |

## Testing

Validate a running instance:

```bash
make test ENDPOINT=https://<vm-ip> PASSWORD=<password>
```

Runs 5 checks: HTTPS connectivity, auth rejection, auth acceptance, UI loading, and WebSocket reverse proxy responsiveness.

## Troubleshooting

| Problem | Fix |
|---------|-----|
| Browser shows "connection not private" | Self-signed TLS is the default. Accept the warning, or set `ONEAPP_OH_TLS_DOMAIN` for Let's Encrypt |
| 401 Unauthorized | Check password: `cat /var/lib/openhands/password`. Username is always "admin" |
| OpenHands not loading | Check container: `docker logs openhands`. Restart: `systemctl restart openhands` |
| WebSocket disconnects | Check Caddy: `journalctl -u caddy -f`. Caddy config uses `flush_interval -1` and `stream_timeout 0` |
| Let's Encrypt fails | DNS must resolve and port 80 must be reachable. Falls back to self-signed automatically |
| Out of memory | OpenHands + sandboxes need 8+ GB. Check: `free -h`. Consider 16+ GB for heavy use |
| LLM not responding | Verify API key and endpoint. Check: `curl -sk <base_url>/models -H "Authorization: Bearer <key>"` |

### Log locations

| Log | Location |
|-----|----------|
| Application log | `/var/log/one-appliance/openhands.log` |
| OpenHands container | `docker logs openhands -f` |
| Caddy reverse proxy | `journalctl -u caddy -f` |
| Report file | `/etc/one-appliance/config` |

## License

MIT (OpenHands) and Apache 2.0 (Caddy, one-apps).

| Component | License | Maintainer |
|-----------|---------|------------|
| OpenHands | MIT | All Hands AI |
| Caddy | Apache 2.0 | Caddy project |
| OpenNebula one-apps | Apache 2.0 | OpenNebula Systems |

## Author

Pablo del Arco, Cloud-Edge Innovation Engineer at [OpenNebula Systems](https://opennebula.io/).
