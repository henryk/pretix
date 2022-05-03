ARG PYTHON_VERSION=3.9
ARG PRETIX_EXTRA_APT_PACKAGES
ARG PRETIX_EXTRA_PYTHON_PACKAGES
ARG PRETIX_EXTRAS=memcached,mysql

FROM python:${PYTHON_VERSION}-slim-bullseye as base

ARG PRETIX_EXTRA_APT_PACKAGES

# Basic setup used both in the builder and the eventual worker container
# Includes user account and locales
RUN mkdir -p /etc/pretix /data /static && \
    useradd -ms /bin/bash -d /pretix -u 15371 pretixuser && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
            locales \
            ${PRETIX_EXTRA_APT_PACKAGES} && \
    dpkg-reconfigure locales && \
	locale-gen C.UTF-8 && \
	/usr/sbin/update-locale LANG=C.UTF-8 && \
    pip3 install -U \
         pip \
         setuptools \
         wheel && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* ~/.cache/pip


FROM base as base-builder

# Basic build environment, mostly always cached
# Also installs sudo, nginx and supervisor (for use in standalone image)
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
            build-essential \
            libmariadb-dev \
            gettext \
            git \
            sudo  \
            curl \
            libffi-dev \
            libjpeg-dev \
            libmemcached-dev \
            libpq-dev \
            libssl-dev \
            libxml2-dev \
            libxslt1-dev \
            python3-virtualenv \
            python3-dev \
            zlib1g-dev \
            sudo \
            nginx \
            supervisor && \
    mkdir -p /pretix/src /install /etc/supervisord && \
    echo 'pretixuser ALL=(ALL) NOPASSWD:SETENV: /usr/bin/supervisord' >> /etc/sudoers && \
	curl -fsSL https://deb.nodesource.com/setup_15.x | sudo -E bash - && \
    apt-get install -y nodejs && \
    curl -qL https://www.npmjs.com/install.sh | sh && \
    pip3 install -U \
        pip \
        setuptools \
        wheel && \
    rm -rf ~/.cache/pip

FROM base-builder as builder

ARG PRETIX_EXTRAS
ENV LC_ALL=C.UTF-8 \
    DJANGO_SETTINGS_MODULE=production_settings

COPY deployment/docker/production_settings.py /pretix/src/production_settings.py

# To copy only the requirements files needed to install from PIP
# We'll prefix-install to /install, then copy to /usr/local
COPY src/setup.py /pretix/src/setup.py
RUN cd /pretix/src && \
    PRETIX_DOCKER_BUILD=TRUE pip3 install \
        --prefix=/install \
        -e ".[${PRETIX_EXTRAS}]" \
        gunicorn django-extensions ipython && \
    cp -r /install/* /usr/local && \
    rm -rf ~/.cache/pip

COPY src /pretix/src
RUN cd /pretix/src &&  \
    python setup.py install --prefix=/install &&  \
    cp -r /install/* /usr/local &&  \
    rm -rf ~/.cache/pip

# There is now a properly installed pretix with dependencies in /usr/local,
# source in /pretix/src, with a copy in /install that can be deployed independently

FROM base-builder as standalone-install
# This is the previous standalone image
ENV LC_ALL=C.UTF-8 \
    DJANGO_SETTINGS_MODULE=production_settings
COPY deployment/docker/pretix.bash /usr/local/bin/pretix
COPY deployment/docker/supervisord /etc/supervisord
COPY deployment/docker/supervisord.all.conf /etc/supervisord.all.conf
COPY deployment/docker/supervisord.web.conf /etc/supervisord.web.conf
COPY deployment/docker/nginx.conf /etc/nginx/nginx.conf
COPY deployment/docker/nginx-max-body-size.conf /etc/nginx/conf.d/nginx-max-body-size.conf
COPY deployment/docker/production_settings.py /pretix/src/production_settings.py
COPY --from=builder /install /usr/local

COPY src /pretix/src

RUN chmod +x /usr/local/bin/pretix && \
    rm /etc/nginx/sites-enabled/default && \
    cd /pretix/src && \
    rm -f pretix.cfg && \
	mkdir -p data && \
    chown -R pretixuser:pretixuser /pretix /data data && \
	sudo -u pretixuser make production

FROM standalone-install as worker-builder
# We'll copy the compiled assets back to the /install path,
# but remove the intermingled (node) sources
ARG PYTHON_VERSION
ARG PRETIX_EXTRAS
ARG PRETIX_EXTRA_PYTHON_PACKAGES

COPY deployment/docker/production_settings.py /pretix/src/pretix/production_settings.py

RUN cd /pretix/src && \
    pip uninstall -y pretix && \
    PRETIX_DOCKER_BUILD=TRUE pip3 install \
        --prefix=/install \
        ".[${PRETIX_EXTRAS}]" \
        gunicorn django-extensions ipython ${PRETIX_EXTRA_PYTHON_PACKAGES} && \
    cp -r /pretix/src/pretix/static.dist \
          /install/lib/python${PYTHON_VERSION}/site-packages/pretix/ && \
    rm -rf /install/lib/python${PYTHON_VERSION}/site-packages/pretix/static.dist/npm_dir \
           /install/lib/python${PYTHON_VERSION}/site-packages/pretix/static.dist/node_prefix \
           /install/lib/python${PYTHON_VERSION}/site-packages/pretix/static

FROM base as pretix
# This is a clean image that only installs runtime dependencies

# Copy the built dependencies from builder
ENV LC_ALL=C.UTF-8 \
    DJANGO_SETTINGS_MODULE=pretix.production_settings

RUN mkdir -p /data /data/logs && \
    chown -R pretixuser:pretixuser /data

COPY --from=builder /install /usr/local
COPY --from=worker-builder /install /usr/local

USER pretixuser
VOLUME ["/etc/pretix", "/data"]
EXPOSE 8000
ENTRYPOINT ["django-admin"]
CMD ["runserver"]

FROM standalone-install as standalone
USER pretixuser
VOLUME ["/etc/pretix", "/data"]
EXPOSE 80
ENTRYPOINT ["pretix"]
CMD ["all"]
