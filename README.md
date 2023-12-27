# slink-webhook

A [K8s mutating webhook](
https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/) to set `enableServiceLinks: false` in PODs.
Initiated by K8s issue [#121787](
https://github.com/kubernetes/kubernetes/issues/121787). By default
environment variables are generated for all services, and in
namespaces with very many services PODs can crash because of a too-big
environment.

## Quick install in a test cluster

**NOTE:** Don't use this in a production cluster, where you should have
more control and security. Build your own image, and use your own key
and certificate.

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
kubectl exec testpod -- env
```

Uninstall with:
```
kubectl delete MutatingWebhookConfiguration slink-webhook
kubectl delete namespace slink-webhook
kubectl delete pod testpod
```

## Build

The default way is to use a self-signed certificate and include the
certificate and key in the image. You can specify your own image tag
and namespace with environment variables.

```
export __namespace=my-webhooks
export __tag=example.com/webhooks/svc-links:1.0.0
make cert    # Generate a key and self-signed certificate in cert/
make         # Build the image
#docker push $__tag
make deploy
#./build.sh undeploy
```

The `cert/` directory is included in the image. If you prefer to mount
vulumes, or sectrets, for the cert and/or key, just make sure the
`cert/` is empty, or just contain the certificate, when building the image.

If `cert/slink-webhook.crt` doesn't exist you must provide a
"caBundle" to be used in the webhook configuration manifest. This is
for instance needed if you use a certificate signed by a CA.

```
__cabundle=$(cat ca.crt | base64 | tr -d '\n')
./build.sh manifests
```

#### Make vs build.sh

Make uses dependencies to speed up the build process. When you
don't use them, but instead write scripts in `make`, it's more
maintainable to use a script. But many users expects to type "make",
so I made a compromise where `build.sh` is called from a thin
Makefile. Invoke `build.sh` without parametes for a help printout.


## Configure namespaces

By default the webhook is called for all PODs, except in the
[kube-system namespace](https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/#avoiding-operating-on-the-kube-system-namespace),
and in the namespace of the [webhook itself](https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/#avoiding-deadlocks-in-self-hosted-webhooks).

You should probably narrow this down to the namespaces where you have
problems with large environemnts caused by many services, by editing
"deployment/slink-webhook-conf-template.yaml".


## Logging

Structured logging with json formatting is used.

```
k8s-webhook > pod=$(kubectl -n slink-webhook get pods -o name)
kubectl -n slink-webhook logs $pod | jq
```

The log level can be controlled by the `LOG_LEVEL` variable in the
manifest. At default level `0`, only start/stop events and errors are
logged. Higher levels should be avoided in production.


## Test

The `createsvcs` script mentioned in the [issue](
http://github.com/kubernetes/kubernetes/issues/121787) is included,
and can be used to create a lot of services.

```
export namespace=env-test
kubectl create namespace $namespace
./test/createsvcs 100
kubectl -n $namespace create -f - <<EOF
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
kubectl -n $namespace get pod testpod -o json | jq .spec.enableServiceLinks
kubectl -n $namespace exec testpod -- env | wc -lc
kubectl delete namespace $namespace
```

Test with and without the webhook.
