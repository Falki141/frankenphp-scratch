# FrankenPHP on Ubuntu

Docker images of [FrankenPHP](https://frankenphp.dev) on **Ubuntu 26.04** with
PHP (ZTS) compiled from source, almost all bundled PHP extensions and a few
common PIE/PECL extensions. Images are built natively for `linux/amd64` and
`linux/arm64`.

Two variants are built from the same [Dockerfile](Dockerfile):

| Variant | Target | Contents | Runs as |
|---|---|---|---|
| **scratch** (default) | final stage | Minimal root filesystem cut with [Ubuntu Chisel](https://github.com/canonical/chisel): FrankenPHP, PHP and only the libraries it needs. No shell, no package manager. | `www-data` (33:33) |
| **ubuntu** | `--target ubuntu` | Regular Ubuntu image with shell and `apt`, PHP headers and `php-config`. Useful for debugging and for building additional extensions. | `root` |

## Tags

Published on Docker Hub as `falki141/frankenphp-ubuntu`:

| Tag | Meaning |
|---|---|
| `8.6.0`, `8.5.13`, … | Exact PHP version |
| `8.6`, `8.5` | Latest built patch release of that minor version |
| `latest` | Highest PHP version currently built |

The tags contain the **scratch** variant. Images are rebuilt every night, so
they pick up updates of FrankenPHP, Caddy modules and Ubuntu libraries.

## Quick start

```sh
docker run --rm -p 8080:8080 -v "$PWD":/app falki141/frankenphp-ubuntu:8.5
```

The document root is `/app/public`. Without a mounted app, a `phpinfo()` page is
served at <http://localhost:8080>.

Example `Dockerfile` for your own application:

```dockerfile
FROM falki141/frankenphp-ubuntu:8.5
COPY --chown=33:33 . /app
```

### Paths and ports

| Path / port | Purpose |
|---|---|
| `/app` | Application (`/app/public` is the web root) |
| `/etc/frankenphp/Caddyfile` | Caddy/FrankenPHP configuration ([Caddyfile](Caddyfile)) |
| `/usr/local/etc/php/php.ini` | `php.ini` (based on `php.ini-production`) |
| `/usr/local/etc/php/conf.d/` | Additional `.ini` files |
| `/data`, `/config` | Caddy data (certificates) and config (`XDG_DATA_HOME`, `XDG_CONFIG_HOME`) |
| `8080` | HTTP. The scratch image runs unprivileged and cannot bind ports below 1024. |

To serve HTTPS with an automatic certificate, mount your own Caddyfile that
uses your domain instead of `:8080`. The scratch image runs as `www-data` and
can only listen on ports ≥ 1024. For ports 80/443, use the ubuntu variant or
terminate TLS in front of the container.

### Running PHP CLI commands

The scratch image has no `php` binary. FrankenPHP's embedded CLI is used instead:

```sh
docker run --rm -v "$PWD":/app falki141/frankenphp-ubuntu:8.5 php-cli artisan migrate
```

With PHP < 8.6, `frankenphp php-cli` only runs script files: options like
`-m`, `-r` or `-v` are not available. The ubuntu variant also has the regular
`php` binary.

## Included extensions

- **Built in:** bcmath, bz2, calendar, ctype, curl, dom, exif, ffi, fileinfo,
  filter, ftp, gd (freetype, jpeg, webp, avif), gettext, gmp, hash, iconv, intl,
  ldap (SASL), mbstring, mysqli, mysqlnd, OPcache, openssl, pcntl, pdo,
  pdo_mysql, pdo_pgsql, pdo_sqlite, pgsql, posix, readline, session, shmop,
  simplexml, soap, sockets, sodium, sqlite3, sysvmsg, sysvsem, sysvshm, tidy,
  tokenizer, xml, xmlreader, xmlwriter, xsl, zip, zlib
- **Installed with [PIE](https://github.com/php/pie):** apcu, redis
  (build arg `PIE_EXTENSIONS`)
- **FrankenPHP modules:** Mercure, Vulcain, Brotli compression, worker mode
  with file watcher ([Watcher C](https://github.com/e-dant/watcher))

`imagick` is not included on purpose: ImageMagick needs coder modules and
configuration files at runtime that the Chisel slices do not provide.

## Building locally

```sh
# scratch variant (default)
docker build -t frankenphp .

# ubuntu variant
docker build --target ubuntu -t frankenphp:ubuntu .

# a different PHP version
docker build --build-arg PHP_VERSION=8.6.0 -t frankenphp:8.6 .
```

### Build arguments

| Argument | Default | Description |
|---|---|---|
| `PHP_VERSION` | `8.5.13` | Exact PHP version (`x.y.z`), downloaded from `php.net/distributions` |
| `UBUNTU_VERSION` | `26.04` | Ubuntu base image and Chisel release |
| `GO_VERSION` | `1.27.4` | Go toolchain for xcaddy/FrankenPHP (newer toolchains are fetched automatically if required) |
| `PIE_EXTENSIONS` | `apcu/apcu phpredis/phpredis` | Additional extensions as Composer package names, optionally with a constraint, e.g. `phpredis/phpredis:^6.2`. See [packagist.org/extensions](https://packagist.org/extensions). |
| `BASE_SLICES` | see Dockerfile | Chisel slices that are always included (certificates, time zones, glibc, …) |

The runtime libraries are not maintained by hand: after the build, all ELF
files are inspected with `ldd`, and the libraries are mapped to Ubuntu packages.
The ubuntu variant installs those packages with `apt`. The scratch variant cuts
the matching `<package>_libs` Chisel slices. Packages without a slice are
copied from the builder.

### Build stages

```
watcher ─┐
gotools ─┼─► builder ─┬─► ubuntu    (--target ubuntu)
apt+PHP ─┘            └─► rootfs ──► scratch (default)
```

`watcher` (Watcher C) and `gotools` (Go, xcaddy, chisel) do not depend on PHP,
so BuildKit builds them in parallel with the PHP compilation.

## CI pipeline

[.github/workflows/docker-image.yml](.github/workflows/docker-image.yml) runs
on every push to `main`, every night at 03:00 UTC and on demand.

1. **setup** reads the list of PHP versions.
2. **build** builds every PHP version × platform natively on its own runner
   (`ubuntu-latest` for amd64, `ubuntu-24.04-arm` for arm64, no QEMU) and
   pushes the images by digest.
3. **merge** combines the two platform images of each PHP version into a
   multi-arch manifest and sets the tags.

### Updating or adding PHP versions

The versions are defined in a single place in the workflow:

```yaml
env:
  PHP_VERSIONS: "8.5.13 8.6.0"
```

Bump a number to update a version, or add/remove entries to build more or
fewer versions. Each version is tagged as `x.y.z` and `x.y`, and the highest
one is also tagged as `latest`.

To build other versions once, without changing the file, use **Actions →
ci-build → Run workflow** and enter the versions, e.g. `8.5.12`. Versions that
are not in `PHP_VERSIONS` only get their exact `x.y.z` tag, so they never
overwrite `8.5` or `latest`.

If one PHP version fails to build, the other versions are still published.

### Requirements

- Repository secrets `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN`
- The arm64 runners (`ubuntu-24.04-arm`) are free for public repositories.
  Private repositories need a GitHub plan with larger runners.

## Tests

[tests/laravel/run.sh](tests/laravel/run.sh) builds both variants, creates a
fresh Laravel 13 application on top of them and checks it against MariaDB and
Redis. The checks cover extensions, Artisan, HTTP, sessions, cache and queues.

```sh
tests/laravel/run.sh            # both variants
tests/laravel/run.sh scratch    # only the scratch variant
SKIP_IMAGE_BUILD=1 tests/laravel/run.sh   # use existing frankenphp:test images
```
