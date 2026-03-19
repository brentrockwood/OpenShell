# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Developer convenience targets for local builds and E2E deployment.
# Wraps the same logic used by mise tasks so that mise is not required.
#
# Typical E2E workflow (run in order):
#   make clean      Destroy gateway container and all build artifacts
#   make build      Compile openshell CLI + build gateway Docker image
#   make deploy     Start fresh gateway with local image + run nemoclaw onboard
#
# Iterating after initial build (image already built):
#   make deploy     Tear down old gateway, redeploy, re-onboard
#
# Other targets:
#   make install-cli    Build and install the openshell CLI only
#   make build-gateway  Build the gateway Docker image only
#   make hot-swap       Push local image into already-running cluster
#   make onboard        Run nemoclaw onboard against running cluster
#   make help           Show all targets

SHELL := /bin/bash

# ---------------------------------------------------------------------------
# Configuration (override via environment or make flags)
# ---------------------------------------------------------------------------

# Gateway / cluster identity
GATEWAY_NAME    ?= nemoclaw
CONTAINER_NAME   = openshell-cluster-$(GATEWAY_NAME)

# Local Docker registry. The host pushes to REGISTRY_LOCAL_HOST:5000.
# k3s inside the container pulls from REGISTRY_DOCKER_HOST:5000 — on macOS
# with Docker Desktop this is host.docker.internal. On Linux, override to
# the host's bridge IP (e.g. 172.17.0.1) if host.docker.internal is absent.
REGISTRY_LOCAL_HOST  ?= 127.0.0.1
REGISTRY_DOCKER_HOST ?= host.docker.internal
REGISTRY_PORT        ?= 5000
REGISTRY_CONTAINER   ?= openshell-local-registry

REGISTRY_LOCAL   = $(REGISTRY_LOCAL_HOST):$(REGISTRY_PORT)
REGISTRY_DOCKER  = $(REGISTRY_DOCKER_HOST):$(REGISTRY_PORT)

# Image names.
# REGISTRY_IMAGE and DOCKER_IMAGE refer to the same physical image in the same
# registry server, just from two different network viewpoints:
#   REGISTRY_IMAGE  -- used by `docker push` on the host (127.0.0.1:5000)
#   DOCKER_IMAGE    -- used by k3s inside the cluster container (host.docker.internal:5000)
# Pushing to REGISTRY_IMAGE makes the image pullable as DOCKER_IMAGE because
# both hostnames resolve to the same registry server; the image path is identical.
IMAGE_TAG        ?= dev
GATEWAY_IMAGE    = openshell/gateway:$(IMAGE_TAG)
REGISTRY_IMAGE   = $(REGISTRY_LOCAL)/openshell/gateway:$(IMAGE_TAG)
DOCKER_IMAGE     = $(REGISTRY_DOCKER)/openshell/gateway:$(IMAGE_TAG)

# CLI install
INSTALL_DIR      ?= $(HOME)/.local/bin
CARGO_PROFILE    ?= debug

ifeq ($(CARGO_PROFILE),release)
  CARGO_FLAGS = --release
  CARGO_OUT   = target/release
else
  CARGO_FLAGS =
  CARGO_OUT   = target/debug
endif

# Onboard parameters
OLLAMA_URL       ?= http://ai1.lab:11434
OLLAMA_MODEL     ?= mistral:latest
NEMOCLAW         ?= nemoclaw

# ---------------------------------------------------------------------------
# Phony targets
# ---------------------------------------------------------------------------

.PHONY: help clean build build-cli install-cli build-gateway \
        deploy ensure-registry push-image start-gateway wait-healthy \
        hot-swap onboard

# ---------------------------------------------------------------------------
# help
# ---------------------------------------------------------------------------

