# Moodle 5.2 container image

A production-oriented Docker image for **Moodle 5.2** on **PHP 8.3 + Apache**, built for
Kubernetes with PostgreSQL (for example CloudNativePG). Moodle, its Composer
dependencies, the Boost Union theme and your third-party plugins are baked into the image,
so every pod runs identical code.

| | |
|---|---|
| Moodle | 5.2.1 (downloaded from GitHub and verified by SHA256 at build time) |
| PHP | 8.3.36 on `php:8.3.36-apache-bookworm` (Moodle 5.2 supports PHP 8.3 and 8.4) |
| Database | PostgreSQL (`pgsql` driver); MySQL/MariaDB drivers are not installed |
| Web root | `/var/www/html/public` (Moodle 5.1+ layout), router via `FallbackResource /r.php` |
| Not in the image | `config.php`, PHP ini overrides, `moodledata`, secrets |

## Repository layout

```
.
|-- Dockerfile            # 4 stages: moodle source -> php base -> composer -> runtime
|-- entrypoint.sh         # waits for the DB, checks config.php, fixes moodledata perms
|-- install-plugins.sh    # installs the ZIPs from plugins/ (fails the build on any problem)
|-- moodle-apache.conf    # VirtualHost: DocumentRoot public/, router, denies the repo root
|-- plugins/              # put plugin ZIPs here (Marketplace / moodle.org downloads)
|-- LICENSE
`-- README.md
```

## Build

```bash
docker buildx build \
  --build-arg MOODLE_VERSION=5.2.1 \
  --build-arg MOODLE_SHA256=d65fdec343f5cd2fc3b4fdcec33054a91396453afee849bd5b40f1e83222d70f \
  --build-arg BOOST_UNION_VERSION=v5.2-r14 \
  --build-arg BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --build-arg VCS_REF="$(git rev-parse --short HEAD)" \
  -t registry.example.com/moodle:5.2.1-1 \
  --push .
```

| Build arg | Purpose |
|---|---|
| `MOODLE_VERSION` | Moodle release tag to download (`v<version>` on GitHub) |
| `MOODLE_SHA256` | SHA256 of that tarball; the build fails if it does not match |
| `BOOST_UNION_VERSION` | Boost Union release tag, installed into `public/theme/boost_union` |
| `BUILD_DATE`, `VCS_REF` | OCI image labels |

To get the hash for a new Moodle version:

```bash
curl -fsSL https://codeload.github.com/moodle/moodle/tar.gz/refs/tags/v5.2.2 | sha256sum
```

**Use a unique tag for every build** (`5.2.1-1`, `5.2.1-2`, or the git SHA) and use that same tag
for the web pods, the cron container and the install/upgrade Jobs. Re-pushing one tag lets
containers in the same pod end up on different code, which makes Moodle report
"upgrade pending, cron execution suspended".

## Plugins

Moodle 5.1+ keeps every plugin folder under `public/`. Do not install plugins through the
admin UI of a running container: they are written to that one container's filesystem and
disappear on restart, and other replicas never see them.

1. Download each plugin ZIP and put it in `plugins/`.
2. Build. `install-plugins.sh` reads each plugin's `version.php`, derives the folder from
   its component name (for example `mod_board` -> `public/mod/board`) and copies it in.
3. The build **fails** if a ZIP has no `version.php`, no `$plugin->component`, an unsupported
   plugin type, or a `$plugin->requires` newer than the Moodle core in the image.
4. After deploying a new image, run the upgrade step (below) before rolling the web pods.

Supported plugin types: `mod`, `block`, `local`, `tool`, `theme`, `format`, `enrol`,
`availability`, `filter`, `auth`, `report`, `repository`, `qtype`, `qbehaviour`,
`plagiarism`, `booktool`, `quizaccess`, `assignsubmission`, `assignfeedback`, `gradeexport`,
`gradeimport`, `gradereport`. Add others to the `TYPE_PATH` table in `install-plugins.sh`.

Do not put a plugin in `plugins/` that the Dockerfile already installs another way (Boost
Union): the copy would merge old and new files.

To stop admins installing plugins from the UI, add this to `config.php`:

```php
$CFG->disableupdateautodeploy = true;
```

## Runtime configuration

### Environment variables (read by `entrypoint.sh`)

| Variable | Required | Default | Meaning |
|---|---|---|---|
| `DB_HOST` | yes | | PostgreSQL host (for CNPG, the `-rw` service) |
| `DB_PORT` | no | `5432` | |
| `DB_NAME` | yes | | |
| `DB_USER` | yes | | |
| `MOODLE_DB_PASSWORD` | yes | | |
| `MOODLE_DATAROOT` | no | `/var/moodledata` | |
| `SKIP_DB_WAIT` | no | `false` | skip the `pg_isready` wait loop |
| `MOODLE_CRON` | no | `false` | start the system cron daemon in this container |
| `MOODLE_PURGE_CACHES_ON_START` | no | `false` | run `purge_caches.php` before starting |

### Files you mount

| Path in container | Content |
|---|---|
| `/var/www/html/config.php` | Moodle config. Must be at the repo root, **not** in `public/` |
| `/usr/local/etc/php/conf.d/moodle-custom.ini` | PHP overrides (no ini is baked into the image) |
| `/var/moodledata` | Persistent volume (ReadWriteMany if you run more than one replica) |

Minimal `config.php`:

```php
<?php
unset($CFG);
global $CFG;
$CFG = new stdClass();

