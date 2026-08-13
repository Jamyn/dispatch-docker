#!/usr/bin/env bash
set -e

MIN_DOCKER_VERSION='25.0.0'
MIN_COMPOSE_VERSION='2.0.0'
MIN_RAM=2400 # MB

DISPATCH_CONFIG_ENV='./.env'
DISPATCH_EXTRA_REQUIREMENTS='./requirements.txt'

# PLACEHOLDER_SECRET must match the sentinel in .env.example exactly (note the
# spelling), or the generation below silently no-ops and ships that value live.
# DEFAULT_DB_PASSWORD is no longer in .env.example; it is kept so an .env written
# before the password became a placeholder is still treated as uninitialised.
PLACEHOLDER_SECRET='REPLACEWITHSOMETHIINGSECRET'
DEFAULT_DB_PASSWORD='dispatch'

DISPATCH_DB_SAMPLE_DATA_FILE='dispatch-sample-data.dump'
DISPATCH_DB_SAMPLE_DATA_URL="https://raw.githubusercontent.com/Jamyn/dispatch/main/data/${DISPATCH_DB_SAMPLE_DATA_FILE}"

DID_CLEAN_UP=0
# the cleanup function will be the exit point
cleanup () {
  if [ "$DID_CLEAN_UP" -eq 1 ]; then
    return 0;
  fi
  echo "Cleaning up..."
  docker compose stop &> /dev/null
  DID_CLEAN_UP=1
}
trap cleanup ERR INT TERM

echo "Checking minimum requirements..."

DOCKER_VERSION=$(docker version --format '{{.Server.Version}}')
COMPOSE_VERSION=$(docker compose version --short)
RAM_AVAILABLE_IN_DOCKER=$(docker run --rm busybox free -m 2>/dev/null | awk '/Mem/ {print $2}');

# Compare dot-separated strings - function below is inspired by https://stackoverflow.com/a/37939589/808368
function ver () { echo "$@" | awk -F. '{ printf("%d%03d%03d", $1,$2,$3); }'; }

function ensure_file_from_example {
  if [ -f "$1" ]; then
    echo "$1 already exists, skipped creation."
  else
    echo "Creating $1..."
    cp -n $(echo "$1".example) "$1"
  fi
}

# Handle OSX sed
if [[ "$OSTYPE" == "darwin"* ]]; then
    sed_suffix_arg="-i ''"
else
    sed_suffix_arg="-i"
fi

function fill_uninitialised_secret {
    secret_name=$1
    if [ -z ${!secret_name} ] || [ ${!secret_name} == "$PLACEHOLDER_SECRET" ]; then
        echo "Generating ${secret_name}..."
        declare ${secret_name}=$(openssl rand -hex 30)
        sed $sed_suffix_arg "s/^${secret_name}=.*/${secret_name}=${!secret_name}/" $DISPATCH_CONFIG_ENV
        echo "${secret_name} written to $DISPATCH_CONFIG_ENV"
    else
        echo "Leaving existing ${secret_name}..."
    fi
}


if [ $(ver $DOCKER_VERSION) -lt $(ver $MIN_DOCKER_VERSION) ]; then
    echo "FAIL: Expected minimum Docker version to be $MIN_DOCKER_VERSION but found $DOCKER_VERSION"
    exit -1
fi

if [ $(ver $COMPOSE_VERSION) -lt $(ver $MIN_COMPOSE_VERSION) ]; then
    echo "FAIL: Expected minimum Docker Compose version to be $MIN_COMPOSE_VERSION but found $COMPOSE_VERSION"
    exit -1
fi

if [ "$RAM_AVAILABLE_IN_DOCKER" -lt "$MIN_RAM" ]; then
    echo "FAIL: Expected minimum RAM available to Docker to be $MIN_RAM MB but found $RAM_AVAILABLE_IN_DOCKER MB"
    exit -1
fi

echo ""
ensure_file_from_example $DISPATCH_CONFIG_ENV
ensure_file_from_example $DISPATCH_EXTRA_REQUIREMENTS
source $DISPATCH_CONFIG_ENV

# Must run after the .env exists (created above) -- grep against a missing
# file silently resolves this to empty rather than erroring.
COMPOSE_BUILD_ARGS="$(grep -E '^(VITE)' ${DISPATCH_CONFIG_ENV} | while read var ; do printf %b "--build-arg ${var} "; done)"

# Clean up old stuff and ensure nothing is working while we install/update
docker compose down --rmi local --remove-orphans

echo ""
echo "Creating volumes for persistent storage..."
echo "Created $(docker volume create --name=dispatch-postgres)."

