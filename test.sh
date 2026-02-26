#!/usr/bin/env bash
set -euo pipefail

# OpenHands Post-Deployment Test
# Validates a running instance with 5 checks.
# Usage: ./test.sh <endpoint> <password>
# Example: ./test.sh https://10.0.0.1 mysecretpw

ENDPOINT="${1:?Usage: $0 <endpoint> <password>}"
PASSWORD="${2:?Usage: $0 <endpoint> <password>}"

_pass=0
_fail=0
_total=0

report() {
    local _status="$1"
    local _name="$2"
    _total=$((_total + 1))
    if [ "${_status}" = "PASS" ]; then
        _pass=$((_pass + 1))
        printf '[PASS] %s\n' "${_name}"
    else
        _fail=$((_fail + 1))
        printf '[FAIL] %s\n' "${_name}"
    fi
}

echo ""
echo "OpenHands Post-Deployment Test"
echo "=============================="
echo "Endpoint: ${ENDPOINT}"
echo ""

# Test 1: HTTPS connectivity
# Caddy should be listening on 443 and return some HTTP response
if curl -sk --max-time 10 -o /dev/null -w '%{http_code}' "${ENDPOINT}/" | grep -qE '(401|200|301)'; then
    report PASS "HTTPS connectivity"
else
    report FAIL "HTTPS connectivity"
fi

# Test 2: Auth rejection (no credentials)
# Caddy basic auth must block unauthenticated requests with 401
_code=$(curl -sk --max-time 10 -o /dev/null -w '%{http_code}' "${ENDPOINT}/")
if [ "${_code}" = "401" ]; then
    report PASS "Auth rejection (no credentials)"
else
    report FAIL "Auth rejection (no credentials) -- got HTTP ${_code}"
fi

# Test 3: Auth acceptance (valid basic auth)
# HTTP basic auth with username "admin" and the configured password
_code=$(curl -sk --max-time 10 -u "admin:${PASSWORD}" -o /dev/null -w '%{http_code}' "${ENDPOINT}/")
if [ "${_code}" = "200" ]; then
    report PASS "Auth acceptance (valid basic auth)"
else
    report FAIL "Auth acceptance (valid basic auth) -- got HTTP ${_code}"
fi

# Test 4: UI loading (OpenHands serves the web UI)
# Authenticated request should return HTML containing "openhands"
if curl -sk --max-time 10 -u "admin:${PASSWORD}" "${ENDPOINT}/" | grep -qi 'openhands'; then
    report PASS "UI loading (OpenHands web interface)"
else
    report FAIL "UI loading (OpenHands web interface)"
fi

# Test 5: Reverse proxy responsiveness (WebSocket-capable path)
# Caddy should handle a WebSocket upgrade attempt without hanging (non-000 status)
_code=$(curl -sk --max-time 10 -u "admin:${PASSWORD}" \
    -H "Upgrade: websocket" -H "Connection: Upgrade" \
    -o /dev/null -w '%{http_code}' "${ENDPOINT}/")
if [ "${_code}" != "000" ]; then
    report PASS "Reverse proxy responsiveness (WebSocket path)"
else
    report FAIL "Reverse proxy responsiveness (WebSocket path)"
fi

# Summary
echo ""
echo "Result: ${_pass}/${_total} tests passed"
if [ "${_fail}" -gt 0 ]; then
    exit 1
fi
