# syntax=docker/dockerfile:1
#
# Test image: a fresh Laravel 13 application on top of the FrankenPHP image
# that is being tested.
#
#   BUILDER_IMAGE – image with a shell, used to run Composer (Ubuntu variant).
#                   Composer runs with the PHP from the image under test, so the
#                   platform check validates the real extension set.
#   BASE_IMAGE    – image under test (scratch or Ubuntu variant).

ARG BUILDER_IMAGE=frankenphp:test-ubuntu
ARG BASE_IMAGE=frankenphp:test
ARG LARAVEL_VERSION=^13.0

FROM ${BUILDER_IMAGE} AS app
ARG LARAVEL_VERSION
ENV COMPOSER_ALLOW_SUPERUSER=1
COPY --from=composer:2 /usr/bin/composer /usr/local/bin/composer
WORKDIR /src
RUN composer create-project --no-interaction --prefer-dist --no-dev \
        "laravel/laravel:${LARAVEL_VERSION}" app \
    && rm -f app/database/database.sqlite
COPY overlay/ /src/app/

FROM ${BASE_IMAGE}
COPY --from=app --chown=65532:65532 /src/app /app