echo ""
fill_uninitialised_secret "SECRET_KEY"
fill_uninitialised_secret "DISPATCH_JWT_SECRET"

# Does the volume already hold a Postgres cluster? Neither the encryption key
# nor the database password can be changed safely once it does, so both blocks
# below gate on this. `docker volume create` above leaves a fresh volume empty,
# so the absence of PG_VERSION is a reliable "nothing to lose" signal.
# The `|| true` is load-bearing: on a fresh volume the file is absent and `cat`
# exits non-zero, which under `set -e` would abort the install on the assignment.
# Since postgres 18, the official image stores PG_VERSION under a major-version
# subdirectory (/db/<major>/docker/PG_VERSION) instead of at the volume root,
# so both locations must be checked -- checking only the old path would read as
# "empty volume" against a real 18+ cluster and silently attempt to regenerate
# POSTGRES_PASSWORD/DISPATCH_ENCRYPTION_KEY on every install.sh run.
EXISTING_PG_DATA="$(docker run --rm -v dispatch-postgres:/db busybox sh -c 'cat /db/PG_VERSION 2>/dev/null; cat /db/*/docker/PG_VERSION 2>/dev/null' || true)"

# DISPATCH_ENCRYPTION_KEY encrypts plugin configuration (Slack tokens, OAuth
# client secrets, SMTP credentials) at rest. Unlike the two secrets above it
# cannot be rotated freely: a new key makes every already-stored plugin
# configuration undecryptable.
NEEDS_ENCRYPTION_KEY_ROTATION=0
if [ -z "$EXISTING_PG_DATA" ]; then
    fill_uninitialised_secret "DISPATCH_ENCRYPTION_KEY"
elif [ -z "$DISPATCH_ENCRYPTION_KEY" ] || [ "$DISPATCH_ENCRYPTION_KEY" == "$PLACEHOLDER_SECRET" ]; then
    NEEDS_ENCRYPTION_KEY_ROTATION=1
    echo "WARNING: DISPATCH_ENCRYPTION_KEY is still the shipped placeholder."
    echo "         Any plugin credentials in this database are encrypted with a"
    echo "         publicly-known key. This install already has database data, so"
    echo "         the key is NOT rotated automatically - doing so would make the"
    echo "         existing plugin configuration undecryptable."
else
    echo "Leaving existing DISPATCH_ENCRYPTION_KEY..."
fi

# The database password ships as the placeholder. The postgres image only applies
# POSTGRES_PASSWORD while initializing a data directory, so generating one against
# an existing cluster would leave the server on the old password and break every
# connection -- hence the same volume gate. Both the placeholder and the historic
# "dispatch" default count as unset, or an .env from either era ships as live.
NEEDS_DB_PASSWORD_ROTATION=0
if [ -n "$POSTGRES_PASSWORD" ] &&
   [ "$POSTGRES_PASSWORD" != "$DEFAULT_DB_PASSWORD" ] &&
   [ "$POSTGRES_PASSWORD" != "$PLACEHOLDER_SECRET" ]; then
    echo "Leaving existing POSTGRES_PASSWORD..."
elif [ -z "$EXISTING_PG_DATA" ]; then
    echo "Generating POSTGRES_PASSWORD..."
    db_password=$(openssl rand -hex 24)
    sed $sed_suffix_arg "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=${db_password}/" $DISPATCH_CONFIG_ENV
    # DATABASE_CREDENTIALS is the same credential in user:password form; the
    # application reads it while the postgres image reads the pair above.
    sed $sed_suffix_arg "s/^DATABASE_CREDENTIALS=.*/DATABASE_CREDENTIALS=${POSTGRES_USER}:${db_password}/" $DISPATCH_CONFIG_ENV
    # Keep this shell in sync with what was just written. The database steps
    # further down authenticate with $POSTGRES_PASSWORD, while the container
    # they talk to picks the new value up from .env -- if these drift, the
    # sample-data load fails to authenticate against the cluster it just made.
    POSTGRES_PASSWORD="$db_password"
    DATABASE_CREDENTIALS="${POSTGRES_USER}:${db_password}"
    echo "POSTGRES_PASSWORD and DATABASE_CREDENTIALS written to $DISPATCH_CONFIG_ENV"
else
    NEEDS_DB_PASSWORD_ROTATION=1
    echo "WARNING: POSTGRES_PASSWORD is still the shipped placeholder."
    echo "         This install already has database data, so the password is NOT"
    echo "         rotated automatically - the running cluster would keep the old"
    echo "         one and every connection would fail."
fi

