# =============================================================================
# Enterprise LLM Inference Platform - Top-Level Makefile
# =============================================================================

.PHONY: help setup-runpod setup-gke install-platform deploy-% bench-% clean

SHELL := /bin/bash
ROOT_DIR := $(shell pwd)
INFERENCE_NS := inference
ENTERPRISE_NS := enterprise
MONITORING_NS := monitoring
GATEWAY_NS := gateway

# Default vLLM image
VLLM_IMAGE ?= vllm/vllm-openai:v0.8.5

# =============================================================================
# Help
# =============================================================================

help: ## Show this help
	@echo "Enterprise LLM Inference Platform"
	@echo "================================="
	@echo ""
	@echo "Infrastructure:"
	@grep -E '^setup-' $(MAKEFILE_LIST) | awk -F ':.*?## ' '{printf "  make %-25s %s\n", $$1, $$2}'
	@echo ""
	@echo "Platform:"
	@grep -E '^install-' $(MAKEFILE_LIST) | awk -F ':.*?## ' '{printf "  make %-25s %s\n", $$1, $$2}'
	@echo ""
	@echo "Inference Deployments:"
	@grep -E '^deploy-' $(MAKEFILE_LIST) | awk -F ':.*?## ' '{printf "  make %-25s %s\n", $$1, $$2}'
	@echo ""
	@echo "Benchmarks:"
	@grep -E '^bench-' $(MAKEFILE_LIST) | awk -F ':.*?## ' '{printf "  make %-25s %s\n", $$1, $$2}'
	@echo ""
	@echo "Utilities:"
	@grep -E '^(clean|status|logs)-' $(MAKEFILE_LIST) | awk -F ':.*?## ' '{printf "  make %-25s %s\n", $$1, $$2}'

# =============================================================================
# Infrastructure (Layer 1)
# =============================================================================

setup-runpod: ## Provision RunPod 8xH100 SXM pod and bootstrap k3s
	@echo "==> Setting up RunPod infrastructure..."
	cd $(ROOT_DIR)/infra && bash scripts/setup-runpod.sh

setup-gke: ## Provision GKE cluster with H100 node pool
	@echo "==> Setting up GKE infrastructure..."
	cd $(ROOT_DIR)/infra && bash scripts/setup-gke.sh

setup-k3s: ## Install k3s on current node (run on RunPod pod)
	@echo "==> Installing k3s..."
	cd $(ROOT_DIR)/infra/k8s-bootstrap && bash k3s-install.sh

setup-post-install: ## Install Helm, add repos, create namespaces
	@echo "==> Running post-install setup..."
	cd $(ROOT_DIR)/infra/k8s-bootstrap && bash post-install.sh

# =============================================================================
# Platform (Layer 2)
# =============================================================================

install-platform: install-gpu-operator install-monitoring install-gateway ## Install all platform components

install-gpu-operator: ## Install NVIDIA GPU Operator
	@echo "==> Installing GPU Operator..."
	cd $(ROOT_DIR)/platform/gpu-operator && bash install.sh

install-gpu-operator-mig: ## Install GPU Operator with MIG support
	@echo "==> Installing GPU Operator with MIG..."
	cd $(ROOT_DIR)/platform/gpu-operator && bash install.sh --mig

install-monitoring: ## Install Prometheus + Grafana + DCGM Exporter
	@echo "==> Installing monitoring stack..."
	cd $(ROOT_DIR)/platform/monitoring && bash install.sh

install-gateway: ## Install Gateway API + Inference Extension
	@echo "==> Installing Gateway API..."
	cd $(ROOT_DIR)/platform/gateway-api && bash install.sh

install-network-operator: ## Install Network Operator (for InfiniBand)
	@echo "==> Installing Network Operator..."
	cd $(ROOT_DIR)/platform/network-operator && bash install.sh

install-keda: ## Install KEDA event-driven autoscaler
	@echo "==> Installing KEDA..."
	cd $(ROOT_DIR)/platform/autoscaling && bash keda-install.sh

install-keda-objects: ## Apply KEDA ScaledObjects for all vLLM profiles
	@echo "==> Applying KEDA ScaledObjects..."
	kubectl apply -f $(ROOT_DIR)/platform/autoscaling/keda-vllm.yaml
	kubectl apply -f $(ROOT_DIR)/platform/autoscaling/keda-profiles/

