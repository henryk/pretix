#!/usr/bin/env bash
set -ev

BUILD_DEPS="build-essential libmariadb-dev git libffi-dev libjpeg-dev libmemcached-dev libpq-dev libssl-dev libxml2-dev libxslt1-dev python3-dev zlib1g-dev"
RUNTIME_DEPS="gettext"

apt-get update
apt-get install -y --no-install-recommends $BUILD_DEPS $RUNTIME_DEPS
pip install "$@"
apt-get purge -y $BUILD_DEPS
apt-get autoremove -y --purge
apt-get clean
rm -rf /var/lib/apt/lists/*