echo ""
echo "Pulling, building, and tagging Docker images..."
echo ""
docker compose pull postgres
docker compose build ${COMPOSE_BUILD_ARGS} --force-rm
echo ""
echo "Docker images pulled and built."

docker compose up -d postgres

# The database steps below connect immediately. Postgres accepts connections
# only after the entrypoint has finished initialising the data directory, and
# on a fresh volume that takes long enough to lose the race -- previously this
# only ever passed because the image pull and build above absorbed the delay.
# Probe from a second container so this tests the same compose-network path the
# commands below use, rather than a socket only reachable inside the server.
echo ""
echo "Waiting for Postgres to accept connections..."
postgres_ready=0
for _ in $(seq 1 30); do
    # `run` attaches stdin, so without -T and </dev/null the probe swallows the
    # input meant for the sample-data prompt below and a piped install dies on
    # that read returning EOF under `set -e`.
    if docker compose run --rm -T postgres pg_isready -h $DATABASE_HOSTNAME -p $DATABASE_PORT -q < /dev/null > /dev/null 2>&1; then
        postgres_ready=1
        break
    fi
    sleep 2
done
if [ "$postgres_ready" -ne 1 ]; then
    echo "FAIL: Postgres did not accept connections within 60 seconds."
    echo "      Inspect it with: docker compose logs postgres"
    exit -1
fi
echo "Postgres is accepting connections."

echo ""
echo "Setting up database..."
# Loading sample data is gated on the answer, not on being interactive. The
# prompt is what cannot run under CI, and gating the load on `[ ! $CI ]` meant
# every runner sets CI=true and no automation ever exercised this path -- which
# is how a sample dump inconsistent with the migration chain survived for years
# (Jamyn/dispatch#90). DISPATCH_LOAD_SAMPLE_DATA=1 answers the prompt ahead of
# time so postgres-install can cover it.
LOAD_SAMPLE_DATA="${DISPATCH_LOAD_SAMPLE_DATA:-}"
if [ -z "$LOAD_SAMPLE_DATA" ] && [ ! $CI ]; then
  read -p "Do you want to load example data (WARNING: this will remove all existing database data) (y/N)?" CONT
  if [ "$CONT" = "y" ]; then
    LOAD_SAMPLE_DATA=1
  fi
fi

if [ -n "$LOAD_SAMPLE_DATA" ] && [ "$LOAD_SAMPLE_DATA" != "0" ]; then
    echo "Downloading example data from Dispatch repository..."
    # -f, or a 404 body is written to the dump file and loaded as if it were data.
    curl -f -# -o "./$DISPATCH_DB_SAMPLE_DATA_FILE" "$DISPATCH_DB_SAMPLE_DATA_URL"
    echo "Dropping database dispatch if it already exists..."
    docker compose run -e "PGPASSWORD=$POSTGRES_PASSWORD" --rm postgres dropdb -h $DATABASE_HOSTNAME -p $DATABASE_PORT -U $POSTGRES_USER $DATABASE_NAME --if-exists
    echo "Creating dispatch database..."
    docker compose run -e "PGPASSWORD=$POSTGRES_PASSWORD" --rm postgres createdb -h $DATABASE_HOSTNAME -p $DATABASE_PORT -U $POSTGRES_USER $DATABASE_NAME
    echo "Loading example data to the database..."
    # ON_ERROR_STOP, or psql exits 0 after failing every statement.
    docker compose run -e "PGPASSWORD=$POSTGRES_PASSWORD" -v "$(pwd)/$DISPATCH_DB_SAMPLE_DATA_FILE:/$DISPATCH_DB_SAMPLE_DATA_FILE:Z" --rm postgres psql -v ON_ERROR_STOP=1 -h $DATABASE_HOSTNAME -p $DATABASE_PORT -U $POSTGRES_USER -d $DATABASE_NAME -f "/$DISPATCH_DB_SAMPLE_DATA_FILE"
    echo "Example data loaded. Navigate to /default/auth/register and create a new user."
fi