install-prometheus-adapter: ## Install Prometheus Adapter for HPA custom metrics
	@echo "==> Installing Prometheus Adapter..."
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
	helm repo update prometheus-community
	helm upgrade --install prometheus-adapter prometheus-community/prometheus-adapter \
		--namespace $(MONITORING_NS) \
		-f $(ROOT_DIR)/platform/autoscaling/prometheus-adapter/values.yaml \
		--wait --timeout 3m

install-ray-operator: ## Install KubeRay operator (for multi-node Ray clusters)
	@echo "==> Installing KubeRay operator..."
	cd $(ROOT_DIR)/platform/ray-operator && bash install.sh

# =============================================================================
# Model Management
# =============================================================================

download-models: ## Download model weights to PVC
	@echo "==> Downloading model weights..."
	kubectl apply -f $(ROOT_DIR)/inference/model-cache/pvc.yaml
	kubectl apply -f $(ROOT_DIR)/inference/model-cache/download-job.yaml
	kubectl wait --for=condition=complete job/model-download -n $(INFERENCE_NS) --timeout=3600s

# =============================================================================
# Inference Deployments (Layer 3)
# =============================================================================

deploy-8b-mig: ## Deploy Llama 3.1 8B on MIG slices
	@echo "==> Deploying Llama 8B on MIG..."
	kubectl apply -k $(ROOT_DIR)/inference/vllm/profiles/llama-8b-mig/

deploy-70b-tp4: ## Deploy Llama 3.3 70B with TP=4
	@echo "==> Deploying Llama 70B TP=4..."
	kubectl apply -k $(ROOT_DIR)/inference/vllm/profiles/llama-70b-tp4/

deploy-70b-fp8: ## Deploy Llama 3.3 70B FP8 with TP=2
	@echo "==> Deploying Llama 70B FP8 TP=2..."
	kubectl apply -k $(ROOT_DIR)/inference/vllm/profiles/llama-70b-fp8-tp2/

deploy-70b-eagle3: ## Deploy Llama 3.3 70B + EAGLE3 speculative decoding
	@echo "==> Deploying Llama 70B + EAGLE3..."
	kubectl apply -k $(ROOT_DIR)/inference/vllm/profiles/llama-70b-eagle3/

deploy-70b-disagg: ## Deploy Llama 3.3 70B disaggregated prefill/decode
	@echo "==> Deploying Llama 70B disaggregated P/D..."
	kubectl apply -k $(ROOT_DIR)/inference/vllm/profiles/llama-70b-disagg-pd/

deploy-405b-multinode: ## Deploy Llama 3.1 405B multi-node via LeaderWorkerSet (dev)
	@echo "==> Deploying Llama 405B multi-node (LeaderWorkerSet)..."
	kubectl apply -k $(ROOT_DIR)/inference/vllm/profiles/llama-405b-multinode/

deploy-405b-ray: ## Deploy Llama 3.1 405B multi-node via KubeRay (production)
	@echo "==> Deploying Llama 405B multi-node (KubeRay RayCluster)..."
	kubectl apply -f $(ROOT_DIR)/inference/vllm/profiles/llama-405b-multinode/ray-cluster.yaml

deploy-llmd: ## Deploy llm-d InferencePool and InferenceModel CRDs
	@echo "==> Deploying llm-d..."
	cd $(ROOT_DIR)/inference/llm-d && bash install.sh

# =============================================================================
# Enterprise Services (Layer 4)
# =============================================================================

deploy-enterprise: deploy-litellm deploy-guardrails ## Deploy all enterprise services

deploy-litellm: ## Deploy LiteLLM proxy with PostgreSQL and Redis
	@echo "==> Deploying LiteLLM..."
	kubectl apply -f $(ROOT_DIR)/enterprise/litellm/postgres.yaml
	kubectl apply -f $(ROOT_DIR)/enterprise/litellm/redis.yaml
	kubectl wait --for=condition=ready pod -l app=postgres -n $(ENTERPRISE_NS) --timeout=120s
	kubectl wait --for=condition=ready pod -l app=redis -n $(ENTERPRISE_NS) --timeout=120s
	kubectl apply -f $(ROOT_DIR)/enterprise/litellm/config.yaml
	kubectl apply -f $(ROOT_DIR)/enterprise/litellm/deployment.yaml
	kubectl apply -f $(ROOT_DIR)/enterprise/litellm/service.yaml

deploy-guardrails: deploy-llm-guard deploy-nemo-guardrails ## Deploy all guardrails

deploy-nemo-guardrails: ## Deploy NeMo Guardrails
	@echo "==> Deploying NeMo Guardrails..."
	kubectl apply -f $(ROOT_DIR)/enterprise/guardrails/nemo-guardrails/configmap.yaml
	kubectl apply -f $(ROOT_DIR)/enterprise/guardrails/nemo-guardrails/deployment.yaml

