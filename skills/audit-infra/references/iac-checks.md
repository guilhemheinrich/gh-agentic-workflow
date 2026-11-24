# Docker, Compose, Terraform / CloudFormation and CI/CD checks

Same format as `k8s-checks.md`: field, failing value, reason, reporting tool. Tool ids
were observed by running `scripts/scan-iac.sh --with-checkov scripts/fixtures`
(trivy 0.76.2, hadolint v2.15.1, checkov 3.4.9). `manual` = no scanner reported it on
the fixture.

House references to link rather than repeat: `skills/dockerfile` (multi-stage,
non-root, health checks), `skills/compose-env-ports` (port collisions),
`skills/devops-pipeline-design` (pipeline shape).

## Dockerfile

| # | Check | Fails when | Why | Tool |
|---|---|---|---|---|
| D-01 | Base image tag | `FROM image` or `FROM image:latest` | The build of today and the build of tomorrow differ silently | hadolint `DL3007` (`:latest`, seen on the fixture) and `DL3006` (no tag, from hadolint's rule list), trivy `DS-0001`, checkov `CKV_DOCKER_7` |
| D-02 | `USER` | absent, or `root`, in the final stage | The process runs as the base image's user, which is uid 0 unless the base sets one: check the base (`docker image inspect -f '{{.Config.User}}'`) before writing "runs as root" | trivy `DS-0002`, checkov `CKV_DOCKER_3` |
| D-03 | Package installs | `apt-get install` without pinned versions, `--no-install-recommends` or list cleanup | Non-reproducible and oversized images, more CVEs to carry | hadolint `DL3008`, `DL3009`, `DL3015`, trivy `DS-0029` |
| D-04 | `ADD` with a URL or an archive | present | Fetches unverified content at build time; `COPY` plus a checksum is auditable | checkov `CKV_DOCKER_4` |
| D-05 | `HEALTHCHECK` | absent (for images run outside Kubernetes) | The runtime cannot tell a hung process from a healthy one | trivy `DS-0026`, checkov `CKV_DOCKER_2` |
| D-06 | `EXPOSE 22` | present | A hint that an SSH daemon is shipped, a second, unmanaged way in. `EXPOSE` opens nothing by itself: look for `sshd` in the image before reporting more than the hint | trivy `DS-0004`, checkov `CKV_DOCKER_1` |
| D-07 | `CMD` / `ENTRYPOINT` form | shell form (`CMD npm start`) | The process is not PID 1 and never receives SIGTERM: no graceful shutdown | hadolint `DL3025` |
| D-08 | Secrets in `ARG` / `ENV` / `COPY .env` | present | They stay in the image history for anyone who can pull | trivy secret scanner on the built image, manual on the Dockerfile |
| D-09 | Multi-stage | compilers and dev dependencies in the final stage | Attack surface and CVE count | manual; compare `docker history` sizes |

## Docker Compose

Compose is the blind spot of the scanners: on `fixtures/compose/docker-compose.yml`
trivy, hadolint and kube-linter reported **zero** findings, and checkov reported only
the password inside `DATABASE_URL` (`CKV_SECRET_4`). Every row below is therefore
covered by `topology-from-manifests.py` or by reading the file.

| # | Check | Fails when | Why | Tool |
|---|---|---|---|---|
| C-01 | `ports:` on a datastore | `"5432:5432"` (binds 0.0.0.0) | Docker publishes on every interface **and inserts its own iptables rules ahead of the host firewall**: `ufw deny 5432` does not block it | topology `T-CMP-01` |
| C-02 | `ports:` binding | no `127.0.0.1:` prefix on a port meant for a local reverse proxy | Same as C-01 for admin UIs | topology draws `internet -->` instead of `Host loopback -->` |
| C-03 | `privileged: true`, `cap_add: [SYS_ADMIN]`, `network_mode: host`, `pid: host` | present | Container isolation is off | topology `T-CMP-02` (`privileged`, `network_mode`); `cap_add` and `pid` manual |
| C-04 | `/var/run/docker.sock` mounted | present | Whoever controls the container controls the Docker daemon, hence root on the host | topology `T-CMP-03` |
| C-05 | Image tags | `latest` or none | As D-01 | topology `T-CMP-04` |
| C-06 | Secrets in `environment:` | literal password or token | Committed in Git, visible in `docker inspect` | checkov `CKV_SECRET_4` for URL credentials only; otherwise manual. Prefer `secrets:` or an untracked env file |
| C-07 | `restart:` and `healthcheck:` | absent on long-running services | No recovery from a crash, and `depends_on: condition: service_healthy` cannot work | manual |
| C-08 | Resource limits | no `deploy.resources.limits` / `mem_limit` | One container can exhaust the host | manual |
| C-09 | Networks | every service on the default network | Flat network: the proxy can reach the database port directly | manual; define a `frontend` and a `backend` network |
| C-10 | Container hardening | no `user:`, no `read_only: true`, no `cap_drop: [ALL]`, no `security_opt: [no-new-privileges:true]` | The same hardening as K-02 to K-05, which Compose never applies by default | manual |

## Terraform and CloudFormation

AWS ids shown; trivy and checkov have equivalent families for Azure (`AZU-`, `CKV_AZURE_`)
and GCP (`GCP-`, `CKV_GCP_`). CloudFormation is scanned by the same two tools (not
exercised on a fixture here). Every row is a **declared** fact about one file: account
or organisation controls, other modules and manual changes can widen or narrow it.
When rules are built from variables, modules or `dynamic` blocks, ask the owner to
resolve them on their side and send back **only** the ports and CIDRs of the rules in
question. Never ask for the plan, the state or `terraform show -json`: that output
prints `sensitive` values in clear (seen on a throwaway plan: masked by `terraform
show`, readable with `-json`). Without the extract those resources are `UNKNOWN`.

| # | Check | Fails when | Why | Tool |
|---|---|---|---|---|
| T-01 | Public bucket | bucket `acl = "public-read"`; or a policy statement with `Effect = "Allow"`, `Principal = "*"`, `s3:ListBucket` or `s3:GetObject`, and no restricting condition | Report listing and reading apart: the bucket ACL lets anyone **list**; reading an object needs the object's own ACL or a `GetObject` grant. `Principal = "*"` under `Effect = "Deny"` (deny non-TLS access) grants nothing. Account-level Block Public Access can override all of it. A missing `aws_s3_bucket_public_access_block` alone is a **missing guardrail** (medium) | public ACL: trivy `AWS-0092`, checkov `CKV_AWS_20`. Missing block: trivy `AWS-0086`, `AWS-0087`, `AWS-0091`, `AWS-0093`, `AWS-0094`, checkov `CKV2_AWS_6`. Policies: manual |
| T-02 | Ingress from `0.0.0.0/0` on an admin port | 22 or 3389 open to the world | Brute force and exploit exposure | trivy `AWS-0107` (both), checkov `CKV_AWS_24` (22) and `CKV_AWS_25` (3389, seen on a throwaway rule) |
| T-03 | Ingress from `0.0.0.0/0` on a **data** port | 5432, 3306, 6379, 27017, 9200 open to the world | The database is declared open to the internet | **manual**. In the pinned versions trivy `AWS-0107` is titled "…unrestricted ingress to SSH or RDP" and fired on the fixture's port-22 rule only (line 19), not on the 5432 rule (line 27); checkov's `CKV_AWS_24` / `25` are per-port. Grep every `0.0.0.0/0` and `::/0` and justify each one |
| T-04 | Unrestricted egress | `egress` to `0.0.0.0/0` on all ports | No exfiltration control; acceptable only with a stated reason | trivy `AWS-0104`, checkov `CKV_AWS_382` |
| T-05 | Storage encryption | `storage_encrypted = false`, unencrypted EBS | Data readable from a snapshot or a decommissioned disk. For S3, new objects are encrypted with SSE-S3 by default since January 2023: `AWS-0132` / `CKV_AWS_145` ask for a customer-managed KMS key, a policy choice, not a sign of plaintext | trivy `AWS-0080`, `AWS-0132`; checkov `CKV_AWS_16`, `CKV_AWS_145` |
| T-06 | Database reachable publicly | `publicly_accessible = true` | A public endpoint plus one weak security group is a breach | trivy `AWS-0180`, checkov `CKV_AWS_17` |
| T-07 | IAM wildcards | `Action = "*"` with `Resource = "*"`, or `iam:*`, `s3:*` on `*` | `*` on `*` is account administration; `iam:*` leads to it; `s3:*` on `*` is full control of every bucket. What a principal can really do also depends on boundaries, SCPs and explicit denies | checkov `CKV_AWS_62`, `CKV_AWS_63`, `CKV_AWS_355`, `CKV2_AWS_40`, `CKV_AWS_286` to `290`; **trivy did not flag the `jsonencode` policy of the fixture** |
| T-08 | `iam:PassRole` / `sts:AssumeRole` on `*` | present | `PassRole` on `*` lets the holder hand any role to a service it can launch; `AssumeRole` on `*` works for every role whose **trust policy** accepts the caller: read the trust policies before rating | checkov `CKV_AWS_286`; manual review of trust policies |
| T-09 | Backups | `backup_retention_period = 0`, `skip_final_snapshot = true`, no deletion protection | A `terraform destroy` or a bad migration is unrecoverable | trivy `AWS-0077`, `AWS-0177`; checkov `CKV_AWS_133`, `CKV_AWS_293` |
| T-10 | Single AZ | `multi_az = false`, one subnet, one NAT gateway | A zone outage is a full outage | checkov `CKV_AWS_157`; NAT and subnets manual |
| T-11 | Logging | no flow logs, no bucket access logs, no database log export, no CloudTrail | An incident cannot be reconstructed | trivy `AWS-0089`, checkov `CKV_AWS_18` (bucket logging); checkov `CKV_AWS_129` (RDS log export). A missing trail cannot be flagged by a file scanner: look for an `aws_cloudtrail` resource; when one exists, checkov `CKV_AWS_67` and trivy `AWS-0014` check that it is multi-region (seen on a throwaway file) |
| T-12 | State and secrets | local state committed, `*.tfvars` with secrets, plaintext `password =` | The state file contains every secret in clear text | trivy secret scanner, manual: check the backend block (remote, encrypted, locked) |
| T-13 | Load balancer listeners | HTTP listener without redirect, `ssl_policy` older than TLS 1.2 | Clear-text traffic or legacy protocols at the edge | trivy `AWS-0054`, `AWS-0047` (from trivy's check list, not triggered by the fixture) |
| T-14 | Provider and module pinning | no `required_providers` version, modules from a branch | A plan of tomorrow changes without a code change | manual; tflint if available |
| T-15 | Instance metadata service | `aws_instance` / launch template without `metadata_options { http_tokens = "required" }` | With IMDSv1, one SSRF in the application reads the instance role's credentials | trivy `AWS-0028`, checkov `CKV_AWS_79` (seen on a throwaway file) |
| T-16 | CI federation trust (OIDC) | a role trusting `token.actions.githubusercontent.com` (or GitLab, Bitbucket) whose `sub` condition is absent or a wildcard such as `repo:*` or `repo:org/*` | Any repository, or any branch and pull request, can assume the deployment role | checkov `CKV_AWS_393` (seen on a throwaway file with `repo:*`); otherwise manual: expect `repo:<org>/<repo>:environment:<name>` or `:ref:refs/heads/main`, and a pinned `aud` |

Made-up example of a justified exception, to show what "justify each one" means: a
public `0.0.0.0/0` on 443 for the ALB of a public website is expected; write "443 on
`aws_security_group.alb`: public website entry point, in scope" in the report rather
than silently skipping it.

## CI/CD pipelines

No scanner of this skill parses pipeline semantics; trivy and checkov cover a few
GitHub Actions and GitLab rules, the rest is reading. Grep targets are given.

| # | Check | Fails when | Why | How to find it |
|---|---|---|---|---|
| P-01 | Third-party actions | `uses: owner/action@v3` or `@main` instead of a 40-hex commit SHA | A tag is mutable: in the tj-actions/changed-files compromise of March 2025 (CVE-2025-30066) existing tags were repointed to a commit that dumped CI secrets into build logs | grep `uses:` and flag every ref that is not `@[0-9a-f]{40}`. Not concerned: local actions (`uses: ./…`); `docker://` refs need `@sha256:` instead |
| P-02 | Token permissions | no `permissions:` block (GitHub), or `write-all` | The default token can push code or publish packages | grep `permissions:`; expect `contents: read` at the top and per-job additions |
| P-03 | `pull_request_target` or `workflow_run` checking out PR code | present | Untrusted code runs with secrets and a write token | grep `pull_request_target`, then look for `ref: ${{ github.event.pull_request.head` |
| P-04 | Script injection | `${{ github.event.* }}` (title, body, branch name) inside a `run:` block | Attacker-controlled text becomes shell | grep `run:` blocks for `github.event`, `github.head_ref` |
| P-05 | Secrets handling | secrets echoed, passed as CLI args, or written to artifacts; long-lived cloud keys in CI variables | Logs and artifacts are readable by more people than the secret store | `scan-iac.sh` `ci-grep` (echo/printf of a secret reference, `--password` / `--passwd` as an argument): it prints `path:line` and the rule only, never the line, which may hold a literal password. Do not grep these patterns by hand: grep prints the whole matching line into the transcript. Artifacts and CI variables: read by hand; prefer OIDC federation over static keys, then check its trust policy (T-16) |
| P-06 | Image provenance | images pushed by tag only, not signed, no SBOM or attestation | Nobody can prove what was built from which commit | look for `cosign sign`, `docker buildx --provenance --sbom`, digest pinning in deploy manifests |
| P-07 | Deployment gate | production deploy on every push, no environment protection or manual approval | One compromised or mistaken commit reaches production | read the deploy job's `environment:` / `when: manual` |
| P-08 | Self-hosted runners | used on public repositories, or shared between trust levels | A fork PR executes code on a machine inside the network | grep `runs-on: self-hosted` |
| P-09 | Scan steps | no image scan, no IaC scan, or scans with `continue-on-error: true` | Findings exist but block nothing | grep `trivy`, `continue-on-error`, `allow_failure` |
| P-10 | Pipeline image pinning | `image: node:latest` in GitLab/Bitbucket pipelines | As D-01, for the build environment | grep `image:` |

## Reading a scanner report without drowning

`scan-iac.sh --with-checkov` produced 274 raw hits on the 12-file fixture (146 without
checkov). Triage in this order:

1. **Deduplicate across tools**: a privileged container is one finding even if three
   tools report it. Group by object and defect, not by tool id.
2. **Sort by exposure, not by scanner severity**: a `LOW` on an internet-facing ingress
   outranks a `HIGH` on a batch job that no network path reaches. Use the topology map.
3. **Drop policy noise explicitly**: say which rules were ignored and why (for example
   "KSV-0125 trusted registries: the registry is private, accepted"). An unexplained
   silence looks like a miss.
4. **Keep the count honest**: report "274 raw scanner hits, 19 distinct findings after
   deduplication" (the 19 is a made-up number) rather than either number alone.