$CFG->dbtype    = 'pgsql';
$CFG->dblibrary = 'native';
$CFG->dbhost    = getenv('DB_HOST');
$CFG->dbname    = getenv('DB_NAME');
$CFG->dbuser    = getenv('DB_USER');
$CFG->dbpass    = getenv('MOODLE_DB_PASSWORD');
$CFG->prefix    = 'mdl_';
$CFG->dboptions = ['dbport' => (int)(getenv('DB_PORT') ?: 5432)];

$CFG->wwwroot  = 'https://moodle.example.com';
$CFG->sslproxy = true;                  // TLS terminated at the ingress
$CFG->dataroot = '/var/moodledata';

$CFG->routerconfigured = true;          // required: Moodle 5.x router check
$CFG->cronclionly      = true;          // cron runs from the CLI only
$CFG->disableupdateautodeploy = true;   // no plugin installs from the UI

require_once(__DIR__ . '/lib/setup.php');
```

PHP settings worth setting in the ini: `memory_limit`, `upload_max_filesize`, `post_max_size`,
`max_execution_time`, and `max_input_vars` of at least 5000 (a Moodle requirement).

## First install, upgrades and cron

Run these as one-off Jobs or with `docker run` against the same image, config and volume.

```bash
# First install into an empty database. Use install_database.php, NOT install.php:
# install.php aborts when config.php already exists.
php /var/www/html/admin/cli/install_database.php \
  --lang=en --adminuser=admin --adminpass='...' --adminemail=admin@example.com \
  --fullname="My Moodle" --shortname=moodle --agree-license

# After every new image (Moodle version or plugin change), before rolling the web pods:
php /var/www/html/admin/cli/upgrade.php --non-interactive
php /var/www/html/admin/cli/purge_caches.php

# Is an upgrade pending in this container? (exit code 2 = yes)
php /var/www/html/admin/cli/upgrade.php --is-pending

# Cron, as a long-running process
php /var/www/html/admin/cli/cron.php --keep-alive=86400
```

Run only one upgrade at a time, and from the CLI rather than the web UI. Give Jobs more memory
than PHP's `memory_limit`, or the kernel may kill an install halfway through.

## Quick local test

```bash
docker run --rm -p 8080:80 \
  -e DB_HOST=host.docker.internal -e DB_NAME=moodle -e DB_USER=moodle \
  -e MOODLE_DB_PASSWORD=secret \
  -v "$PWD/config.php:/var/www/html/config.php:ro" \
  -v moodledata:/var/moodledata \
  registry.example.com/moodle:5.2.1-1
```

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `relation "mdl_config" does not exist` | The database is empty. Run `install_database.php` |
| "Router not configured" in security checks | Add `$CFG->routerconfigured = true;` to `config.php` |
| "Moodle upgrade pending, cron execution suspended" | The code on disk (core and plugins) differs from what the database recorded. Make every container use the same image tag, run the upgrade, then restart |
| Plugin shows "missing from disk" after a restart | It was installed by hand into a running container. Add its ZIP to `plugins/` and rebuild |
| `relation "mdl_theme_..." already exists` during upgrade | Two upgrades ran at once, or an earlier install was interrupted. Check `mdl_config_plugins` for the plugin's `version` row before dropping any tables |
| 403 or blank page on every URL | `config.php` is in the wrong place, or the VirtualHost `DocumentRoot` is not `/var/www/html/public` |

## Security and maintenance

- No secrets are baked in. Pass the database password through the environment or a Secret.
- Apache denies direct access to the repo root, so `config.php`, `lib/` and `admin/cli` are
  not web-reachable; only `public/` is served.
- Patch PHP promptly: bump the `FROM php:8.3.x-apache-bookworm` tag and rebuild. Rebuild
  periodically to pick up OS security updates.
- Third-party downloads are verified where a hash is available (Moodle core). Plugin ZIPs
  are only as trustworthy as their source, so keep them in version control or a private
  store and review updates.

## License

The build files in this repository (Dockerfile, scripts, configuration, documentation) are
released under the MIT License, see [LICENSE](LICENSE).

An image built from them contains other software under its own licenses: Moodle is
GPL-3.0-or-later, PHP and Apache have their own licenses, and each plugin carries its own
license (Moodle plugins are normally GPL-3.0-or-later). If you distribute a built image,
you must comply with those licenses. Check each plugin you add.
