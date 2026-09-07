# op inject template -- references only, never values. Rendered on the laptop
# (where `op` is already unlocked) and piped over SSH, so no service-account
# token has to exist anywhere on the LAN.
#
#   just secrets herdr
#
# Re-running is the whole rotation procedure.
#
# The token is minted on a machine that HAS a browser:
#
#   claude setup-token          # on the laptop -- prints once, saves nothing
#   op item create --category "Secure Note" --title "claude-code-oauth-token" \
#     --vault Homelab "credential[password]=<the token>"
#
# It lasts a year, and it can only make model requests: no Remote Control
# sessions and no claude.ai connectors. That is why interactive `claude auth
# login` stays the normal way to get a full-featured session on this box, and
# this token is the unattended fallback.
#
# Do NOT add ANTHROPIC_API_KEY here. It outranks both this token and an
# interactive login, silently, and bills a different account.
CLAUDE_CODE_OAUTH_TOKEN=op://Homelab/claude-code-oauth-token/credential
