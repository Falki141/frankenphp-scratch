#!/usr/bin/env bash
#
# Integration test: Laravel 13 + MariaDB + Redis on the FrankenPHP image.
#
# Usage:  tests/laravel/run.sh [scratch|ubuntu|all]   (default: all)
#
# Environment:
#   SKIP_IMAGE_BUILD=1   use existing frankenphp:test / frankenphp:test-ubuntu
#   KEEP=1               keep the containers running after the test
#   TEST_PORT=18080      host port for HTTP checks
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
VARIANTS="${1:-all}"
[ "$VARIANTS" = all ] && VARIANTS="scratch ubuntu"
export TEST_PORT="${TEST_PORT:-18080}"
BASE_URL="http://localhost:${TEST_PORT}"

PASS=0
FAIL=0
pass() { echo "  ✔ $*"; PASS=$((PASS + 1)); }
fail() { echo "  ✘ $*"; FAIL=$((FAIL + 1)); }
check() { local desc="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi; }
json_true() { grep -q "\"$1\":true" <<<"$2"; }
json_str() { sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p" <<<"$2"; }
json_num() { sed -n "s/.*\"$1\":\([0-9]*\).*/\1/p" <<<"$2"; }

if [ "${SKIP_IMAGE_BUILD:-0}" != 1 ]; then
    echo "==> Building FrankenPHP images"
    docker build -t frankenphp:test "$ROOT"
    docker build --target ubuntu -t frankenphp:test-ubuntu "$ROOT"
fi

for VARIANT in $VARIANTS; do
    case "$VARIANT" in
        scratch) BASE_IMAGE=frankenphp:test ;;
        ubuntu)  BASE_IMAGE=frankenphp:test-ubuntu ;;
        *) echo "unknown variant: $VARIANT" >&2; exit 2 ;;
    esac
    export VARIANT BASE_IMAGE BUILDER_IMAGE=frankenphp:test-ubuntu
    COMPOSE=(docker compose -f "$HERE/compose.yaml" -p "frankenphp-laravel-$VARIANT")
    ARTISAN=("${COMPOSE[@]}" exec -T app /usr/local/bin/frankenphp php-cli artisan)
    PHP=("${COMPOSE[@]}" exec -T app /usr/local/bin/frankenphp php-cli)

    cleanup() {
        if [ "${KEEP:-0}" != 1 ]; then "${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true; fi
    }
    trap cleanup EXIT

    echo
    echo "==> Variant: $VARIANT ($BASE_IMAGE)"
    "${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
    "${COMPOSE[@]}" build app
    "${COMPOSE[@]}" up -d --wait

    echo "--> PHP runtime"
    MODULES="$("${PHP[@]}" smoke-modules.php)"
    for ext in ctype curl dom fileinfo filter hash intl mbstring openssl pcntl pcre \
               pdo pdo_mysql session tokenizer xml redis Zend\ OPcache; do
        check "extension $ext" grep -qix "$ext" <<<"$MODULES"
    done
    LARAVEL_VERSION="$("${ARTISAN[@]}" --version)"
    echo "     $LARAVEL_VERSION"
    check "Laravel major version is 13" grep -q "Laravel Framework 13\." <<<"$LARAVEL_VERSION"

    echo "--> Artisan (CLI)"
    check "artisan migrate (MariaDB)"   "${ARTISAN[@]}" migrate --force
    check "artisan optimize"            "${ARTISAN[@]}" optimize
    check "artisan db:show"             "${ARTISAN[@]}" db:show
    check "artisan smoke:cli (DB + Redis + cache)" "${ARTISAN[@]}" smoke:cli

    echo "--> HTTP (FrankenPHP)"
    for _ in $(seq 1 30); do curl -fs -o /dev/null "$BASE_URL/up" && break; sleep 1; done
    check "GET /up returns 200"  curl -fs -o /dev/null "$BASE_URL/up"
    check "GET / returns 200"    curl -fs -o /dev/null "$BASE_URL/"
    check "response compressed"  bash -c "curl -fs -o /dev/null -D - -H 'Accept-Encoding: zstd, br, gzip' '$BASE_URL/' | grep -qi '^content-encoding:'"

    JAR="$(mktemp)"
    R1="$(curl -fs -c "$JAR" -b "$JAR" "$BASE_URL/smoke" || true)"
    R2="$(curl -fs -c "$JAR" -b "$JAR" "$BASE_URL/smoke" || true)"
    rm -f "$JAR"
    echo "     $R2"
    check "SAPI is frankenphp"       test "$(json_str sapi "$R2")" = frankenphp
    check "PHP is ZTS"               json_true zts "$R2"
    check "DB driver is mariadb"     test "$(json_str db_driver "$R2")" = mariadb
    check "DB server is MariaDB"     grep -qi mariadb <<<"$(json_str db_server "$R2")"
    check "Eloquent create/read/delete" json_true eloquent "$R2"
    check "password hashing"         json_true password_hashed "$R2"
    check "Redis client is phpredis" test "$(json_str redis_client "$R2")" = phpredis
    check "Redis ping"               json_true redis_ping "$R2"
    check "cache store Redis"        json_true cache_redis "$R2"
    check "session driver is redis"  test "$(json_str session_driver "$R2")" = redis
    check "session persists in Redis" test "$(json_num session_counter "$R1"),$(json_num session_counter "$R2")" = "1,2"

    echo "--> Queue (Redis)"
    Q="$(curl -fs "$BASE_URL/smoke/queue" || true)"
    TOKEN="$(json_str token "$Q")"
    check "job dispatched to redis queue" test "$(json_str queue_driver "$Q")" = redis -a "$(json_num queue_size "$Q")" -ge 1
    check "queue:work processes job"      "${ARTISAN[@]}" queue:work --once --stop-when-empty --tries=1
    check "job result visible over HTTP"  test -n "$TOKEN" -a "$(json_str token "$(curl -fs "$BASE_URL/smoke/queue/result")")" = "$TOKEN"
    check "no failed jobs"                "${ARTISAN[@]}" smoke:no-failed-jobs

    echo "--> Logs"
    LOGS="$("${COMPOSE[@]}" logs app 2>&1)"
    check "no PHP fatal errors / exceptions in logs" bash -c "! grep -Eiq 'PHP (Fatal|Warning)|production.ERROR|Uncaught' <<<\"\$0\"" "$LOGS"

    if [ "$FAIL" -gt 0 ]; then
        echo; echo "---- app logs ($VARIANT) ----"; echo "$LOGS" | tail -50
    fi
    cleanup
    trap - EXIT
done

echo
echo "==> $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
