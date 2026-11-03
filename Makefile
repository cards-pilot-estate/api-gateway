ENV ?= dev
EG_VERSION := v1.9.3

.PHONY: install deploy test lint render

install: ## Install or upgrade the Envoy Gateway controller (cluster-wide, once per cluster)
	helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm --version $(EG_VERSION) \
	  -n envoy-gateway-system --create-namespace -f values/envoy-gateway.yaml --wait --timeout 5m

deploy: ## Install or upgrade the gateway, its routes and policies (every environment of the cluster)
	kubectl create namespace api-gateway --dry-run=client -o yaml | kubectl apply -f -
	helm upgrade --install api-gateway chart/api-gateway -n api-gateway -f environments/kind.yaml --wait --timeout 4m

test: ## Live checks of every acceptance item against ENV
	bash scripts/gateway-test.sh $(ENV)

lint: ## Lint and render the chart
	helm lint chart/api-gateway -f environments/kind.yaml
	helm template api-gateway chart/api-gateway -n api-gateway -f environments/kind.yaml > /dev/null

render: ## Print the rendered manifests
	helm template api-gateway chart/api-gateway -n api-gateway -f environments/kind.yaml
