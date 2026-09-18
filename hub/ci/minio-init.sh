#!/usr/bin/env bash
# Provision the Nix binary-cache bucket and its dedicated MinIO user, on
# the native minio (ac-host-ci-minio.service). Run by
# ac-host-ci-minio-init.service as `flox activate -d <env> -- bash
# <env>/hub/ci/minio-init.sh` (modules/ci/default.nix), so `mc` is the
# environment's. Idempotent, and it runs at every start of the init unit,
# so what it does with the environment it is handed is what a rotation
# costs (modules/platform/secrets.nix, the ci-env comment).
#
# Adapted from ac-host's compose/minio-init.sh (the container's init, which
# this retires): the endpoint is loopback rather than the compose network's
# `minio` name, mc's flags are the current spelling only (no `mc policy set`
# fallback: the image ran a 2025 mc and so does the lock), and the rest is
# the same script.
set -eu

endpoint="${MINIO_ENDPOINT:-http://127.0.0.1:9000}"
bucket="${S3_CACHE_BUCKET:-flox-binary-cache}"

: "${MINIO_ROOT_USER:?MINIO_ROOT_USER is not set (EnvironmentFile= on the unit is the sops-rendered ci-env)}"
: "${MINIO_ROOT_PASSWORD:?MINIO_ROOT_PASSWORD is not set}"

echo "waiting for minio at ${endpoint}..."
i=0
until mc alias set local "${endpoint}" "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}" >/dev/null 2>&1; do
  i=$((i + 1))
  if [ "${i}" -gt 30 ]; then
    echo "minio did not become ready at ${endpoint}" >&2
    exit 1
  fi
  sleep 2
done

mc mb --ignore-existing "local/${bucket}"

# Anonymous READ on the bucket, so the box itself can substitute what CI
# built: modules/ci lists http://127.0.0.1:9000/${bucket} as a nix
# substituter with the flox-binary-cache-* public keys. Safe to open: minio
# binds 127.0.0.1 only (the stub's --address), every object is a signed
# store path of a public repo, and writes still need the user below.
mc anonymous set download "local/${bucket}"

if [ -n "${S3_CACHE_ACCESS_KEY_ID:-}" ] && [ -n "${S3_CACHE_SECRET_ACCESS_KEY:-}" ]; then
  # No existence guard, on purpose: CreateUser on an existing user rewrites
  # its secret, which is what makes the stored secret follow the rendered
  # file after a rotation (ac-host 141280e learned this the 403 way).
  mc admin user add local "${S3_CACHE_ACCESS_KEY_ID}" "${S3_CACHE_SECRET_ACCESS_KEY}"
  mc admin policy attach local readwrite --user "${S3_CACHE_ACCESS_KEY_ID}" \
    || echo "readwrite policy already attached to ${S3_CACHE_ACCESS_KEY_ID}"
fi

echo "minio cache bucket ${bucket} ready"
