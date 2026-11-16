# ============================================================
# Stage 1 - Download & verify Moodle source
# ============================================================
FROM curlimages/curl:8.7.1 AS moodle-src

ARG MOODLE_VERSION=5.2.1
ARG MOODLE_BRANCH=stable502
# SHA256 of https://codeload.github.com/moodle/moodle/tar.gz/refs/tags/v5.2.1
ARG MOODLE_SHA256=d65fdec343f5cd2fc3b4fdcec33054a91396453afee849bd5b40f1e83222d70f

WORKDIR /tmp

RUN set -eux; \
    curl -fsSL \
      "https://codeload.github.com/moodle/moodle/tar.gz/refs/tags/v${MOODLE_VERSION}" \
      -o moodle.tar.gz; \
    echo "${MOODLE_SHA256}  moodle.tar.gz" | sha256sum -c -; \
    tar -xzf moodle.tar.gz; \
    mv "moodle-${MOODLE_VERSION}" moodle; \
    rm -rf moodle/.git \
           moodle/.github \
           moodle/.esbuild \
           moodle/phpunit.xml.dist \
           moodle/vendor/bin; \
    echo "Moodle ${MOODLE_VERSION} source verified and extracted."

# ============================================================
# Stage 2 - Shared PHP base (extensions) for composer + runtime
# ============================================================
FROM php:8.3.36-apache-bookworm AS php-base

RUN apt-get update && apt-get install -y --no-install-recommends \
      libpq-dev postgresql-client \
      libpng-dev libjpeg-dev libwebp-dev libfreetype6-dev \
      libicu-dev libxml2-dev libxslt1-dev libzip-dev libldap2-dev \
      ghostscript cron less vim-tiny unzip git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# ctype is already compiled into the official php image, so it is not installed here.
RUN docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp && \
    docker-php-ext-configure zip --with-zip && \
    docker-php-ext-configure ldap && \
    docker-php-ext-install -j"$(nproc)" \
        exif gd intl ldap opcache pgsql soap xsl zip && \
    pecl install redis && \
    docker-php-ext-enable redis && \
    pecl clear-cache

# Fail early if an extension is missing
RUN php -m | tr '[:upper:]' '[:lower:]' > /tmp/mods.txt && \
    for e in ctype curl dom gd iconv intl json mbstring openssl pgsql simplexml sodium xml zip zlib redis "zend opcache"; do \
      grep -qx "$e" /tmp/mods.txt || { echo "MISSING PHP EXTENSION: $e"; exit 1; }; \
    done && rm /tmp/mods.txt

RUN a2enmod rewrite headers dir

# ============================================================
# Stage 3 - Composer production dependencies
# ============================================================
FROM php-base AS composer-deps

COPY --from=composer:2 /usr/bin/composer /usr/bin/composer
COPY --from=moodle-src /tmp/moodle /app

WORKDIR /app

RUN composer install \
      --no-dev \
      --classmap-authoritative \
      --optimize-autoloader \
      --no-interaction \
      --no-progress \
      --prefer-dist

# ============================================================
# Stage 4 - Final runtime image
# ============================================================
FROM php-base

ARG MOODLE_VERSION=5.2.1
ARG BUILD_DATE
ARG VCS_REF

LABEL org.opencontainers.image.title="Moodle LMS" \
      org.opencontainers.image.version="${MOODLE_VERSION}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.description="Moodle ${MOODLE_VERSION} on PHP 8.3 + Apache, CloudNativePG-ready"

ENV MOODLE_VERSION=${MOODLE_VERSION}

# Core codebase in /var/www/html, vendor overlay from Stage 3
COPY --from=moodle-src    --chown=www-data:www-data /tmp/moodle /var/www/html
COPY --from=composer-deps --chown=www-data:www-data /app/vendor /var/www/html/vendor

# -- 1. Boost Union theme. Moodle 5.1+ keeps ALL plugin folders under public/
ARG BOOST_UNION_VERSION=v5.2-r14
RUN set -eux; \
    mkdir -p /var/www/html/public/theme/boost_union; \
    curl -fsSL \
      "https://github.com/moodle-an-hochschulen/moodle-theme_boost_union/archive/refs/tags/${BOOST_UNION_VERSION}.tar.gz" \
      -o /tmp/boost_union.tar.gz; \
    tar -xzf /tmp/boost_union.tar.gz -C /var/www/html/public/theme/boost_union --strip-components=1; \
    test -f /var/www/html/public/theme/boost_union/version.php; \
    chown -R www-data:www-data /var/www/html/public/theme/boost_union; \
    rm -f /tmp/boost_union.tar.gz

# -- 2. Plugin ZIPs from ./plugins (Marketplace / Moodle.org downloads).
#       install-plugins.sh puts each one under /var/www/html/public/<type>/<name>
#       and FAILS the build on any problem (no silent skipping).
COPY plugins* /tmp/plugin_zips/
COPY install-plugins.sh /tmp/install-plugins.sh
RUN bash /tmp/install-plugins.sh /tmp/plugin_zips /var/www/html && \
    rm -rf /tmp/plugin_zips /tmp/install-plugins.sh

# -- Apache: DocumentRoot + Moodle 5.2 router -----------------
ENV APACHE_DOCUMENT_ROOT=/var/www/html/public

RUN sed -ri -e 's!/var/www/html!${APACHE_DOCUMENT_ROOT}!g' \
      /etc/apache2/sites-available/*.conf && \
    sed -ri -e 's!/var/www/!${APACHE_DOCUMENT_ROOT}!g' \
      /etc/apache2/apache2.conf /etc/apache2/conf-available/*.conf

COPY moodle-apache.conf /etc/apache2/sites-available/moodle.conf
RUN a2ensite moodle && \
    a2dissite 000-default

# -- Moodle data directory ------------------------------------
RUN mkdir -p /var/moodledata && chown www-data:www-data /var/moodledata

# -- Cron -----------------------------------------------------
RUN echo '* * * * * www-data /usr/local/bin/php /var/www/html/admin/cli/cron.php >> /proc/1/fd/1 2>&1' \
      > /etc/cron.d/moodle-cron && \
    chmod 0644 /etc/cron.d/moodle-cron

# -- Entrypoint -----------------------------------------------
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

VOLUME ["/var/moodledata"]

EXPOSE 80

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["apache2-foreground"]