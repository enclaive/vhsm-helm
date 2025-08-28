TEST_IMAGE?=vault-helm-test

# set to run a single test - e.g acceptance/server-ha-enterprise-dr.bats
ACCEPTANCE_TESTS?=acceptance

# filter bats unit tests to run.
UNIT_TESTS_FILTER?='.*'

# set to 'true' to run acceptance tests locally in a kind cluster
LOCAL_ACCEPTANCE_TESTS?=false

# kind cluster name
KIND_CLUSTER_NAME?=vault-helm

# kind k8s version
KIND_K8S_VERSION?=v1.29.2

# Generate json schema for chart values. See test/README.md for more details.
values-schema:
	helm schema-gen values.yaml > values.schema.json

test-image:
	@docker build --rm -t $(TEST_IMAGE) -f $(CURDIR)/test/docker/Dockerfile $(CURDIR)

test-unit:
	@docker run --rm -it -v ${PWD}:/helm-test $(TEST_IMAGE) bats -f $(UNIT_TESTS_FILTER) /helm-test/test/unit

test-bats: test-unit test-acceptance

test: test-image test-bats

test-acceptance: setup-kind acceptance

acceptance:
	bats --tap --timing test/${ACCEPTANCE_TESTS}

setup-kind:
	kind get clusters | grep -q "^${KIND_CLUSTER_NAME}$$" || \
	kind create cluster \
		--image kindest/node:${KIND_K8S_VERSION} \
		--name ${KIND_CLUSTER_NAME} \
		--config $(CURDIR)/test/kind/config.yaml
	kubectl config use-context kind-${KIND_CLUSTER_NAME}

delete-kind:
	kind delete cluster --name ${KIND_CLUSTER_NAME} || :

.PHONY: values-schema test-image test-unit test-bats test test-acceptance test-destroy test-provision acceptance provision-cluster destroy-cluster