help:
	@echo ""
	@echo "OpenShell E2E developer targets"
	@echo ""
	@echo "  make clean          Destroy gateway + remove Docker images + cargo clean"
	@echo "  make build          Compile CLI + build gateway Docker image"
	@echo "  make deploy         Full fresh deploy: registry + image + gateway + onboard"
	@echo ""
	@echo "  make install-cli    Build and install openshell CLI to \$$INSTALL_DIR"
	@echo "  make build-gateway  Build the gateway Docker image only"
	@echo "  make hot-swap       Push local image into already-running cluster"
	@echo "  make onboard        Run nemoclaw onboard against running cluster"
	@echo ""
	@echo "Configuration (override via env vars or make flags):"
	@echo "  GATEWAY_NAME         Cluster/gateway name (default: $(GATEWAY_NAME))"
	@echo "  OLLAMA_URL           Ollama base URL (default: $(OLLAMA_URL))"
	@echo "  OLLAMA_MODEL         Model to use (default: $(OLLAMA_MODEL))"
	@echo "  REGISTRY_DOCKER_HOST Registry host from inside Docker (default: $(REGISTRY_DOCKER_HOST))"
	@echo "  IMAGE_TAG            Docker image tag (default: $(IMAGE_TAG))"
	@echo "  CARGO_PROFILE        debug or release (default: $(CARGO_PROFILE))"
	@echo "  INSTALL_DIR          CLI install path (default: $(INSTALL_DIR))"
	@echo ""

# ---------------------------------------------------------------------------
# clean
# ---------------------------------------------------------------------------

clean:
	@echo "=== Destroying gateway cluster ($(GATEWAY_NAME))..."
	openshell gateway destroy -g "$(GATEWAY_NAME)" 2>/dev/null || true
	@echo "=== Stopping local registry container..."
	docker rm -f "$(REGISTRY_CONTAINER)" 2>/dev/null || true
	@echo "=== Removing local Docker images..."
	docker rmi "$(GATEWAY_IMAGE)" 2>/dev/null || true
	docker rmi "$(REGISTRY_IMAGE)" 2>/dev/null || true
	@echo "=== Cleaning Cargo build artifacts..."
	cargo clean
	@echo "=== Clean complete."

# ---------------------------------------------------------------------------
# build
# ---------------------------------------------------------------------------

build: install-cli build-gateway
	@echo "=== Build complete."
	@echo "    CLI:     $(INSTALL_DIR)/openshell"
	@echo "    Image:   $(GATEWAY_IMAGE)"

build-cli:
	cargo build $(CARGO_FLAGS) --bin openshell

install-cli: build-cli
	@mkdir -p "$(INSTALL_DIR)"
	install -m 755 "$(CARGO_OUT)/openshell" "$(INSTALL_DIR)/openshell"
	@echo "    Installed: $(INSTALL_DIR)/openshell"

build-gateway:
	@echo "=== Building gateway Docker image..."
	tasks/scripts/docker-build-image.sh gateway
	@echo "    Built: $(GATEWAY_IMAGE)"

# ---------------------------------------------------------------------------
# deploy
#
# Full fresh deploy sequence:
#   1. Start (or verify) local Docker registry
#   2. Push local gateway image to the registry
#   3. Destroy any existing gateway cluster
#   4. Start a fresh cluster pointed at the local registry (skips GHCR pull)
#   5. Wait for the gateway to report healthy
#   6. Run nemoclaw onboard
# ---------------------------------------------------------------------------

deploy: ensure-registry push-image start-gateway wait-healthy onboard
	@echo ""
	@echo "=== Deploy complete. Run 'openshell status' to verify."

ensure-registry:
	@echo "=== Ensuring local Docker registry is running..."
	@if docker ps -q --filter "name=^$(REGISTRY_CONTAINER)$$" | grep -q .; then \
	  echo "    Registry already running at $(REGISTRY_LOCAL)"; \
	else \
	  echo "    Starting registry container..."; \
	  docker run -d \
	    --name "$(REGISTRY_CONTAINER)" \
	    -p "$(REGISTRY_PORT):5000" \
	    --restart unless-stopped \
	    registry:2; \
	  echo "    Registry started at $(REGISTRY_LOCAL)"; \
	fi

