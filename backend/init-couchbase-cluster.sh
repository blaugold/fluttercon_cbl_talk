#!/usr/bin/env bash

set -e

CONTAINER_NAME=backend-couchbase-server-1
DATABASE_NAME=messages
USERNAME=admin
PASSWORD=password

docker compose down
docker compose up -d couchbase-server

MAX_ATTEMPTS=60
ATTEMPTS=0
until curl http://localhost:8091/pools/default >/dev/null 2>&1; do
  if [ $ATTEMPTS -eq $MAX_ATTEMPTS ]; then
    echo "Couchbase Sever is unavailable after $MAX_ATTEMPTS attempts - exiting"
    exit 1
  fi
  ATTEMPTS=$((ATTEMPTS + 1))
  echo >&2 "Couchbase Server is unavailable - sleeping"
  sleep 1
done

docker exec $CONTAINER_NAME couchbase-cli cluster-init \
  -c 127.0.0.1 \
  --cluster-username "$USERNAME" \
  --cluster-password "$PASSWORD" \
  --services data,query,index \
  --cluster-ramsize 1024

docker exec $CONTAINER_NAME couchbase-cli bucket-create \
  -c 127.0.0.1 \
  --username "$USERNAME" \
  --password "$PASSWORD" \
  --bucket "$DATABASE_NAME" \
  --bucket-type couchbase \
  --bucket-ramsize 256

docker compose up -d sync-gateway

MAX_ATTEMPTS=60
ATTEMPTS=0
until curl http://localhost:4985 >/dev/null 2>&1; do
  if [ $ATTEMPTS -eq $MAX_ATTEMPTS ]; then
    echo "Sync Gateway is unavailable after $MAX_ATTEMPTS attempts - exiting"
    exit 1
  fi
  ATTEMPTS=$((ATTEMPTS + 1))
  echo >&2 "Sync Gateway is unavailable - sleeping"
  sleep 1
done

sleep 5

SYNC_GATEWAY_DATABASE_CONFIG=$(cat << EOF
{
  "bucket": "$DATABASE_NAME",
  "num_index_replicas": 0,
  "guest": {
    "disabled": false,
    "admin_channels": ["*"]
  }
}
EOF
)

curl -X PUT http://localhost:4985/$DATABASE_NAME/ \
  -H "Content-Type: application/json" \
  -d "$SYNC_GATEWAY_DATABASE_CONFIG"