# Initialise the schema when, and only when, it is actually missing.
#
# This deliberately sits outside the `[ ! $CI ]` block above. `database upgrade`
# below is an alembic migration run, not a schema creator: against a virgin
# database its migrations fail on the first table they try to alter
# ("relation dispatch_user_organization does not exist"). Because CI runners set
# CI=true, the old placement skipped `database init` there and every non
# interactive fresh install died at the migration step.
#
# Gating on the schema rather than on the prompt also makes the script safe to
# re-run, which it has to be since it is the documented upgrade path. Upstream's
# `database init` is not idempotent: it re-inserts the built-in plugin rows and
# dies on the plugin_slug_key unique constraint against an existing database
# (verified 2026-08-08, identical failure on postgres 14.6 and 18.4, so this is
# upstream application behaviour and not a Postgres version issue).
#
# The check is on the schema rather than on EXISTING_PG_DATA above because a
# populated volume does not imply an initialised Dispatch schema: an earlier run
# can create the cluster and then fail before init. The sample data path leaves
# a fully populated schema behind, so it correctly skips init too.
#
# `-T` plus the redirect keep this off stdin for the same reason as the
# readiness probe above. Any failure here falls through to running init.
DISPATCH_SCHEMA_PRESENT="$(docker compose run -e "PGPASSWORD=$POSTGRES_PASSWORD" --rm -T postgres \
  psql -h $DATABASE_HOSTNAME -p $DATABASE_PORT -U $POSTGRES_USER -d $DATABASE_NAME \
  -tAc "select to_regclass('dispatch_core.alembic_version') is not null" \
  < /dev/null 2>/dev/null | tr -d '[:space:]' || true)"
if [ "$DISPATCH_SCHEMA_PRESENT" = "t" ]; then
  echo "Existing Dispatch database detected, skipping initialization."
else
  echo "Initializing the database"
  # `database init` now asks for interactive confirmation before touching a
  # database (upstream a97c011e): it prompts for the hostname, then the
  # database name, echoing each configured value as the expected answer.
  # Piping those same values back answers both prompts non-interactively;
  # -T is needed here (not the readiness probe's /dev/null pattern) because
  # stdin has to carry real input, not be discarded.
  printf '%s\n%s\n' "$DATABASE_HOSTNAME" "$DATABASE_NAME" | docker compose run --rm -T web database init
fi

echo "Running standard database migrations..."
docker compose run --rm web database upgrade

echo ""
echo "Installing plugins..."
docker compose run --rm web plugins install

cleanup

echo ""
echo "----------------"
echo "You're all done! Run the following command to get Dispatch running:"
echo ""
echo "  docker compose up -d"
echo ""
echo "Once running, access the Dispatch UI at:"
echo ""
echo "  http://localhost:8000/default/auth/register"
echo ""
echo "After registering, run the command below to get owner rights for the user you just registered:"
echo ""
echo "  docker exec -it dispatch-web-1 bash -c 'dispatch user update --role owner --organization name-of-the-organization email-address-of-registered-user'"
echo ""
echo "In case you load the sample data, your organization name is: default"
echo ""
echo "----------------"
echo ""

if [ "$NEEDS_ENCRYPTION_KEY_ROTATION" -eq 1 ]; then
  echo "ACTION REQUIRED: DISPATCH_ENCRYPTION_KEY is the shipped placeholder"
  echo ""
  echo "Plugin credentials stored by this install are encrypted with a key that is"
  echo "public knowledge, which gives them no confidentiality at rest. Rotating it"
  echo "is manual because a new key cannot decrypt existing plugin configuration:"
  echo ""
  echo "  1. Back up the database."
  echo "  2. Set DISPATCH_ENCRYPTION_KEY in $DISPATCH_CONFIG_ENV to a fresh value:"
  echo "       openssl rand -hex 30"
  echo "  3. Restart Dispatch, then re-enter each plugin's configuration in the UI."
  echo "  4. Treat any credential that was stored under the old key as exposed and"
  echo "     rotate it at the provider (Slack, Google, SMTP, PagerDuty, etc.)."
  echo ""
  echo "----------------"
  echo ""
fi

if [ "$NEEDS_DB_PASSWORD_ROTATION" -eq 1 ]; then
  echo "ACTION REQUIRED: the database password is the shipped placeholder"
  echo ""
  echo "The ${POSTGRES_USER} password in $DISPATCH_CONFIG_ENV is a shipped value, not a"
  echo "real secret: the historic default is public knowledge, and the placeholder"
  echo "will not authenticate at all."
  echo "Unlike the encryption key this can be rotated in place, but it has to be"
  echo "changed in the running cluster and in $DISPATCH_CONFIG_ENV together:"
  echo ""
  echo "  1. new=\$(openssl rand -hex 24)"
  echo "  2. docker compose exec postgres \\"
  echo "       psql -U $POSTGRES_USER -c \"ALTER USER $POSTGRES_USER WITH PASSWORD '\$new';\""
  echo "  3. Set both of these in $DISPATCH_CONFIG_ENV to match:"
  echo "       POSTGRES_PASSWORD=\$new"
  echo "       DATABASE_CREDENTIALS=${POSTGRES_USER}:\$new"
  echo "  4. docker compose up -d --force-recreate"
  echo ""
  echo "----------------"
  echo ""
fi