push-image:
	@echo "=== Pushing gateway image to local registry..."
	@docker image inspect "$(GATEWAY_IMAGE)" >/dev/null 2>&1 || \
	  { echo "Error: image '$(GATEWAY_IMAGE)' not found. Run 'make build' first."; exit 1; }
	docker tag "$(GATEWAY_IMAGE)" "$(REGISTRY_IMAGE)"
	docker push "$(REGISTRY_IMAGE)"
	@echo "    Pushed: $(REGISTRY_IMAGE)"

start-gateway:
	@echo "=== Destroying any existing gateway cluster..."
	openshell gateway destroy -g "$(GATEWAY_NAME)" 2>/dev/null || true
	@echo "=== Starting fresh gateway cluster with local image..."
	@echo "    Registry: $(REGISTRY_DOCKER) (insecure HTTP)"
	@echo "    Image:    $(DOCKER_IMAGE)"
	OPENSHELL_REGISTRY_HOST="$(REGISTRY_DOCKER)" \
	OPENSHELL_REGISTRY_INSECURE=true \
	OPENSHELL_PUSH_IMAGES="$(DOCKER_IMAGE)" \
	IMAGE_TAG="$(IMAGE_TAG)" \
	openshell gateway start --name "$(GATEWAY_NAME)"

wait-healthy:
	@echo "=== Waiting for gateway to become healthy..."
	@for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do \
	  status=$$(openshell status 2>&1); \
	  if echo "$$status" | grep -q "Connected"; then \
	    echo "    Gateway is healthy (attempt $$i)."; \
	    exit 0; \
	  fi; \
	  if [ "$$i" -eq 30 ]; then \
	    echo "Error: gateway failed to become healthy after 60s."; \
	    echo "Run: openshell gateway info"; \
	    exit 1; \
	  fi; \
	  echo "    Waiting... (attempt $$i/30)"; \
	  sleep 2; \
	done

onboard:
	@echo "=== Running nemoclaw onboard..."
	@echo "    Endpoint:  ollama"
	@echo "    URL:       $(OLLAMA_URL)"
	@echo "    Model:     $(OLLAMA_MODEL)"
	"$(NEMOCLAW)" onboard \
	  --non-interactive \
	  --endpoint ollama \
	  --ollama-url "$(OLLAMA_URL)" \
	  --model "$(OLLAMA_MODEL)"
	@echo "=== Onboard complete."

# ---------------------------------------------------------------------------
# hot-swap: push updated image into an already-running cluster
# (use this when iterating on the gateway without a full restart)
# ---------------------------------------------------------------------------

hot-swap: push-image
	@echo "=== Hot-swapping gateway image in running cluster..."
	@docker ps -q --filter "name=^$(CONTAINER_NAME)$$" | grep -q . || \
	  { echo "Error: cluster container '$(CONTAINER_NAME)' is not running."; \
	    echo "Run 'make deploy' to start a fresh cluster."; exit 1; }
	@echo "    Evicting stale image from cluster containerd..."
	docker exec "$(CONTAINER_NAME)" crictl rmi "$(DOCKER_IMAGE)" 2>/dev/null || true
	@echo "    Restarting gateway deployment..."
	docker exec "$(CONTAINER_NAME)" sh -c \
	  "KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl rollout restart statefulset/openshell -n openshell 2>/dev/null || \
	   kubectl rollout restart deployment/openshell -n openshell"
	docker exec "$(CONTAINER_NAME)" sh -c \
	  "KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl rollout status statefulset/openshell -n openshell --timeout=120s 2>/dev/null || \
	   kubectl rollout status deployment/openshell -n openshell --timeout=120s"
	@echo "=== Hot-swap complete."
