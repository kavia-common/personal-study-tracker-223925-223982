#!/bin/bash

# Minimal PostgreSQL startup script with full paths
# IMPORTANT: This script ONLY starts PostgreSQL. It does NOT start any Node.js apps.
# The optional db_visualizer is for manual/local use and is not part of container startup.

set -euo pipefail

DB_NAME="${DB_NAME:-myapp}"
DB_USER="${DB_USER:-appuser}"
DB_PASSWORD="${DB_PASSWORD:-dbuser123}"
DB_PORT="${DB_PORT:-5001}" # Bind to 5001 per requirement
DB_HOST="${DB_HOST:-0.0.0.0}" # listen on all IPv4; postgres will also bind :: if configured

echo "[startup] Starting PostgreSQL setup..."
echo "[startup] Desired port: ${DB_PORT}, listen address: ${DB_HOST}"

# Find PostgreSQL version and set paths
PG_VERSION=$(ls /usr/lib/postgresql/ | head -1)
PG_BIN="/usr/lib/postgresql/${PG_VERSION}/bin"
PGDATA="/var/lib/postgresql/data"

echo "[startup] Found PostgreSQL version: ${PG_VERSION}"
echo "[startup] Using PGDATA=${PGDATA}"
echo "[startup] Using PGBIN=${PG_BIN}"

# Ensure no conflicting process binds the requested port
if ss -lnt | awk '{print $4}' | grep -E "(:|^).*:${DB_PORT}$" >/dev/null 2>&1; then
  echo "[startup][ERROR] Port ${DB_PORT} already in use by another process:"
  ss -lnt | grep ":${DB_PORT}" || true
  echo "[startup] Exiting to avoid conflict."
  exit 1
fi

# Initialize PostgreSQL data directory if it doesn't exist
if [ ! -f "${PGDATA}/PG_VERSION" ]; then
    echo "[startup] Initializing PostgreSQL data dir..."
    sudo -u postgres "${PG_BIN}/initdb" -D "${PGDATA}"
    # Update postgresql.conf for networking and port
    echo "[startup] Configuring postgresql.conf for port=${DB_PORT} and listen_addresses='*'"
    {
      echo "listen_addresses = '*'"
      echo "port = ${DB_PORT}"
      echo "unix_socket_directories = '/var/run/postgresql'"
    } | sudo tee -a "${PGDATA}/postgresql.conf" >/dev/null
    # Allow local/md5 auth quickly for created role
    HBA="${PGDATA}/pg_hba.conf"
    echo "[startup] Ensuring md5 auth for all hosts in pg_hba.conf"
    # Prepend so it takes effect
    sudo sed -i '1ihost all all 0.0.0.0/0 md5' "${HBA}"
    sudo sed -i '1ihost all all ::/0 md5' "${HBA}"
else
    echo "[startup] Existing data directory found."
    # Make sure config has correct port and listen addresses
    CONF="${PGDATA}/postgresql.conf"
    if ! grep -q "^listen_addresses" "${CONF}" 2>/dev/null; then
      echo "listen_addresses = '*'" | sudo tee -a "${CONF}" >/dev/null
    else
      sudo sed -i "s/^#\?listen_addresses.*/listen_addresses = '*'/g" "${CONF}"
    fi
    if ! grep -q "^port" "${CONF}" 2>/dev/null; then
      echo "port = ${DB_PORT}" | sudo tee -a "${CONF}" >/dev/null
    else
      sudo sed -i "s/^#\?port.*/port = ${DB_PORT}/g" "${CONF}"
    fi
fi

# Double-check no process is holding the port before start
if ss -lnt | awk '{print $4}' | grep -E "(:|^).*:${DB_PORT}$" >/dev/null 2>&1; then
  echo "[startup][ERROR] Port ${DB_PORT} unexpectedly in use. Cannot start Postgres."
  exit 1
fi

# Start PostgreSQL server in background using pg_ctl with explicit -o flags (-p and -h)
echo "[startup] Starting PostgreSQL server with port ${DB_PORT} and listen on all interfaces..."
sudo -u postgres "${PG_BIN}/pg_ctl" -D "${PGDATA}" -l /var/lib/postgresql/server.log \
  -o "-p ${DB_PORT} -h '*'" start

echo "[startup] Waiting for PostgreSQL to become ready on localhost:${DB_PORT} ..."
# Wait for readiness with retries and log output for diagnostics
READY_LOG="/var/lib/postgresql/pg_isready.log"
: > "${READY_LOG}"
for i in $(seq 1 30); do
  if sudo -u postgres "${PG_BIN}/pg_isready" -h 127.0.0.1 -p "${DB_PORT}" | tee -a "${READY_LOG}" | grep -q "accepting connections"; then
    echo "[startup] PostgreSQL is ready (attempt ${i})."
    break
  fi
  echo "[startup] Not ready yet (attempt ${i}); sleeping 1s ..."
  sleep 1
  if [ "$i" -eq 30 ]; then
    echo "[startup][ERROR] PostgreSQL did not become ready in time."
    echo "---- pg_isready log ----"
    cat "${READY_LOG}" || true
    echo "---- server.log tail ----"
    sudo tail -n 200 /var/lib/postgresql/server.log || true
    exit 1
  fi
done

# Create database and user (idempotent)
echo "[startup] Setting up database and user..."
sudo -u postgres "${PG_BIN}/psql" -p "${DB_PORT}" -d postgres << EOF
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${DB_USER}') THEN
        CREATE ROLE ${DB_USER} WITH LOGIN PASSWORD '${DB_PASSWORD}';
    END IF;
    ALTER ROLE ${DB_USER} WITH PASSWORD '${DB_PASSWORD}';
END
\$\$;
EOF

# Create DB if missing
sudo -u postgres "${PG_BIN}/psql" -p "${DB_PORT}" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1 || \
  sudo -u postgres "${PG_BIN}/createdb" -p "${DB_PORT}" "${DB_NAME}"

# Grant privileges and schema permissions
sudo -u postgres "${PG_BIN}/psql" -p "${DB_PORT}" -d "${DB_NAME}" << EOF
GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER};
GRANT USAGE, CREATE ON SCHEMA public TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TYPES TO ${DB_USER};
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO ${DB_USER};
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO ${DB_USER};
EOF

# Save connection command to a file
echo "psql postgresql://${DB_USER}:${DB_PASSWORD}@localhost:${DB_PORT}/${DB_NAME}" > db_connection.txt
echo "[startup] Connection string saved to db_connection.txt"

# Save environment variables to a file for optional db_visualizer (manual usage)
mkdir -p db_visualizer
cat > db_visualizer/postgres.env << EOF
export POSTGRES_URL="postgresql://localhost:${DB_PORT}/${DB_NAME}"
export POSTGRES_USER="${DB_USER}"
export POSTGRES_PASSWORD="${DB_PASSWORD}"
export POSTGRES_DB="${DB_NAME}"
export POSTGRES_PORT="${DB_PORT}"
EOF

echo "[startup] PostgreSQL setup complete!"
echo "[startup] Database: ${DB_NAME}"
echo "[startup] User: ${DB_USER}"
echo "[startup] Port: ${DB_PORT}"
echo ""
echo "[startup] Health check: pg_isready output"
sudo -u postgres "${PG_BIN}/pg_isready" -h 127.0.0.1 -p "${DB_PORT}" | tee -a "${READY_LOG}"

echo ""
echo "To connect to the database, use one of the following commands:"
echo "psql -h localhost -U ${DB_USER} -d ${DB_NAME} -p ${DB_PORT}"
echo "$(cat db_connection.txt)"
