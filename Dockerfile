FROM scratch
COPY --chown=0:0 _output/ /
COPY --chown=0:0 cert/ /cert
CMD ["/slink-webhook"]
