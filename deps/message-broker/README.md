# message-broker

The upstream image is pinned with its fully qualified Docker Hub name so
Podman does not depend on host-specific short-name aliases.

Seeds the pinned NATS image used by the always-on appliance JetStream message
broker. Offline release builds consume the LAN `build-cache/nats` reference;
online builds use the same upstream pin through the shared packaging path.
