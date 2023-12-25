FROM scratch
COPY --chown=0:0 _output/ /
CMD ["/slink-webhook"]
