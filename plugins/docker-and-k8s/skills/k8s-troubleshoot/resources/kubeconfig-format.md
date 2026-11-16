# Kubeconfig file format (dashboard artifact)

The file is downloaded from your organization's Kubernetes administration dashboard (Kubeconfig button of the namespace). It is a standard kubeconfig (`apiVersion: v1`, `kind: Config`).

```yaml
apiVersion: v1
kind: Config
preferences: {}

clusters:
  - name: acme-preprod
    cluster:
      certificate-authority-data: <base64-encoded-ca-cert>
      server: https://k8s-api.example.com

users:
  - name: debug-only
    user:
      token: <JWT-token>

contexts:
  - name: debug-only@acme-preprod
    context:
      cluster: acme-preprod
      user: debug-only
      namespace: acme-app-preprod

current-context: debug-only@acme-preprod
```

## Key points

- Service account `debug-only` has intentionally limited permissions (see `scope-permissions.md`).
- Authentication is a JWT bound to the service account, no client certificate.
- The path on disk depends on the project: `./kubeconfig.yaml`, `~/.kube/config-dashboard`, or a secrets directory outside the repository.
- **Never commit this file**: it contains a token and cluster scope.
- It is not copied into the `k8s-troubleshoot` image; it is mounted read-only at `/home/.kube/config` with `KUBECONFIG` pointing to it.
