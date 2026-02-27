# Changelog

All notable changes to the OpenHands appliance will be documented in this file.

## [1.0.0] - 2026-02-27

### Added
- Initial release of the OpenHands marketplace appliance
- OpenHands v1.4.0 AI coding agent with Docker sandbox execution
- Caddy reverse proxy with automatic TLS (self-signed or Let's Encrypt)
- HTTP basic authentication with auto-generated passwords
- Context variables for LLM provider configuration (API key, model, base URL)
- Workspace persistence across reboots at /opt/openhands/workspace
- Automatic Docker cleanup timers
- Pre-built sandbox runtime image for reliable operation
- Idempotent reconfiguration on every boot via one-appliance framework
