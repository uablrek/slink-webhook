
.PHONY: all 
all: image cert/slink-webhook.crt cert/slink-webhook.key

_output/slink-webhook: cmd/slink-webhook/main.go
	./build.sh binary

cert/slink-webhook.crt cert/slink-webhook.key:
	./build.sh cert --namespace=$(NAMESPACE)

.PHONY: image
image: _output/slink-webhook
	./build.sh image

.PHONY: clean
clean:
	rm -rf cert _output

