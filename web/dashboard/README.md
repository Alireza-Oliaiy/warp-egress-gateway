# WARP Gateway Read-Only Dashboard

This package contains a standard-library-only collector, strict status schema,
loopback HTTP server, local fixtures, and vanilla frontend. It does not import
the privileged helper and exposes no control endpoints.

Launch the local healthy demo from the repository root:

```bash
python3 -m web.dashboard.server --fixture healthy --listen 127.0.0.1 --port 8787
```

Open `http://127.0.0.1:8787`. Other fixture names are `degraded` and `failed`.

The production snapshot path is fixed at:

```text
/run/warp-egress-dashboard/status.json
```

Production directory/file metadata is `root:warp-web 0750` and
`root:warp-web 0640`, respectively. This repository phase does not install or
deploy those objects.
