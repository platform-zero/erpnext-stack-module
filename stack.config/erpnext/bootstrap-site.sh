#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '[erpnext-bootstrap] %s\n' "$*" >&2
}

BENCH_DIR="/home/frappe/frappe-bench"
SITE_NAME="${ERPNEXT_SITE_NAME:-erpnext.${DOMAIN}}"
DB_HOST="${DB_HOST:-mariadb}"
DB_PORT="${DB_PORT:-3306}"
DB_ROOT_USERNAME="${MARIADB_ROOT_USERNAME:-root}"
DB_ROOT_PASSWORD="${MARIADB_ROOT_PASSWORD:-${MARIADB_ADMIN_PASSWORD:-}}"
ADMIN_PASSWORD="${ERPNEXT_ADMIN_PASSWORD:-${STACK_ADMIN_PASSWORD:-admin}}"
OAUTH_SECRET="${ERPNEXT_OAUTH_SECRET:-}"

cd "$BENCH_DIR"
mkdir -p /home/frappe/logs
mkdir -p "$BENCH_DIR/$SITE_NAME/logs"

if [ -f "sites/${SITE_NAME}/site_config.json" ]; then
  log "site ${SITE_NAME} already exists"
else
  if [ -d "sites/${SITE_NAME}" ]; then
    log "site directory sites/${SITE_NAME} exists without site_config.json; remove the partial site state before retrying"
    exit 1
  fi
  log "creating ${SITE_NAME}"
  bench new-site \
    --db-host "$DB_HOST" \
    --db-port "$DB_PORT" \
    --db-root-username "$DB_ROOT_USERNAME" \
    --db-root-password "$DB_ROOT_PASSWORD" \
    --admin-password "$ADMIN_PASSWORD" \
    --no-mariadb-socket \
    --install-app erpnext \
    --set-default \
    "$SITE_NAME"
fi

if bench --site "$SITE_NAME" list-apps 2>/dev/null | grep -qx erpnext; then
  log "erpnext is installed on ${SITE_NAME}"
else
  log "installing erpnext on ${SITE_NAME}"
  bench --site "$SITE_NAME" install-app erpnext
fi

log "running site migration"
bench --site "$SITE_NAME" migrate

if [ -n "$OAUTH_SECRET" ]; then
  log "configuring Keycloak social login for ${SITE_NAME}"
  SITE_NAME="$SITE_NAME" "$BENCH_DIR/env/bin/python" <<'PY'
import json
import os

import frappe

site_name = os.environ["SITE_NAME"]
provider = "Keycloak"
domain = os.environ["DOMAIN"]
secret = os.environ["ERPNEXT_OAUTH_SECRET"]

frappe.init(site=site_name, sites_path="sites")
frappe.connect()
try:
    name = (
        frappe.db.exists("Social Login Key", {"provider_name": provider})
        or frappe.db.exists("Social Login Key", provider)
    )
    doc = frappe.get_doc("Social Login Key", name) if name else frappe.new_doc("Social Login Key")

    values = {
        "provider_name": provider,
        "social_login_provider": provider,
        "enable_social_login": 1,
        "custom_base_url": 1,
        "base_url": f"https://keycloak.{domain}/realms/webservices",
        "client_id": "erpnext",
        "client_secret": secret,
        "redirect_url": "/api/method/frappe.integrations.oauth2_logins.login_via_keycloak",
        "authorize_url": "/protocol/openid-connect/auth",
        "access_token_url": "/protocol/openid-connect/token",
        "api_endpoint": "/protocol/openid-connect/userinfo",
        "user_id_property": "preferred_username",
        "auth_url_data": json.dumps({"response_type": "code", "scope": "openid profile email groups"}),
        "sign_ups": "Allow",
    }

    for field, value in values.items():
        if doc.meta.has_field(field):
            doc.set(field, value)

    if doc.is_new():
        doc.insert(ignore_permissions=True)
    else:
        doc.save(ignore_permissions=True, ignore_version=True)

    frappe.db.commit()
finally:
    frappe.destroy()
PY

  log "promoting Keycloak-created users to ERPNext desk users"
  SITE_NAME="$SITE_NAME" "$BENCH_DIR/env/bin/python" <<'PY'
import os

import frappe

site_name = os.environ["SITE_NAME"]
domain = os.environ["DOMAIN"]
allowed_email_suffix = f"@{domain}"
desk_roles = ["Desk User", "Employee", "Projects User"]

frappe.init(site=site_name, sites_path="sites")
frappe.connect()
try:
    users = frappe.get_all(
        "User",
        filters={"enabled": 1},
        fields=["name", "email", "user_type"],
        limit_page_length=0,
    )
    existing_roles = {row.name for row in frappe.get_all("Role", fields=["name"], limit_page_length=0)}
    roles_to_apply = [role for role in desk_roles if role in existing_roles]

    for user_row in users:
        email = (user_row.email or user_row.name or "").strip().lower()
        if user_row.name in {"Administrator", "Guest"} or not email.endswith(allowed_email_suffix):
            continue
        user = frappe.get_doc("User", user_row.name)
        changed = False
        if user.user_type != "System User":
            user.user_type = "System User"
            changed = True
        current_roles = {role.role for role in user.roles}
        for role in roles_to_apply:
            if role not in current_roles:
                user.append("roles", {"role": role})
                changed = True
        if changed:
            user.save(ignore_permissions=True)
    frappe.db.commit()
finally:
    frappe.destroy()
PY
else
  log "ERPNEXT_OAUTH_SECRET is not set; skipping Keycloak social login"
fi

log "ERPNext site ${SITE_NAME} is ready"
