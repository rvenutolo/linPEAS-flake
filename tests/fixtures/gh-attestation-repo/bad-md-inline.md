# bad inline command

The published image is a multi-arch manifest. This means:

- `gh attestation verify oci://docker.io/example/foo:<tag>` may not
    resolve cleanly against the manifest index alone.
