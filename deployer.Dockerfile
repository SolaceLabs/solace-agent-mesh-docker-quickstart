# Extends the SAM agent deployer image with Docker CLI
# This allows the deployer to create agent containers via Docker-in-Docker

ARG SAM_DEPLOYER_IMAGE=gcr.io/gcp-maas-prod/sam-agent-deployer
ARG SAM_DEPLOYER_TAG=1.1.3

FROM ${SAM_DEPLOYER_IMAGE}:${SAM_DEPLOYER_TAG}

USER root

RUN apt-get update && \
    apt-get install -y --no-install-recommends docker.io && \
    rm -rf /var/lib/apt/lists/*

USER 999