deploy-llm-guard: ## Deploy LLM Guard
	@echo "==> Deploying LLM Guard..."
	kubectl apply -f $(ROOT_DIR)/enterprise/guardrails/llm-guard/config.yaml
	kubectl apply -f $(ROOT_DIR)/enterprise/guardrails/llm-guard/deployment.yaml

# =============================================================================
# Benchmarks (Layer 5)
# =============================================================================

bench-download-dataset: ## Download ShareGPT dataset for benchmarks
	@echo "==> Downloading ShareGPT dataset..."
	cd $(ROOT_DIR)/benchmarks/scripts && bash download-sharegpt.sh

bench-8b: ## Benchmark Llama 8B on MIG
	@echo "==> Benchmarking Llama 8B..."
	cd $(ROOT_DIR)/benchmarks/scripts && bash bench-vllm.sh 8b-mig

bench-70b: ## Benchmark Llama 70B TP=4
	@echo "==> Benchmarking Llama 70B..."
	cd $(ROOT_DIR)/benchmarks/scripts && bash bench-vllm.sh 70b-tp4

bench-all: ## Run full benchmark suite across all profiles
	@echo "==> Running full benchmark suite..."
	cd $(ROOT_DIR)/benchmarks/scripts && bash run-all-benchmarks.sh

bench-locust: ## Run Locust load test
	@echo "==> Running Locust load test..."
	cd $(ROOT_DIR)/benchmarks/locust && pip install -r requirements.txt && \
	locust -f locustfile.py --headless -u 50 -r 5 -t 300s

bench-k6: ## Run k6 CI/CD test
	@echo "==> Running k6 tests..."
	cd $(ROOT_DIR)/benchmarks/k6 && k6 run chat-completion.js

# =============================================================================
# Utilities
# =============================================================================

status-all: ## Show status of all components
	@echo "==> GPU Status:"
	@nvidia-smi --query-gpu=index,name,memory.used,memory.total,utilization.gpu --format=csv 2>/dev/null || echo "  nvidia-smi not available"
	@echo ""
	@echo "==> Kubernetes Pods:"
	@kubectl get pods -A --field-selector=metadata.namespace!=kube-system 2>/dev/null || echo "  kubectl not available"
	@echo ""
	@echo "==> vLLM Services:"
	@kubectl get svc -n $(INFERENCE_NS) 2>/dev/null || echo "  No inference services"

status-gpu: ## Show GPU status (nvidia-smi)
	nvidia-smi
	@echo ""
	@echo "==> MIG Status:"
	nvidia-smi mig -lgi 2>/dev/null || echo "  MIG not configured"

status-inference: ## Show inference pod status
	kubectl get pods -n $(INFERENCE_NS) -o wide
	kubectl get svc -n $(INFERENCE_NS)

logs-vllm: ## Tail vLLM logs
	kubectl logs -f -l app=vllm -n $(INFERENCE_NS) --tail=100

logs-litellm: ## Tail LiteLLM logs
	kubectl logs -f -l app=litellm -n $(ENTERPRISE_NS) --tail=100

clean-inference: ## Delete all inference deployments
	@echo "==> Cleaning inference deployments..."
	kubectl delete -k $(ROOT_DIR)/inference/vllm/profiles/llama-8b-mig/ --ignore-not-found
	kubectl delete -k $(ROOT_DIR)/inference/vllm/profiles/llama-70b-tp4/ --ignore-not-found
	kubectl delete -k $(ROOT_DIR)/inference/vllm/profiles/llama-70b-fp8-tp2/ --ignore-not-found
	kubectl delete -k $(ROOT_DIR)/inference/vllm/profiles/llama-70b-eagle3/ --ignore-not-found
	kubectl delete -k $(ROOT_DIR)/inference/vllm/profiles/llama-70b-disagg-pd/ --ignore-not-found

clean-enterprise: ## Delete enterprise services
	@echo "==> Cleaning enterprise services..."
	kubectl delete -f $(ROOT_DIR)/enterprise/litellm/ --ignore-not-found
	kubectl delete -f $(ROOT_DIR)/enterprise/guardrails/nemo-guardrails/ --ignore-not-found
	kubectl delete -f $(ROOT_DIR)/enterprise/guardrails/llm-guard/ --ignore-not-found

clean-all: clean-inference clean-enterprise ## Delete all deployments
	@echo "==> All deployments cleaned"
