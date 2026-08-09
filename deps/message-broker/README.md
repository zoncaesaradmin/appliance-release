# message-broker

Seeds the pinned NATS image used by the always-on appliance JetStream message
broker. Offline release builds consume the LAN `build-cache/nats` reference;
online builds use the same upstream pin through the shared packaging path.
