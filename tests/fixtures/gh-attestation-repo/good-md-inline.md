# good inline command

The published image is a multi-arch manifest. This means:

- `gh attestation verify oci://docker.io/example/foo:<tag> --repo rvenutolo/linPEAS-flake` may
    not resolve cleanly against the manifest index alone.
