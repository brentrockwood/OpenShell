# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Developer convenience targets for local builds and cluster hot-deploys.
# Wraps the same logic used by mise tasks so that mise is not required.
#
# Common workflows:
#   make deploy         Build gateway image and hot-deploy it into the running cluster
#   make install-cli    Build and install the openshell CLI to ~/.local/bin
#   make rebuild        Full cycle: install-cli + deploy
#   make help           Show available targets

SHELL := /bin/bash

# ---------------------------------------------------------------------------
# Configuration (override via environment or make flags)
# ---------------------------------------------------------------------------

# Cluster name matches the basename of the working directory, lowercased.
# Override with: make CLUSTER_NAME=my-cluster deploy
CLUSTER_NAME ?= $(shell basename "$(CURDIR)" | tr '[:upper:]' '[:lower:]' | \
                  sed 's/[^a-z0-9-]/-/g' | sed 's/--*/-/g;s/^-//;s/-$$//')

CONTAINER_NAME  = openshell-cluster-$(CLUSTER_NAME)
IMAGE_TAG       ?= dev
IMAGE_REPO_BASE ?= 127.0.0.1:5000/openshell
GATEWAY_IMAGE   = openshell/gateway:$(IMAGE_TAG)
REGISTRY_IMAGE  = $(IMAGE_REPO_BASE)/gateway:$(IMAGE_TAG)
INSTALL_DIR     ?= $(HOME)/.local/bin
CARGO_PROFILE   ?= debug

ifeq ($(CARGO_PROFILE),release)
  CARGO_FLAGS = --release
  CARGO_OUT   = target/release
else
  CARGO_FLAGS =
  CARGO_OUT   = target/debug
endif

# ---------------------------------------------------------------------------
# Phony targets
# ---------------------------------------------------------------------------

.PHONY: help build-cli install-cli build-gateway deploy rebuild

help:
	@echo ""
	@echo "OpenShell developer targets"
	@echo ""
	@echo "  make install-cli      Build openshell CLI and install to $(INSTALL_DIR)"
	@echo "  make build-gateway    Build the gateway Docker image (openshell/gateway:$(IMAGE_TAG))"
	@echo "  make deploy           Build gateway image and hot-deploy into running cluster"
	@echo "  make rebuild          install-cli + deploy"
	@echo ""
	@echo "Options (pass as env vars or make flags):"
	@echo "  CLUSTER_NAME   Name of the running cluster (default: $(CLUSTER_NAME))"
	@echo "  IMAGE_TAG      Docker image tag (default: $(IMAGE_TAG))"
	@echo "  CARGO_PROFILE  debug or release (default: $(CARGO_PROFILE))"
	@echo "  INSTALL_DIR    CLI install destination (default: $(INSTALL_DIR))"
	@echo ""

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

build-cli:
	cargo build $(CARGO_FLAGS) --bin openshell

install-cli: build-cli
	@mkdir -p "$(INSTALL_DIR)"
	install -m 755 "$(CARGO_OUT)/openshell" "$(INSTALL_DIR)/openshell"
	@echo "Installed: $(INSTALL_DIR)/openshell"

# ---------------------------------------------------------------------------
# Gateway image
# ---------------------------------------------------------------------------

build-gateway:
	tasks/scripts/docker-build-image.sh gateway

# ---------------------------------------------------------------------------
# Hot-deploy: push updated gateway image into the running cluster
# ---------------------------------------------------------------------------

deploy: build-gateway
	@echo "Checking for running cluster container: $(CONTAINER_NAME)"
	@docker ps -q --filter "name=^$(CONTAINER_NAME)$$" | grep -q . || \
	  { echo "Error: cluster container '$(CONTAINER_NAME)' is not running."; \
	    echo "Start the gateway first: openshell gateway start"; exit 1; }
	@echo "Tagging and pushing gateway image to local registry..."
	docker tag "$(GATEWAY_IMAGE)" "$(REGISTRY_IMAGE)"
	docker push "$(REGISTRY_IMAGE)"
	@echo "Evicting stale image from cluster containerd cache..."
	docker exec "$(CONTAINER_NAME)" crictl rmi "$(REGISTRY_IMAGE)" 2>/dev/null || true
	@echo "Restarting gateway deployment..."
	docker exec "$(CONTAINER_NAME)" sh -c \
	  "KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl rollout restart statefulset/openshell -n openshell 2>/dev/null || \
	   kubectl rollout restart deployment/openshell -n openshell"
	docker exec "$(CONTAINER_NAME)" sh -c \
	  "KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl rollout status statefulset/openshell -n openshell 2>/dev/null || \
	   kubectl rollout status deployment/openshell -n openshell"
	@echo "Gateway hot-deploy complete."

# ---------------------------------------------------------------------------
# Composite
# ---------------------------------------------------------------------------

rebuild: install-cli deploy
