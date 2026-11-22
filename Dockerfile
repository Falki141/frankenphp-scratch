# syntax=docker/dockerfile:1
#
# FrankenPHP on Ubuntu 26.04, PHP (ZTS) compiled from source,
# with (almost) all bundled extensions + common PECL extensions.
#
# Stages:
#   watcher  – compiles Watcher C           (runs in parallel with builder)
#   gotools  – Go toolchain, xcaddy, chisel (runs in parallel with builder)
#   builder  – compiles PHP + PIE extensions, then FrankenPHP
#   ubuntu   – classic Ubuntu runtime image (with shell and apt)
#   rootfs   – builds a minimal root filesystem with Ubuntu Chisel
#   (final)  – scratch image containing only that root filesystem
#
# Build (scratch, default):   docker build -t frankenphp .
# Build (Ubuntu variant):     docker build --target ubuntu -t frankenphp:ubuntu .
#
# Run (scratch):  docker run -p 8080:8080 -v "$PWD":/app frankenphp
# Run (ubuntu):   docker run -p 80:80 -p 443:443 -v "$PWD":/app frankenphp:ubuntu

ARG UBUNTU_VERSION=26.04
# Go version: GOTOOLCHAIN=auto automatically downloads a newer toolchain
# if FrankenPHP or Chisel requires a higher version.
ARG GO_VERSION=1.27.4

###############################################################################
# Stage: Watcher C (optional, restarts workers on file changes)
# Independent of PHP, so BuildKit builds it in parallel with the builder.
###############################################################################
FROM ubuntu:${UBUNTU_VERSION} AS watcher

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential cmake git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Installed with DESTDIR so the result (prefix /usr/local) can be copied
# into the builder as a whole.
RUN git clone --depth 1 https://github.com/e-dant/watcher.git /usr/local/src/watcher \
    && cd /usr/local/src/watcher \
    && cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DBUILD_BIN=OFF \
    && cmake --build build -j"$(nproc)" \
    && DESTDIR=/out cmake --install build

###############################################################################
# Stage: Go toolchain + xcaddy + chisel
# Also independent of PHP and built in parallel with the builder.
###############################################################################
FROM golang:${GO_VERSION} AS gotools

# Static binaries (no dependency on the Debian glibc of the golang image)
ENV GOTOOLCHAIN=auto \
    CGO_ENABLED=0
RUN go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest \
    && go install github.com/canonical/chisel/cmd/chisel@latest

###############################################################################
# Stage: Builder
###############################################################################
FROM ubuntu:${UBUNTU_VERSION} AS builder

ARG PHP_VERSION=8.5.13
# Extensions installed with PIE (Composer package name, optionally with a
# version constraint, e.g. "phpredis/phpredis:^6.2").
# List of all PIE-compatible extensions: https://packagist.org/extensions
# imagick is deliberately not included: ImageMagick needs coder modules and
# configuration files at runtime that the Chisel slices do not provide. For the
# Ubuntu variant you can add "imagick/imagick" and install libmagickwand-dev.
ARG PIE_EXTENSIONS="apcu/apcu phpredis/phpredis"

ENV DEBIAN_FRONTEND=noninteractive

