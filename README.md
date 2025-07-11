# Virtual HSM Helm Chart

This repository contains the official enclaive Helm chart for installing
and configuring vHSM, comprising the key management Vault and attestation verification service Nitride, on Kubernetes. This chart supports multiple use
cases of Vault and Nitride on Kubernetes depending on the values provided.

For full documentation on this Helm chart along with all the ways you can
use Vault with Kubernetes, please see the
[vHSM documentation](https://developer.hashicorp.com/vault/docs/platform/k8s](https://docs.enclaive.cloud/virtual-hsm).

## Prerequisites

To use the charts here, [Helm](https://helm.sh/) must be configured for your
Kubernetes cluster. Setting up Kubernetes and Helm is outside the scope of
this README. Please refer to the Kubernetes and Helm documentation.

The versions required are:

  * **Helm 3.6+**
  * **Kubernetes 1.22+** - This is the earliest version of Kubernetes tested.
    It is possible that this chart works with earlier versions but it is
    untested.

## Usage

To install the latest version of this chart, add the Hashicorp helm repository
and run `helm install`:

```sh
helm install vhsm oci://harbor.enclaive.cloud/vhsm \
  --version 0.28.1 \
  --set injector.enabled=false \
  --set server.extraEnvironmentVars.ENCLAIVE_LICENCE="$licence"
```

Please see the many options supported in the `values.yaml` file. 
