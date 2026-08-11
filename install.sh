#!/usr/bin/env bash
set -e

COMPOSE_DOCKER_CLI_BUILD=0

MIN_DOCKER_VERSION='17.05.0'
MIN_COMPOSE_VERSION='1.19.0'
MIN_RAM=2400 # MB

DISPATCH_CONFIG_ENV='./.env'
DISPATCH_EXTRA_REQUIREMENTS='./requirements.txt'

# Sentinel values shipped in .env.example. These must match the placeholders in
# .env.example exactly (note the spelling of the first), or the corresponding
# generation below silently no-ops and leaves the shipped value in place.
PLACEHOLDER_SECRET='REPLACEWITHSOMETHIINGSECRET'
DEFAULT_DB_PASSWORD='dispatch'

COMPOSE_BUILD_ARGS="$(grep -E '^(VITE)' ${DISPATCH_CONFIG_ENV} | while read var ; do printf %b "--build-arg ${var} "; done)"

DISPATCH_DB_SAMPLE_DATA_FILE='dispatch-sample-data.dump'
DISPATCH_DB_SAMPLE_DATA_URL="https://raw.githubusercontent.com/Jamyn/dispatch/latest/data/${DISPATCH_DB_SAMPLE_DATA_FILE}"

DID_CLEAN_UP=0
# the cleanup function will be the exit point
cleanup () {
  if [ "$DID_CLEAN_UP" -eq 1 ]; then
    return 0;
  fi
  echo "Cleaning up..."
  docker-compose stop &> /dev/null
  DID_CLEAN_UP=1
}
trap cleanup ERR INT TERM

echo "Checking minimum requirements..."

DOCKER_VERSION=$(docker version --format '{{.Server.Version}}')
COMPOSE_VERSION=$(docker-compose --version | grep -o "[0-9]\{1,2\}\.[0-9]\{1,2\}\.[0-9]\{1,2\}")
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
    echo "FAIL: Expected minimum docker-compose version to be $MIN_COMPOSE_VERSION but found $COMPOSE_VERSION"
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

# Clean up old stuff and ensure nothing is working while we install/update
docker-compose down --rmi local --remove-orphans

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
EXISTING_PG_DATA="$(docker run --rm -v dispatch-postgres:/db busybox cat /db/PG_VERSION 2>/dev/null || true)"

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

# The database password ships as the well-known default "dispatch". The postgres
# image only applies POSTGRES_PASSWORD while initializing a data directory, so
# generating one against an existing cluster would leave the server on the old
# password and break every connection -- hence the same volume gate.
NEEDS_DB_PASSWORD_ROTATION=0
if [ "$POSTGRES_PASSWORD" != "$DEFAULT_DB_PASSWORD" ]; then
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
    echo "WARNING: POSTGRES_PASSWORD is still the shipped default."
    echo "         This install already has database data, so the password is NOT"
    echo "         rotated automatically - the running cluster would keep the old"
    echo "         one and every connection would fail."
fi

echo ""
echo "Pulling, building, and tagging Docker images..."
echo ""
docker-compose pull postgres
docker-compose build ${COMPOSE_BUILD_ARGS} --force-rm
echo ""
echo "Docker images pulled and built."

docker-compose up -d postgres

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
    if docker-compose run --rm -T postgres pg_isready -h $DATABASE_HOSTNAME -p $DATABASE_PORT -q < /dev/null > /dev/null 2>&1; then
        postgres_ready=1
        break
    fi
    sleep 2
done
if [ "$postgres_ready" -ne 1 ]; then
    echo "FAIL: Postgres did not accept connections within 60 seconds."
    echo "      Inspect it with: docker-compose logs postgres"
    exit -1
fi
echo "Postgres is accepting connections."

echo ""
echo "Setting up database..."
if [ ! $CI ]; then
  read -p "Do you want to load example data (WARNING: this will remove all existing database data) (y/N)?" CONT
  if [ "$CONT" = "y" ]; then
    echo "Downloading example data from Dispatch repository..."
    # -f, or a 404 body is written to the dump file and loaded as if it were data.
    curl -f -# -o "./$DISPATCH_DB_SAMPLE_DATA_FILE" "$DISPATCH_DB_SAMPLE_DATA_URL"
    echo "Dropping database dispatch if it already exists..."
    docker-compose run -e "PGPASSWORD=$POSTGRES_PASSWORD" --rm postgres dropdb -h $DATABASE_HOSTNAME -p $DATABASE_PORT -U $POSTGRES_USER $DATABASE_NAME --if-exists
    echo "Creating dispatch database..."
    docker-compose run -e "PGPASSWORD=$POSTGRES_PASSWORD" --rm postgres createdb -h $DATABASE_HOSTNAME -p $DATABASE_PORT -U $POSTGRES_USER $DATABASE_NAME
    echo "Loading example data to the database..."
    # ON_ERROR_STOP, or psql exits 0 after failing every statement.
    docker compose run -e "PGPASSWORD=$POSTGRES_PASSWORD" -v "$(pwd)/$DISPATCH_DB_SAMPLE_DATA_FILE:/$DISPATCH_DB_SAMPLE_DATA_FILE:Z" --rm postgres psql -v ON_ERROR_STOP=1 -h $DATABASE_HOSTNAME -p $DATABASE_PORT -U $POSTGRES_USER -d $DATABASE_NAME -f "/$DISPATCH_DB_SAMPLE_DATA_FILE"
    echo "Example data loaded. Navigate to /default/auth/register and create a new user."
  else
    echo "Initializing the database"
    docker-compose run --rm web database init
  fi
fi
echo "Running standard database migrations..."
docker-compose run --rm web database upgrade

echo ""
echo "Installing plugins..."
docker-compose run --rm web plugins install

cleanup

echo ""
echo "----------------"
echo "You're all done! Run the following command to get Dispatch running:"
echo ""
echo "  docker-compose up -d"
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
  echo "ACTION REQUIRED: the database password is the shipped default"
  echo ""
  echo "This install authenticates to Postgres as ${POSTGRES_USER}:${DEFAULT_DB_PASSWORD}."
  echo "Unlike the encryption key this can be rotated in place, but it has to be"
  echo "changed in the running cluster and in $DISPATCH_CONFIG_ENV together:"
  echo ""
  echo "  1. new=\$(openssl rand -hex 24)"
  echo "  2. docker-compose exec postgres \\"
  echo "       psql -U $POSTGRES_USER -c \"ALTER USER $POSTGRES_USER WITH PASSWORD '\$new';\""
  echo "  3. Set both of these in $DISPATCH_CONFIG_ENV to match:"
  echo "       POSTGRES_PASSWORD=\$new"
  echo "       DATABASE_CREDENTIALS=${POSTGRES_USER}:\$new"
  echo "  4. docker-compose up -d --force-recreate"
  echo ""
  echo "----------------"
  echo ""
fi
