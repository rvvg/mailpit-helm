CHART      := charts/mailpit
KIND_NAME  ?= mailpit-test
CALICO     ?= v3.33.0

.PHONY: all lint unit docs docs-check test test-cluster clean

all: docs lint unit

lint:
	helm lint $(CHART)
	@for f in $(CHART)/ci/*.yaml; do \
		echo "--- $$f"; \
		helm lint $(CHART) -f $$f >/dev/null || exit 1; \
		helm template t $(CHART) -f $$f | kubeconform -strict -summary -ignore-missing-schemas \
			-schema-location default \
			-schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' - || exit 1; \
	done

unit:
	helm unittest --strict $(CHART)

docs:
	python3 hack/gen-params.py $(CHART)/values.yaml README.md
	@# Artifact Hub renders the chart README outside GitHub: make relative links absolute
	sed -E 's#\]\((LICENSE|SECURITY\.md|examples[^)]*)\)#](https://github.com/rvvg/mailpit-helm/blob/main/\1)#g' README.md > $(CHART)/README.md

docs-check: docs
	git diff --exit-code README.md $(CHART)/README.md

test-cluster:
	kind create cluster --name $(KIND_NAME) --config hack/kind-calico.yaml
	kubectl apply --server-side -f https://raw.githubusercontent.com/projectcalico/calico/$(CALICO)/manifests/calico.yaml
	kubectl -n kube-system rollout status ds/calico-node --timeout=300s

test:
	ct install --config ct.yaml --all

clean:
	kind delete cluster --name $(KIND_NAME)
