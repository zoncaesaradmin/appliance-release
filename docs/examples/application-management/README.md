# Application Management Example

Application Management is a built-in Control Plane capability, not a separate
runtime service and not part of Automation Runtime. The Control Plane accepts a
validated, digest-pinned application definition and reconciles its workload in
the permanently provisioned `apps` namespace.

The image reference in this example is intentionally local and digest-pinned.
Application images must already be available through the appliance's offline
registry/import flow; application management never downloads images from the
public internet.
