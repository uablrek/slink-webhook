# slink-webhook

A K8s mutating webhook to set `enableServiceLinks: false` in PODs.
Initiated by K8s issue [#121787](
https://github.com/kubernetes/kubernetes/issues/121787). By default
environment variables are generated for all services, and in
namespaces with very many services PODs can crash because of a too-big
environment.

## Quick install in a test cluster

**NOTE:** Don't do this in a production cluster, where you should have
more control and security. Then you should build your own image, and
pay some attention to certificates.

In a test cluster, e.g. [KinD](https://kind.sigs.k8s.io/):
```
kubectl create -f https://raw.githubusercontent.com/uablrek/slink-webhook/main/deployment/slink-webhook-all.yaml
```

This will install the webhook in the `slink-webhook` namespace and
configure it. All created or updated PODs will now get
`enableServiceLinks: false` unconditionally.

```
kubectl create -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: testpod
spec:
  containers:
  - name: alpine
    image: alpine:latest
    imagePullPolicy: IfNotPresent
    command: ["tail", "-f", "/dev/null"]
EOF
kubectl get pod testpod -o json | jq .spec.enableServiceLinks
```

Uninstall with:
```
kubectl delete MutatingWebhookConfiguration slink-webhook
kubectl delete namespace slink-webhook
kubectl delete pod testpod
```

