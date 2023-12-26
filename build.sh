#! /bin/sh
##
## build.sh --
##
##   Help script for github.com/uablrek/slink-webhook
##

prg=$(basename $0)
dir=$(dirname $0); dir=$(readlink -f $dir)
me=$dir/$prg
tmp=/tmp/${prg}_$$

die() {
    echo "ERROR: $*" >&2
    rm -rf $tmp
    exit 1
}
help() {
    grep '^##' $0 | cut -c3-
    rm -rf $tmp
    exit 0
}
test -n "$1" || help
echo "$1" | grep -qi "^help\|-h" && help

log() {
	echo "$*" >&2
}
dbg() {
	test -n "$__verbose" && echo "$prg: $*" >&2
}

## Commands;
##

##   env
##     Print environment.
cmd_env() {
	test "$envread" = "yes" && return 0
	envread=yes
	eset \
		__namespace=slink-webhook \
		__certd=$dir/cert \
		__tag=docker.io/uablrek/slink-webhook:latest
    # Build a *correct* semantic version from date and time (no leading 0's)
    eset __version=$(date +%Y.%_m.%_d+%H.%M | tr -d ' ')

	if test "$cmd" = "env"; then
		opt="namespace|certd|version|tag"
		set | grep -E "^(__($opt))="
		return 0
	fi
	cd $dir
}
# Set variables unless already defined
eset() {
	local e k
	for e in $@; do
		k=$(echo $e | cut -d= -f1)
		test -n "$(eval echo \$$k)" || eval $e
	done
}
##   binary
##     Build the binary in "_output/"
cmd_binary() {
    cmd_env
	mkdir -p $dir/_output
    CGO_ENABLED=0 GOOS=linux \
        go build -ldflags "-extldflags '-static' -X main.version=$__version" \
        -o $dir/_output ./... || die "Build failed"
    strip $dir/_output/slink-webhook
}
##   image [--tag=]
##     Build the image. Update deployment scripts if --tag= is used
cmd_image() {
	cmd_env
	test -x _output/slink-webhook || cmd_binary
	docker build -t $__tag $dir
}
##   emit_csr_conf
##     Emit a csr (Certificate Signing Request) config
cmd_emit_csr_conf() {
	cmd_env
	cat <<EOF
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name
prompt = no
[req_distinguished_name]
CN = slink-webhook.$__namespace.svc
[ v3_req ]
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names
[alt_names]
DNS.1 = slink-webhook
DNS.2 = slink-webhook.$__namespace
DNS.3 = slink-webhook.$__namespace.svc
DNS.4 = slink-webhook.$__namespace.svc.cluster.local
DNS.5 = localhost
EOF
}
##   cert [--namespace=]
##     Create a key and self-signed certificate for the webhook
cmd_cert() {
	cmd_env
	mkdir -p $tmp
	cmd_emit_csr_conf > $tmp/csr.conf
	mkdir -p $__certd || die
	cd $__certd
	test -r slink-webhook.key \
		|| openssl genrsa -out slink-webhook.key 2048
	openssl req -new -key slink-webhook.key -out $tmp/csr -config $tmp/csr.conf
	
	openssl req -x509 -key slink-webhook.key -out slink-webhook.crt -days 3650 -nodes -in $tmp/csr -copy_extensions copyall
	#openssl x509 -noout -text -in cert/slink-webhook.crt
}
##   manifests
##     Build manifests from templates
cmd_manifests() {
	cmd_env
	export __tag
	cat $dir/deployment/slink-webhook-template.yaml | envsubst \
		> $dir/deployment/slink-webhook.yaml
	export __namespace
	export CABUNDLE=$(cat $dir/cert/slink-webhook.crt | base64 | tr -d '\n')
	cat $dir/deployment/slink-webhook-conf-template.yaml | envsubst \
		> $dir/deployment/slink-webhook-conf.yaml
	test "$__combo" = "yes" && combo_manifest
}
# Create a combo-manifest
combo_manifest() {
	local out=$dir/deployment/slink-webhook-all.yaml
	cat > $out <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $__namespace
---
EOF
	local f
	for f in slink-webhook-svc slink-webhook; do
		cat $dir/deployment/$f.yaml \
			| sed -e '/^metadata:/a\' -e "  namespace: $__namespace" >> $out
		echo "---" >> $out
	done
	cat $dir/deployment/slink-webhook-conf.yaml >> $out
}
##   deploy [--namespace=]
##     Deploy the slink-webhook
cmd_deploy() {
	cmd_manifests
	# Check that we have contact with the cluster
	kubectl cluster-info --request-timeout=1 > /dev/null 2>&1 \
		|| die "No contact with the cluster"
	kubectl get namespace $__namespace -o name 2> /dev/null \
		|| kubectl create namespace $__namespace || die "create namespace"
	kubectl -n $__namespace create -f $dir/deployment/slink-webhook-svc.yaml \
		|| die "Create slink-webhook service"
	kubectl -n $__namespace create -f $dir/deployment/slink-webhook.yaml \
		|| die "Create slink-webhook deployment"
	kubectl create -f $dir/deployment/slink-webhook-conf.yaml \
		|| die "Create slink-webhook configuration"
}
##   undeploy [--namespace=]
##     Delete the slink-webhook.
cmd_undeploy() {
	cmd_manifests
	# Check that we have contact with the cluster
	kubectl cluster-info --request-timeout=1 > /dev/null 2>&1 \
		|| die "No contact with the cluster"
	kubectl delete -f $dir/deployment/slink-webhook-conf.yaml \
		|| die "Create slink-webhook configuration"
	kubectl -n $__namespace delete -f $dir/deployment/slink-webhook.yaml \
		|| die "Create slink-webhook deployment"
	kubectl -n $__namespace delete -f $dir/deployment/slink-webhook-svc.yaml \
		|| die "Create slink-webhook service"
}
##   test
##     Create a test-pod in "default" namespace and verify that it
##     gets "enableServiceLinks:false", then create a test-pod in
##     "slink-webhook" namespace and verify that it remains with
##     "enableServiceLinks:true"
cmd_test() {
	cmd_env
	# Check that we have contact with the cluster
	kubectl cluster-info --request-timeout=1 > /dev/null 2>&1 \
		|| die "No contact with the cluster"
	kubectl create -f ./test/testpod.yaml || die "Create testpod"
	
}

##
# Get the command
cmd=$1
shift
grep -q "^cmd_$cmd()" $0 $hook || die "Invalid command [$cmd]"

while echo "$1" | grep -q '^--'; do
	if echo $1 | grep -q =; then
		o=$(echo "$1" | cut -d= -f1 | sed -e 's,-,_,g')
		v=$(echo "$1" | cut -d= -f2-)
		eval "$o=\"$v\""
	else
		o=$(echo "$1" | sed -e 's,-,_,g')
		eval "$o=yes"
	fi
	shift
done
unset o v
long_opts=`set | grep '^__' | cut -d= -f1`

# Execute command
trap "die Interrupted" INT TERM
cmd_$cmd "$@"
status=$?
rm -rf $tmp
exit $status