# --- Build dependencies -------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential autoconf automake libtool m4 bison re2c pkg-config \
        cmake git unzip curl \
        ca-certificates xz-utils dpkg-dev file \
        libxml2-dev libsqlite3-dev libssl-dev zlib1g-dev libcurl4-openssl-dev \
        libonig-dev libzip-dev libpng-dev libjpeg-dev libwebp-dev \
        libfreetype-dev libavif-dev libicu-dev libxslt1-dev libsodium-dev \
        libargon2-dev libgmp-dev libbz2-dev libreadline-dev libpq-dev \
        libldap-dev libsasl2-dev libtidy-dev libffi-dev libzstd-dev \
        libbrotli-dev \
    && rm -rf /var/lib/apt/lists/*

# --- PHP from source (ZTS + embed, as required by FrankenPHP) ----------------
WORKDIR /usr/local/src
RUN curl -fsSL "https://www.php.net/distributions/php-${PHP_VERSION}.tar.xz" \
        | tar xJ \
    && cd "php-${PHP_VERSION}" \
    && MULTIARCH="$(dpkg-architecture -qDEB_HOST_MULTIARCH)" \
    && ./configure \
        --prefix=/usr/local \
        --with-config-file-path=/usr/local/etc/php \
        --with-config-file-scan-dir=/usr/local/etc/php/conf.d \
        --with-libdir="lib/${MULTIARCH}" \
        # Required flags for FrankenPHP
        --enable-embed \
        --enable-zts \
        --disable-zend-signals \
        --enable-zend-max-execution-timers \
        # SAPIs that are not needed
        --disable-cgi \
        --disable-phpdbg \
        # Extensions (OPcache is built in since PHP 8.5, no flag needed)
        --enable-bcmath \
        --enable-calendar \
        --enable-exif \
        --enable-ftp \
        --enable-gd --with-freetype --with-jpeg --with-webp --with-avif \
        --enable-intl \
        --enable-mbstring \
        --enable-pcntl \
        --enable-shmop \
        --enable-soap \
        --enable-sockets \
        --enable-sysvmsg --enable-sysvsem --enable-sysvshm \
        --with-bz2 \
        --with-curl \
        --with-ffi \
        --with-gettext \
        --with-gmp \
        --with-ldap --with-ldap-sasl \
        --with-mysqli=mysqlnd --with-pdo-mysql=mysqlnd \
        --with-pgsql --with-pdo-pgsql \
        --with-sqlite3 --with-pdo-sqlite \
        --with-openssl \
        --with-password-argon2 \
        --with-readline \
        --with-sodium \
        --with-tidy \
        --with-xsl \
        --with-zip \
        --with-zlib \
    && make -j"$(nproc)" \
    && make install \
    && mkdir -p /usr/local/etc/php/conf.d \
    && cp php.ini-production /usr/local/etc/php/php.ini

# --- Additional extensions with PIE (successor to PECL) ----------------------
# pie.phar is bind-mounted from the official image ghcr.io/php/pie:bin and
# therefore does not end up in the image. PIE runs with the freshly built PHP
# (/usr/local/bin/php), builds the extensions with phpize/php-config and creates
# the matching .ini file in the scan directory /usr/local/etc/php/conf.d.
# Build tools and libraries are already installed above, so PIE's interactive
# checks are skipped.
RUN --mount=type=bind,from=ghcr.io/php/pie:bin,source=/pie,target=/usr/local/bin/pie \
    set -eux; \
    pie install --no-cache \
        --no-build-tools-check \
        --no-system-dependencies-check \
        ${PIE_EXTENSIONS}; \
    pie show; \
    php -m

# --- Watcher C and Go toolchain from the parallel stages ---------------------
COPY --from=watcher /out/usr/local/ /usr/local/
RUN ldconfig
COPY --from=gotools /usr/local/go/ /usr/local/go/
COPY --from=gotools /go/bin/xcaddy /root/go/bin/xcaddy
ENV PATH="/usr/local/go/bin:/root/go/bin:${PATH}" \
    GOTOOLCHAIN=auto

# --- Build FrankenPHP --------------------------------------------------------
WORKDIR /build
RUN CGO_ENABLED=1 \
    XCADDY_GO_BUILD_FLAGS="-ldflags='-w -s' -tags=nobadger,nomysql,nopgx,deprecated_topic,deprecated_claim" \
    CGO_CFLAGS="$(php-config --includes)" \
    CGO_LDFLAGS="$(php-config --ldflags) $(php-config --libs)" \
    xcaddy build \
        --output /usr/local/bin/frankenphp \
        --with github.com/dunglas/frankenphp/caddy \
        --with github.com/dunglas/mercure/caddy \
        --with github.com/dunglas/vulcain/caddy \
        --with github.com/dunglas/caddy-cbrotli

# --- Detect runtime packages automatically -----------------------------------
# Instead of maintaining package names (libicu78, libssl3t64, …) by hand, all
# ELF files under /usr/local are inspected with ldd and the required libraries
# are mapped to their Ubuntu packages via dpkg -S. The list is shared by the
# Ubuntu stage (apt) and the Chisel stage (slices).
RUN set -eu; \
    find /usr/local/bin /usr/local/lib -type f \
        -exec sh -c 'file -b "$1" | grep -q "^ELF" && ldd "$1" || true' _ {} \; \
    | awk '$2 == "=>" && $3 ~ /^\// && $3 !~ /^\/usr\/local\// { print $3 }' \
    | sort -u \
    | while read -r lib; do \
        real="$(readlink -f "$lib")"; \
        dpkg -S "$real" 2>/dev/null \
          || dpkg -S "${real#/usr}" 2>/dev/null \
          || echo "WARNING: not mapped to any package: $real" >&2; \
      done \
    | cut -d: -f1 | sort -u > /runtime-packages.txt; \
    echo "Required runtime packages:"; cat /runtime-packages.txt

###############################################################################
# Stage: Ubuntu runtime (with shell and apt, e.g. for debugging)
###############################################################################
FROM ubuntu:${UBUNTU_VERSION} AS ubuntu

ENV DEBIAN_FRONTEND=noninteractive

COPY --from=builder /runtime-packages.txt /tmp/runtime-packages.txt
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates media-types tzdata \
        $(cat /tmp/runtime-packages.txt) \
    && rm -rf /var/lib/apt/lists/* /tmp/runtime-packages.txt

# Copy PHP (headers, libs, extensions, php.ini), Watcher and FrankenPHP
COPY --from=builder /usr/local/bin/ /usr/local/bin/
COPY --from=builder /usr/local/lib/ /usr/local/lib/
COPY --from=builder /usr/local/etc/php/ /usr/local/etc/php/
COPY --from=builder /usr/local/include/ /usr/local/include/
RUN ldconfig

# Verify: no missing libraries, extensions load
RUN ! ldd /usr/local/bin/frankenphp | grep "not found" \
    && ! find /usr/local/lib/php/extensions -name '*.so' -exec ldd {} \; | grep "not found" \
    && php -m \
    # "frankenphp php-cli" only accepts script files with PHP < 8.6 (no -m/-r/-v)
    && echo '<?php echo PHP_SAPI, " ", PHP_VERSION, PHP_EOL;' > /tmp/check.php \
    && frankenphp php-cli /tmp/check.php \
    && rm /tmp/check.php

ENV XDG_CONFIG_HOME=/config \
    XDG_DATA_HOME=/data
RUN mkdir -p /app/public /config /data /etc/frankenphp \
    && echo '<?php phpinfo();' > /app/public/index.php

COPY Caddyfile /etc/frankenphp/Caddyfile

WORKDIR /app
EXPOSE 80 443 443/udp

CMD ["frankenphp", "run", "--config", "/etc/frankenphp/Caddyfile"]

###############################################################################
# Stage: Minimal root filesystem with Ubuntu Chisel
###############################################################################
FROM builder AS rootfs

ARG UBUNTU_VERSION
ARG CHISEL_RELEASE=ubuntu-${UBUNTU_VERSION}
# Base slices that are not found via ldd (TLS certificates, MIME types,
# time zones, glibc). Slices that do not exist are skipped.
ARG BASE_SLICES="base-files_base base-files_release-info ca-certificates_data media-types_data tzdata_zoneinfo libc6_libs libc6_config"

# Chisel comes prebuilt from the gotools stage
COPY --from=gotools /go/bin/chisel /root/go/bin/chisel

# 1) Cut slices: for each runtime package the "<package>_libs" slice is used.
#    If no slice exists (yet), the package's .so files are copied directly
#    from the builder.
RUN set -eu; \
    mkdir -p /rootfs; \
    slices=""; noslice=""; \
    for s in ${BASE_SLICES}; do \
        if chisel info --release "${CHISEL_RELEASE}" "$s" >/dev/null 2>&1; then \
            slices="$slices $s"; \
        else \
            echo "Note: slice $s does not exist in ${CHISEL_RELEASE} – skipped"; \
        fi; \
    done; \
    for pkg in $(cat /runtime-packages.txt); do \
        if chisel info --release "${CHISEL_RELEASE}" "${pkg}_libs" >/dev/null 2>&1; then \
            slices="$slices ${pkg}_libs"; \
        else \
            noslice="$noslice $pkg"; \
        fi; \
    done; \
    echo "Chisel slices:$slices"; \
    chisel cut --release "${CHISEL_RELEASE}" --root /rootfs $slices; \
    for pkg in $noslice; do \
        echo "No slice for $pkg – copying libraries from the builder"; \
        dpkg -L "$pkg" | grep -E '\.so(\.[0-9]+)*$' | while read -r f; do \
            [ -e "$f" ] && cp -a --parents "$f" /rootfs; \
        done; \
    done

# 2) Copy FrankenPHP, libphp, extensions and php.ini,
#    create linker cache, users and directories
COPY Caddyfile /rootfs/etc/frankenphp/Caddyfile
RUN set -eux; \
    MULTIARCH="$(dpkg-architecture -qDEB_HOST_MULTIARCH)"; \
    mkdir -p /rootfs/usr/local/bin /rootfs/usr/local/etc /rootfs/etc/ld.so.conf.d; \
    cp -a /usr/local/bin/frankenphp /rootfs/usr/local/bin/; \
    cp -a /usr/local/lib /rootfs/usr/local/; \
    cp -a /usr/local/etc/php /rootfs/usr/local/etc/; \
    # Linker cache for /usr/local/lib and the multiarch libraries
    [ -f /rootfs/etc/ld.so.conf ] || echo 'include /etc/ld.so.conf.d/*.conf' > /rootfs/etc/ld.so.conf; \
    printf '/usr/local/lib\n/usr/lib/%s\n' "$MULTIARCH" > /rootfs/etc/ld.so.conf.d/frankenphp.conf; \
    ldconfig -r /rootfs; \
    # Unprivileged user (UID/GID 65532, as in distroless)
    echo 'root:x:0:0:root:/root:/usr/sbin/nologin' >  /rootfs/etc/passwd; \
    echo 'nonroot:x:65532:65532:nonroot:/home/nonroot:/usr/sbin/nologin' >> /rootfs/etc/passwd; \
    echo 'root:x:0:' > /rootfs/etc/group; \
    echo 'nonroot:x:65532:' >> /rootfs/etc/group; \
    # Directories for the app, Caddy data/config and PHP temp files
    mkdir -p /rootfs/tmp /rootfs/app/public /rootfs/config /rootfs/data /rootfs/home/nonroot; \
    chmod 1777 /rootfs/tmp; \
    echo '<?php phpinfo();' > /rootfs/app/public/index.php; \
    chown -R 65532:65532 /rootfs/app /rootfs/config /rootfs/data /rootfs/home/nonroot;
    # Test: does FrankenPHP run in the minimal root filesystem and load all extensions?
    #chroot /rootfs /usr/local/bin/frankenphp php-cli -m

###############################################################################
# Stage: scratch image (default target)
###############################################################################
FROM scratch

COPY --from=rootfs /rootfs/ /

ENV PATH=/usr/local/bin \
    XDG_CONFIG_HOME=/config \
    XDG_DATA_HOME=/data \
    # Ports < 1024 are not allowed for non-root users
    SERVER_NAME=:8080

USER 65532:65532
WORKDIR /app
EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/frankenphp"]
CMD ["run", "--config", "/etc/frankenphp/Caddyfile"]