# Tiny image that only holds the Gateway API traffic-router plugin binary.
# Built by the owner (not CI): k8s-pull can read belleshop, not the ghcr proxy, and
# Caddy does not route /v2/argoproj-labs/* — so we cannot pull the upstream plugin
# image through registry.home.arpa. Busybox is already in the dockerhub proxy.
#
# Binary is not in git. Owner downloads it at build time and verifies
# sha256 1904ca787d33107c140521899d61fff030ee75d99908bd175fca5a4647759061
# (docs/runbooks/argo-rollouts-plugin.md).
FROM registry.home.arpa/dockerhub/library/busybox:1.36.1@sha256:650fd573e056b679a5110a70aabeb01e26b76e545ec4b9c70a9523f2dfaf18c6
COPY gatewayapi-plugin-linux-amd64 /plugin/gatewayapi-plugin-linux-amd64
USER 65534
