#!/usr/bin/env bash

# --- DB client detection ---
if command -v mariadb >/dev/null 2>&1; then
  DB_CLIENT="mariadb"
elif command -v mysql >/dev/null 2>&1; then
  DB_CLIENT="mysql"
else
  echo "ERROR: Neither mariadb nor mysql client found in PATH" >&2
  exit 1
fi

MYSQL_OPTS="--batch --raw --silent"


set -euo pipefail

DB_NAME="suspicion_check"
OUT_DIR="/usr/lib/suspcheck/policy/current"
MYSQL_OPTS="--batch --raw --silent"

mkdir -p "$OUT_DIR"

export_json() {
  local file="$1"
  local sql="$2"

  local output
  output="$(
    $DB_CLIENT $MYSQL_OPTS -e "USE $DB_NAME; $sql"
  )"

  # Normalize NULL / empty output
  if [[ -z "$output" || "$output" == "NULL" ]]; then
    output="{}"
  fi

  printf '%s\n' "$output" > "$OUT_DIR/$file"

  # Hard validation
  if ! jq empty "$OUT_DIR/$file" >/dev/null 2>&1; then
    echo "ERROR: Invalid JSON generated for $file" >&2
    echo "=== SQL ==="
    echo "$sql"
    echo "=== Output ==="
    cat "$OUT_DIR/$file"
    exit 1
  fi
}
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

jq -n \
  --arg ts "$now" \
  --arg db "$DB_NAME" \
  --argjson reasoning "$($DB_CLIENT -N -e "SELECT COUNT(*) FROM $DB_NAME.reasoning;")" \
  --argjson countries "$($DB_CLIENT -N -e "SELECT COUNT(*) FROM $DB_NAME.countries;")" \
  --argjson cities "$($DB_CLIENT -N -e "SELECT COUNT(*) FROM $DB_NAME.cities;")" \
  --argjson companies "$($DB_CLIENT -N -e "SELECT COUNT(*) FROM $DB_NAME.companies;")" \
  --argjson semantic "$($DB_CLIENT -N -e "SELECT COUNT(*) FROM $DB_NAME.semantic_tokens;")" \
  --argjson structural "$($DB_CLIENT -N -e "SELECT COUNT(*) FROM $DB_NAME.structural_tokens;")" \
  '{
    exported_at: $ts,
    database: $db,
    tables: {
      reasoning: $reasoning,
      countries: $countries,
      cities: $cities,
      companies: $companies,
      semantic_tokens: $semantic,
      structural_tokens: $structural
    }
  }' > "$OUT_DIR/policy.meta.json"


# Verify DB exists
$DB_CLIENT $MYSQL_OPTS -e "SHOW DATABASES LIKE '$DB_NAME';" \
  | grep -q "$DB_NAME" || {
    echo "Database $DB_NAME not found"
    exit 1
  }


export_json reasoning.json "
SELECT JSON_OBJECTAGG(
  hostility_level,
  JSON_OBJECT('message', message, 'is_default', is_default)
)
FROM reasoning;
"

export_json countries.json "
SELECT JSON_OBJECTAGG(
  c.iso_code,
  JSON_OBJECT(
    'name', c.name,
    'hostility', c.hostility,
    'reasoning', r.message
  )
)
FROM countries c
LEFT JOIN reasoning r ON r.id = c.reasoning_id;
"

export_json cities.json "
SELECT JSON_OBJECTAGG(
  c.iso_code,
  (
    SELECT JSON_ARRAYAGG(
      JSON_OBJECT(
        'name', ci.name,
        'hostility_adjustment', ci.hostility_adjustment
      )
    )
    FROM cities ci WHERE ci.country_id = c.id
  )
)
FROM countries c;
"

export_json companies.json "
SELECT JSON_OBJECTAGG(
  c.iso_code,
  (
    SELECT JSON_ARRAYAGG(
      JSON_OBJECT(
        'name', co.name,
        'hostility_adjustment', co.hostility_adjustment,
        'reasoning', r.message
      )
    )
    FROM companies co
    LEFT JOIN reasoning r ON r.id = co.reasoning_id
    WHERE co.country_id = c.id
  )
)
FROM countries c;
"

export_json semantic_tokens.json "
SELECT JSON_ARRAYAGG(
  JSON_OBJECT(
    'token', s.token,
    'hostility_adjustment', s.hostility_adjustment,
    'company', c.name,
    'reasoning', r.message
  )
)
FROM semantic_tokens s
LEFT JOIN companies c ON c.id = s.company_id
LEFT JOIN reasoning r ON r.id = s.reasoning_id;
"

export_json structural_tokens.json "
SELECT JSON_ARRAYAGG(
  JSON_OBJECT(
    'token', s.token,
    'hostility_adjustment', s.hostility_adjustment,
    'reasoning', r.message
  )
)
FROM structural_tokens s
LEFT JOIN reasoning r ON r.id = s.reasoning_id;
"

echo "Policy export completed successfully."
