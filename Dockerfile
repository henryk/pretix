ARG PYTHON_VERSION=3.9

FROM python:${PYTHON_VERSION}-slim-bullseye as base

# Basic setup used both in the builder and the eventual worker container
# Includes user account and locales
RUN mkdir -p /etc/pretix /data && \
    useradd -ms /bin/bash -d /pretix -u 15371 pretixuser && \
    apt-get update && \
    apt-get install -y --no-install-recommends locales && \
    dpkg-reconfigure locales && \
	locale-gen C.UTF-8 && \
	/usr/sbin/update-locale LANG=C.UTF-8 && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*


FROM base as builder

ENV LC_ALL=C.UTF-8 \
    DJANGO_SETTINGS_MODULE=production_settings

# Basic build environment, mostly always cached
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
            zlib1g-dev && \
    mkdir /install && \
	curl -fsSL https://deb.nodesource.com/setup_15.x | sudo -E bash - && \
    apt-get install -y nodejs && \
    curl -qL https://www.npmjs.com/install.sh | sh

# Install pretix and compile static assets
# We'll copy the compiled assets back to the /install path,
# but remove the intermingled (node) sources
ARG PYTHON_VERSION

COPY deployment/docker/production_settings.py /tmp/production_settings.py
COPY deployment/docker/pretix.bash /tmp/pretix
COPY deployment/docker/nginx.conf /tmp/nginx.conf

# To copy only the requirements files needed to install from PIP
COPY src/setup.py /pretix/src/setup.py
RUN pip3 install -U \
        pip \
        setuptools \
        wheel && \
    mkdir -p /pretix/src /socket && \
    cp /tmp/production_settings.py /pretix/src/ && \
    cd /pretix/src && \
    PRETIX_DOCKER_BUILD=TRUE pip3 install \
        ".[memcached,mysql]" \
        --prefix=/install \
        gunicorn django-extensions ipython && \
    cp -r /install/* /usr/local && \
    sed -i -e "s,pretix/src/pretix,usr/local/lib/python${PYTHON_VERSION}/site-packages/pretix," \
           -e "s,var/log/nginx/access.log,dev/stdout," \
           -e "s,var/log/nginx/error.log,dev/stderr," \
           -e "s,tmp/pretix.sock,socket/pretix.sock," \
          /tmp/nginx.conf && \
    sed -i -e "s,tmp/pretix.sock,socket/pretix.sock," \
          /tmp/pretix

COPY src /pretix/src
RUN cd /pretix/src && \
    make npminstall && \
    PRETIX_DOCKER_BUILD=TRUE pip3 install \
        ".[memcached,mysql]" \
        --prefix=/install && \
    cp -r /install/* /usr/local && \
    python -m pretix rebuild && \
    cp -r /usr/local/lib/python${PYTHON_VERSION}/site-packages/pretix/static.dist \
          /install/lib/python${PYTHON_VERSION}/site-packages/pretix/ && \
    rm -rf /install/lib/python${PYTHON_VERSION}/site-packages/pretix/static.dist/npm_dir \
           /install/lib/python${PYTHON_VERSION}/site-packages/pretix/static.dist/node_prefix \
           /install/lib/python${PYTHON_VERSION}/site-packages/pretix/static

FROM base as worker-base

# This is a clean image that only installs runtime dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends nginx && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Copy the modified nginx.conf and pretix command
COPY --from=builder /tmp/nginx.conf /etc/nginx/nginx.conf
COPY deployment/docker/nginx-max-body-size.conf /etc/nginx/conf.d/nginx-max-body-size.conf
COPY --from=builder /tmp/pretix /usr/local/bin/pretix

# Copy the built dependencies from builder
RUN mkdir -p /pretix/src /socket /data && \
    chown pretixuser:pretixuser /socket /data
COPY deployment/docker/production_settings.py /pretix/src/
COPY deployment/docker/install-python-package.sh /usr/local/bin/
COPY --from=builder /install /usr/local

ENV LC_ALL=C.UTF-8 \
    DJANGO_SETTINGS_MODULE=production_settings

# We could derive different images (taskworker, webworker) from worker-base
# But currently we'll just use the same image for everything

FROM worker-base as worker
USER pretixuser
VOLUME ["/etc/pretix", "/data"]
ENTRYPOINT ["/usr/local/bin/pretix"]
CMD ["webworker"]
