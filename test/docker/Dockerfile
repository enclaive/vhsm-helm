# Copyright (c) HashiCorp, Inc.
# SPDX-License-Identifier: MPL-2.0

# This Dockerfile installs all the dependencies necessary to run the unit and
# acceptance tests. This image also contains gcloud so you can run tests
# against a GKE cluster easily.
#
# This image has no automatic entrypoint. It is expected that you'll run
# a script to configure kubectl, potentially install Helm, and run the tests
# manually. This image only has the dependencies pre-installed.

FROM harbor.enclaive.cloud/mirror/alpine:latest
WORKDIR /root

ENV BATS_VERSION "1.3.0"

# base packages
RUN apk update && apk add --no-cache --virtual .build-deps \
    ca-certificates \
    curl \
    tar \
    bash \
    openssl \
    git \
    make \
    jq \
    py-pip

# yq
RUN python3 -m venv venv && \
    . venv/bin/activate && \
    pip install yq && \
    ln -s $PWD/venv/bin/yq /usr/local/bin/yq && \
    deactivate

# helm
RUN curl https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | bash

# bats
RUN curl -sSL https://github.com/bats-core/bats-core/archive/v${BATS_VERSION}.tar.gz -o /tmp/bats.tgz \
    && tar -zxf /tmp/bats.tgz -C /tmp \
    && /bin/bash /tmp/bats-core-$BATS_VERSION/install.sh /usr/local
