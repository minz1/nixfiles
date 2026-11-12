#!/usr/bin/env bash
# Applies the authentik OIDC source, its client secret and the user-scoped runner on every Forgejo start.
# No secret in argv (the svc-exec audit rule ships argv to Loki) and no failure that stops Forgejo.

src=(--name authentik --provider openidConnect --key forgejo
    --auto-discover-url "$OIDC_DISCOVERY_URL"
    --scopes openid --scopes email --scopes profile
    --group-claim-name groups --admin-group forgejo-admins --skip-local-2fa)
id=$(forgejo admin auth list | awk '$2 == "authentik" { print $1 }')
# add/update-oauth fetch discovery and fail (or hang ~60s) if authentik is unreachable; Forgejo itself
# copes, and the unit's 90s start timeout must not be spent here
if [ -z "$id" ]; then
    timeout -k 5 20 forgejo admin auth add-oauth "${src[@]}" || echo "forgejo-bootstrap: auth source not created"
else
    timeout -k 5 20 forgejo admin auth update-oauth --id "$id" "${src[@]}" || echo "forgejo-bootstrap: auth source not updated"
fi

OIDC_SECRET=$(< "$OIDC_SECRET_FILE") psql -v ON_ERROR_STOP=1 -q -d "$FORGEJO_DB" << 'SQL'
\getenv s OIDC_SECRET
UPDATE login_source SET cfg = jsonb_set(cfg::jsonb, '{ClientSecret}', to_jsonb($1::text))::text WHERE name = 'authentik' \bind :s \g
SQL

if forgejo admin user list | awk -v u="$RUNNER_SCOPE" '$2 == u { f = 1 } END { exit !f }'; then
    forgejo forgejo-cli actions register --scope "$RUNNER_SCOPE" --name "$RUNNER_NAME" \
        --keep-labels --secret-file "$RUNNER_SECRET_FILE" || echo "forgejo-bootstrap: runner registration failed"
else
    echo "forgejo-bootstrap: user $RUNNER_SCOPE missing, runner registration skipped"
fi
