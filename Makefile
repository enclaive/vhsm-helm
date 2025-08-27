TEST_IMAGE ?= vhsm-helm-test

# set to run a single test - e.g test/acceptance/server.bats
ACCEPTANCE_TESTS ?= test/acceptance

# filter bats unit tests to run.
UNIT_TESTS_FILTER ?= '.*'

KIND_CLUSTER_NAME ?= vhsm-helm

# kind k8s version
KIND_K8S_VERSION ?= v1.33.2

# Generate json schema for chart values. See test/README.md for more details.
values-schema:
	helm-schema -k title,description,default,required,additionalProperties

test: test-image test-bats

test-image:
	@docker build --rm -t $(TEST_IMAGE) -f $(CURDIR)/test/docker/Dockerfile $(CURDIR)

test-bats: test-unit test-acceptance

test-unit:
	@docker run --rm -it -v ${PWD}:/helm-test $(TEST_IMAGE) bats -f $(UNIT_TESTS_FILTER) /helm-test/test/unit

test-acceptance: setup-kind acceptance

acceptance:
	@[ -n "$(ENCLAIVE_LICENCE)" ] || (echo "Please set ENCLAIVE_LICENCE to a valid value" ; exit 1)
	bats --tap --timing ${ACCEPTANCE_TESTS}

setup-kind:
	kind get clusters | grep -q "^${KIND_CLUSTER_NAME}$$" || \
	kind create cluster \
		--image kindest/node:${KIND_K8S_VERSION} \
		--name ${KIND_CLUSTER_NAME} \
		--config $(CURDIR)/test/kind/config.yaml
	kubectl config use-context kind-${KIND_CLUSTER_NAME}

delete-kind:
	kind delete cluster --name ${KIND_CLUSTER_NAME} || :

.PHONY: values-schema test test-image test-bats test-unit test-acceptance acceptance setup-kind delete-kind
