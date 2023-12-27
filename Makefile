
.PHONY: image
image: binary
	./build.sh image

.PHONY: binary
binary: _output/slink-webhook
_output/slink-webhook: cmd/slink-webhook/main.go
	./build.sh binary

.PHONY: cert
cert:
	./build.sh cert

.PHONY: deploy
deploy:
	./build.sh deploy

.PHONY: clean
clean:
	rm -rf _output deployment/slink-webhook.yaml deployment/slink-webhook-conf.yaml
