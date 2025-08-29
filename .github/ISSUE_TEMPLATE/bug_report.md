---
name: Bug report
about: Let us know about a bug!
title: ''
labels: bug
assignees: ''

---

**Describe the bug**
A clear and concise description of what the bug is.

**To Reproduce**
Steps to reproduce the behavior:
1. Install chart
2. Run vhsm command
3. See error (vhsm logs, etc.)

Other useful info to include: vhsm pod logs, `kubectl describe statefulset vhsm` and `kubectl get statefulset vhsm -o yaml` output

**Expected behavior**
A clear and concise description of what you expected to happen.

**Environment**
* Kubernetes version: 
  * Distribution or cloud vendor (OpenShift, EKS, GKE, AKS, etc.):
  * Other configuration options or runtime services (istio, etc.):
* vhsm-helm version:

Chart values:

```yaml
# Paste your user-supplied values here (`helm get values <release>`).
# Be sure to scrub any sensitive values!
```

**Additional context**
Add any other context about the problem here.
