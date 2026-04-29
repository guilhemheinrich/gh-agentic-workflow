# Kubeconfig File Format (dashboard artifact)

The file is downloaded from the **Kubernetes administration dashboard**:

- URL: [https://modelo-dashboard-k8s-preprod.septeo.fr](https://modelo-dashboard-k8s-preprod.septeo.fr)

It is a standard kubeconfig (`apiVersion: v1`, `kind: Config`) containing cluster, user, context, and current-context.

## Structure example

```yaml
apiVersion: v1
kind: Config
preferences: {}

clusters:
  - name: modelo-pprod
    cluster:
      certificate-authority-data: <base64-encoded-ca-cert>
      server: https://api-kube-compute-lat.septeo.fr

users:
  - name: modelo-debug-only
    user:
      token: <JWT-token>

contexts:
  - name: modelo-debug-only@modelo-pprod
    context:
      cluster: modelo-pprod
      user: modelo-debug-only
      namespace: modelo-management-pprod

current-context: modelo-debug-only@modelo-pprod
```

## Key points

| Element | Expected value |
|---------|----------------|
| Service account | `modelo-debug-only` (intentionally limited permissions) |
| Namespace (pprod) | `modelo-management-pprod` |
| Cluster API server | `https://api-kube-compute-lat.septeo.fr` |
| Token | JWT bound to the service account (no client certificate in this example) |
| Cluster certificate | `certificate-authority-data` base64-encoded |

## File location on the local machine

The path depends on the project and team conventions, for example:

- `/Users/.../modelo-meet/kubeconfig.yaml`
- `./kubeconfig.yaml` at the root of a cloned repository
- a local secrets directory outside the repository

**Do not version-control this file**: it must **never** be committed to Git (contains secrets and cluster scope).

## Usage with Docker

The kubeconfig is **not** copied into the `k8s-troubleshoot` Docker image. It is mounted read-only in the container, typically at `/home/.kube/config`, with `KUBECONFIG` pointing to that path. See the main SKILL.md for details.
