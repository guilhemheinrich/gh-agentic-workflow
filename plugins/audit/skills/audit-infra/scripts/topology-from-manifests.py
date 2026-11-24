#!/usr/bin/env python3
"""Build a Mermaid topology graph from Kubernetes manifests and Compose files.

Standard library only (no PyYAML), meant to run in a container:

    docker run --rm -v "$PWD":/work:ro -v <skill>/scripts:/s:ro python:3.12-slim \
        python -I /s/topology-from-manifests.py /work/deploy [--json /dev/stdout] [--markdown]

What it draws (solid edge = declared, dashed edge = inferred from configuration):
  outside -> Ingress / HTTPRoute -> Service -> workload       (declared routing)
  outside -> Service of type LoadBalancer or NodePort         (declared exposure)
  outside -> Compose service with a published port            (declared exposure)
  service -.-> service, Compose `depends_on`                  (startup order, not traffic)
  workload -.-> Service, when an env value names it as a host (inferred dependency)
  workload -.-> external host found in an env URL             (inferred SaaS dependency)

It also emits topology-level findings that linters miss because they need the whole
graph: namespaces without any NetworkPolicy, datastores reachable from outside,
single-replica workloads, Ingress without TLS, Services selecting nothing.

The "outside" node (id `internet`) means "an entry point is DECLARED outside the cluster
or host". A manifest cannot say who can actually reach it: an internal load balancer, a
source-range restriction, a pending address or a firewall all stay invisible here. A
declared exposure becomes "reachable from the internet" only once observed from an
authorized vantage point or confirmed by the owner.

Helm charts and Kustomize overlays must be rendered first (`helm template`,
`kubectl kustomize`): a file this parser cannot read is skipped and listed on stderr.
"""
import argparse
import json
import os
import re
import sys

# --------------------------------------------------------------------------- YAML subset
# Block mappings and sequences, flow collections, quoted scalars, block scalars,
# multiple documents, anchors/aliases and merge keys. Enough for manifests and Compose
# files; not a general YAML parser (no tags semantics, no complex keys).


class YamlError(Exception):
    pass


_KEY = re.compile(r'''^(?P<k>"(?:[^"\\]|\\.)*"|'(?:[^']|'')*'|[^\s\[\]{},#&*!|>'"%@`-][^#]*?|-[^\s][^#]*?)\s*:(?:\s+(?P<v>.*))?$''')
_INT = re.compile(r"^[-+]?[0-9]+$")
_FLOAT = re.compile(r"^[-+]?([0-9]*\.[0-9]+|[0-9]+\.[0-9]*)([eE][-+]?[0-9]+)?$")


def _strip_comment(text):
    quote = None
    for i, ch in enumerate(text):
        if quote:
            if ch == quote:
                quote = None
        elif ch in "\"'":
            quote = ch
        elif ch == "#" and (i == 0 or text[i - 1] in " \t"):
            return text[:i].rstrip()
    return text.rstrip()


def _scalar(text):
    text = text.strip()
    if text == "":
        return None
    if len(text) >= 2 and text[0] == text[-1] == '"':
        try:
            return json.loads(text)
        except ValueError:
            return text[1:-1]
    if len(text) >= 2 and text[0] == text[-1] == "'":
        return text[1:-1].replace("''", "'")
    low = text.lower()
    if low in ("null", "~"):
        return None
    if low == "true":
        return True
    if low == "false":
        return False
    if _INT.match(text):
        return int(text)
    if _FLOAT.match(text):
        return float(text)
    return text


class _Flow:
    """Recursive-descent parser for flow collections: [a, b] and {a: 1, b: [x]}."""

    def __init__(self, text, anchors):
        self.s, self.i, self.anchors = text, 0, anchors

    def ws(self):
        while self.i < len(self.s) and self.s[self.i] in " \t\n":
            self.i += 1

    def value(self):
        self.ws()
        if self.i >= len(self.s):
            raise YamlError("unterminated flow collection")
        ch = self.s[self.i]
        if ch == "[":
            self.i += 1
            out = []
            while True:
                self.ws()
                if self.s[self.i : self.i + 1] == "]":
                    self.i += 1
                    return out
                out.append(self.value())
                self.ws()
                if self.s[self.i : self.i + 1] == ",":
                    self.i += 1
        if ch == "{":
            self.i += 1
            out = {}
            while True:
                self.ws()
                if self.s[self.i : self.i + 1] == "}":
                    self.i += 1
                    return out
                key = self.atom(":,}")
                self.ws()
                if self.s[self.i : self.i + 1] == ":":
                    self.i += 1
                    out[str(key)] = self.value()
                else:
                    out[str(key)] = None
                self.ws()
                if self.s[self.i : self.i + 1] == ",":
                    self.i += 1
        return self.atom(",]}")

    def atom(self, stops):
        self.ws()
        start = self.i
        if self.s[self.i : self.i + 1] in ('"', "'"):
            quote = self.s[self.i]
            self.i += 1
            while self.i < len(self.s) and self.s[self.i] != quote:
                self.i += 2 if (quote == '"' and self.s[self.i] == "\\") else 1
            self.i += 1
            return _scalar(self.s[start : self.i])
        while self.i < len(self.s) and self.s[self.i] not in stops:
            # "a: b" inside a flow mapping: the colon only ends the key when a space follows
            if self.s[self.i] == ":" and ":" in stops and self.s[self.i + 1 : self.i + 2] not in (" ", ""):
                self.i += 1
                continue
            self.i += 1
        if self.i > len(self.s) or start == self.i and self.i >= len(self.s):
            raise YamlError("unterminated flow collection")
        token = self.s[start : self.i].strip()
        if token.startswith("*"):
            return self.anchors.get(token[1:])
        return _scalar(token)


class _Doc:
    def __init__(self, raw_lines):
        self.raw = raw_lines
        self.n = len(raw_lines)
        self.anchors = {}

    # -- line access ------------------------------------------------------------------
    def peek(self, i):
        """Index, indent and content of the next meaningful line at or after i."""
        while i < self.n:
            raw = self.raw[i]
            stripped = _strip_comment(raw.replace("\t", "  "))
            if stripped.strip():
                return i, len(stripped) - len(stripped.lstrip(" ")), stripped.strip()
            i += 1
        return self.n, -1, ""

    # -- values -------------------------------------------------------------------------
    def parse(self):
        i, indent, _ = self.peek(0)
        if i >= self.n:
            return None
        value, end = self.block(i, indent)
        rest, _, text = self.peek(end)
        if rest < self.n:
            # Never return a silently truncated document: the caller skips the file instead.
            raise YamlError("unsupported YAML near line %d: %s" % (rest + 1, text[:60]))
        return value

    def block(self, i, indent):
        i, ind, text = self.peek(i)
        if text == "-" or text.startswith("- "):
            return self.sequence(i, ind)
        if _KEY.match(text):
            return self.mapping(i, ind)
        value, j = self.inline(text, i, ind)
        return value, j

    def sequence(self, i, indent):
        out = []
        while True:
            j, ind, text = self.peek(i)
            if j >= self.n or ind != indent or not (text == "-" or text.startswith("- ")):
                return out, j
            rest = text[1:].strip()
            if rest == "":
                k, kind, _ = self.peek(j + 1)
                if k < self.n and kind > indent:
                    value, i = self.block(k, kind)
                else:
                    value, i = None, j + 1
            elif rest == "-" or rest.startswith("- "):
                # "- - x" opens a nested sequence aligned with the inner dash.
                offset = indent + (len(text) - len(text[1:].lstrip(" ")))
                self.raw[j] = " " * offset + rest
                value, i = self.sequence(j, offset)
            elif _KEY.match(rest) and not rest.startswith(("[", "{", '"', "'")) or re.match(r'^["\'][^"\']*["\']\s*:(\s|$)', rest):
                # "- name: x" opens a mapping whose keys align with `name`.
                offset = indent + (len(text) - len(text[1:].lstrip(" ")))
                self.raw[j] = " " * offset + rest
                value, i = self.mapping(j, offset)
            else:
                value, i = self.inline(rest, j, indent)
            out.append(value)

    def mapping(self, i, indent):
        out = {}
        while True:
            j, ind, text = self.peek(i)
            if j >= self.n or ind != indent:
                return out, j
            m = _KEY.match(text)
            if not m:
                return out, j
            key = _scalar(m.group("k"))
            rest = (m.group("v") or "").strip()
            anchor = None
            am = re.match(r"^&([^\s]+)\s*(.*)$", rest)
            if am:
                anchor, rest = am.group(1), am.group(2).strip()
            tm = re.match(r"^!+[^\s]*\s*(.*)$", rest)
            if tm:
                rest = tm.group(1).strip()
            if rest == "":
                k, kind, ktext = self.peek(j + 1)
                if k < self.n and kind > indent:
                    value, i = self.block(k, kind)
                elif k < self.n and kind == indent and (ktext == "-" or ktext.startswith("- ")):
                    value, i = self.sequence(k, kind)
                else:
                    value, i = None, j + 1
            else:
                value, i = self.inline(rest, j, indent)
            if anchor:
                self.anchors[anchor] = value
            if key == "<<":
                for part in value if isinstance(value, list) else [value]:
                    if isinstance(part, dict):
                        for pk, pv in part.items():
                            out.setdefault(pk, pv)
            else:
                out[str(key)] = value

    def inline(self, text, line, indent):
        """A value that starts on `line`: flow collection, block scalar, alias or scalar."""
        if text[:1] in "[{":
            buf, j = text, line
            while buf.count("[") + buf.count("{") > buf.count("]") + buf.count("}"):
                j += 1
                if j >= self.n:
                    raise YamlError("unterminated flow collection at line %d" % (line + 1))
                buf += " " + _strip_comment(self.raw[j]).strip()
            return _Flow(buf, self.anchors).value(), j + 1
        if re.match(r"^[|>][+-]?[0-9]?$", text):
            lines, j = [], line + 1
            while j < self.n:
                raw = self.raw[j]
                if raw.strip() and (len(raw) - len(raw.lstrip(" "))) <= indent:
                    break
                lines.append(raw.rstrip())
                j += 1
            while lines and not lines[-1]:
                lines.pop()
            margin = min((len(x) - len(x.lstrip(" ")) for x in lines if x), default=0)
            lines = [x[margin:] for x in lines]
            body = "\n".join(lines) if text[0] == "|" else " ".join(x.strip() for x in lines)
            return body + ("" if "-" in text or not body else "\n"), j
        if text.startswith("*") and re.match(r"^\*[^\s]+$", text):
            return self.anchors.get(text[1:]), line + 1
        # Plain scalar, possibly continued on more-indented lines.
        value, j = text, line + 1
        if text[:1] not in "\"'":
            while True:
                k, kind, ktext = self.peek(j)
                if k >= self.n or kind <= indent or _KEY.match(ktext) or ktext.startswith("- "):
                    break
                value += " " + ktext
                j = k + 1
        return _scalar(value), j


def load_yaml_documents(text):
    docs, current = [], []
    for line in text.splitlines():
        if line.startswith("---") and line[3:4] in ("", " ", "\t"):
            docs.append(current)
            current = []
        elif line.strip() == "...":
            continue
        else:
            current.append(line)
    docs.append(current)
    out = []
    for lines in docs:
        value = _Doc(lines).parse()
        if value is not None:
            out.append(value)
    return out


# --------------------------------------------------------------------------- model

DATASTORES = [
    ("postgres", "db"), ("postgis", "db"), ("timescale", "db"), ("mysql", "db"), ("mariadb", "db"),
    ("mongo", "db"), ("cockroach", "db"), ("cassandra", "db"), ("clickhouse", "db"), ("mssql", "db"),
    ("elasticsearch", "db"), ("opensearch", "db"), ("influxdb", "db"), ("etcd", "db"), ("minio", "db"),
    ("redis", "cache"), ("valkey", "cache"), ("memcached", "cache"), ("dragonfly", "cache"),
    ("rabbitmq", "queue"), ("kafka", "queue"), ("redpanda", "queue"), ("nats", "queue"),
    ("activemq", "queue"), ("pulsar", "queue"),
]
WORKLOAD_KINDS = ("Deployment", "StatefulSet", "DaemonSet", "ReplicaSet", "Job", "CronJob", "Pod")
URL_HOST = re.compile(r"[a-z][a-z0-9+.-]*://(?:[^@/\s]*@)?([A-Za-z0-9.-]+)")
BARE_FQDN = re.compile(r"^(?:[a-z0-9-]+\.)+[a-z]{2,}(?::[0-9]+)?$", re.I)


def classify(image):
    name = (image or "").lower().rsplit("@", 1)[0]
    base = name.rsplit("/", 1)[-1].split(":")[0]
    for needle, role in DATASTORES:
        if needle in base:
            return role
    return "app"


def unpinned(image):
    if not image or "@sha256:" in image:
        return False
    tag = image.rsplit("/", 1)[-1].split(":", 1)
    return len(tag) == 1 or tag[1] == "latest"


def as_list(value):
    if value is None:
        return []
    return value if isinstance(value, list) else [value]


def as_dict(value):
    return value if isinstance(value, dict) else {}


class Graph:
    def __init__(self):
        self.nodes, self.edges, self.findings = {}, [], []

    def node(self, nid, label, zone, shape="box"):
        self.nodes.setdefault(nid, {"id": nid, "label": label, "zone": zone, "shape": shape})
        return nid

    def edge(self, src, dst, label="", inferred=False):
        item = {"from": src, "to": dst, "label": label, "inferred": inferred}
        if src != dst and item not in self.edges:
            self.edges.append(item)

    def finding(self, fid, severity, obj, message):
        self.findings.append({"id": fid, "severity": severity, "object": obj, "message": message})


def nid(*parts):
    return re.sub(r"[^A-Za-z0-9_]", "_", "_".join(str(p) for p in parts))


# --------------------------------------------------------------------------- Kubernetes


def pod_spec(obj):
    kind, spec = obj.get("kind"), as_dict(obj.get("spec"))
    if kind == "Pod":
        return spec, as_dict(as_dict(obj.get("metadata")).get("labels"))
    if kind == "CronJob":
        spec = as_dict(as_dict(spec.get("jobTemplate")).get("spec"))
    template = as_dict(spec.get("template"))
    return as_dict(template.get("spec")), as_dict(as_dict(template.get("metadata")).get("labels"))


def env_strings(containers, configmaps, namespace):
    out = []
    for c in containers:
        for e in as_list(c.get("env")):
            if isinstance(e, dict) and isinstance(e.get("value"), (str, int)):
                out.append((str(e.get("name")), str(e["value"])))
        for arg in as_list(c.get("args")) + as_list(c.get("command")):
            if isinstance(arg, str):
                out.append(("arg", arg))
        for ref in as_list(c.get("envFrom")):
            name = as_dict(as_dict(ref).get("configMapRef")).get("name")
            for k, v in as_dict(configmaps.get((namespace, name))).items():
                if isinstance(v, (str, int)):
                    out.append((str(k), str(v)))
    return out


def add_kubernetes(graph, objects):
    services, workloads, configmaps, service_meta = {}, [], {}, {}
    netpol_ns, pdb_selectors, hpa_targets, ns_seen = set(), [], set(), set()

    for obj in objects:
        meta = as_dict(obj.get("metadata"))
        ns = meta.get("namespace") or "default"
        kind, name = obj.get("kind"), meta.get("name")
        spec = as_dict(obj.get("spec"))
        if kind == "ConfigMap":
            configmaps[(ns, name)] = as_dict(obj.get("data"))
        elif kind == "NetworkPolicy":
            netpol_ns.add(ns)
        elif kind == "PodDisruptionBudget":
            pdb_selectors.append((ns, as_dict(as_dict(spec.get("selector")).get("matchLabels"))))
        elif kind == "HorizontalPodAutoscaler":
            hpa_targets.add((ns, as_dict(spec.get("scaleTargetRef")).get("name")))
        elif kind == "Service":
            services[(ns, name)] = spec
            service_meta[(ns, name)] = as_dict(meta.get("annotations"))

    for obj in objects:
        kind = obj.get("kind")
        if kind not in WORKLOAD_KINDS:
            continue
        meta = as_dict(obj.get("metadata"))
        ns, name = meta.get("namespace") or "default", meta.get("name")
        ns_seen.add(ns)
        pspec, labels = pod_spec(obj)
        containers = [c for c in as_list(pspec.get("containers")) + as_list(pspec.get("initContainers")) if isinstance(c, dict)]
        images = [c.get("image") for c in containers if c.get("image")]
        role = next((r for r in (classify(i) for i in images) if r != "app"), "app")
        replicas = as_dict(obj.get("spec")).get("replicas")
        if replicas is None and kind in ("Deployment", "StatefulSet"):
            replicas = 1
        count = "" if replicas is None else " x%s" % replicas
        wid = graph.node(nid("wl", ns, name), "%s%s<br/>%s/%s" % (name, count, ns, kind),
                         "data" if role != "app" else "services",
                         {"db": "cylinder", "cache": "cylinder", "queue": "queue"}.get(role, "box"))
        workloads.append({"id": wid, "ns": ns, "name": name, "kind": kind, "labels": labels, "role": role,
                          "replicas": replicas, "env": env_strings(containers, configmaps, ns),
                          "images": images})
        if kind in ("Deployment", "StatefulSet") and replicas == 1 and (ns, name) not in hpa_targets:
            graph.finding("T-K8S-03", "medium", "%s/%s/%s" % (ns, kind, name),
                          "single replica and no HorizontalPodAutoscaler: one pod loss or node drain is an outage (SPOF)")
        if kind in ("Deployment", "StatefulSet") and (replicas or 0) > 1 and not any(
                pns == ns and sel and all(labels.get(k) == v for k, v in sel.items()) for pns, sel in pdb_selectors):
            graph.finding("T-K8S-07", "low", "%s/%s/%s" % (ns, kind, name),
                          "%s replicas but no PodDisruptionBudget: a node drain may evict them all at once" % replicas)
        for image in images:
            if unpinned(image):
                graph.finding("T-K8S-08", "medium", "%s/%s/%s" % (ns, kind, name),
                              "image '%s' is not pinned (no tag, or latest): deploys are not reproducible" % image)

    def targets(ns, svc_name):
        spec = services.get((ns, svc_name))
        selector = as_dict(as_dict(spec).get("selector"))
        if not selector:
            return []
        return [w for w in workloads if w["ns"] == ns and all(w["labels"].get(k) == v for k, v in selector.items())]

    exposed_services = set()
    restricted = {}
    internet = None

    for (ns, name), spec in services.items():
        stype = spec.get("type") or "ClusterIP"
        ports = ",".join(str(as_dict(p).get("port")) for p in as_list(spec.get("ports")))
        sid = graph.node(nid("svc", ns, name), "svc %s:%s<br/>%s/%s" % (name, ports, ns, stype),
                         "edge" if stype in ("LoadBalancer", "NodePort") else "services", "round")
        if stype == "ExternalName":
            ext = graph.node(nid("ext", spec.get("externalName")), str(spec.get("externalName")), "external", "round")
            graph.edge(sid, ext, "ExternalName")
            continue
        matched = targets(ns, name)
        for w in matched:
            graph.edge(sid, w["id"], "selector")
        if as_dict(spec.get("selector")) and not matched:
            graph.finding("T-K8S-06", "low", "%s/Service/%s" % (ns, name),
                          "selector %s matches no workload in these manifests (dangling Service, or workload defined elsewhere)"
                          % json.dumps(spec.get("selector"), sort_keys=True))
        if stype in ("LoadBalancer", "NodePort"):
            internet = graph.node("internet", "Outside<br/>(declared, not probed)", "outside", "circle")
            # Hints that the entry is not open to everyone. They are read, never trusted
            # blindly: the annotation may not be the one the cloud controller honours.
            internal = any("internal" in str(k).lower() and str(v).lower() not in ("false", "0", "")
                           for k, v in service_meta.get((ns, name), {}).items())
            ranges = as_list(spec.get("loadBalancerSourceRanges"))
            limits = []
            if internal:
                limits.append("an internal-load-balancer annotation is set")
            if ranges:
                limits.append("loadBalancerSourceRanges = %s" % ",".join(str(r) for r in ranges))
            restricted[(ns, name)] = bool(limits)
            graph.edge(internet, sid, "%s %s%s" % (stype, ports, " (restricted?)" if limits else ""))
            exposed_services.add((ns, name))
            graph.finding("T-K8S-02", "medium", "%s/Service/%s" % (ns, name),
                          "type %s declares an entry point outside the cluster for port(s) %s, bypassing any Ingress, "
                          "WAF or TLS termination; %s. Reachability from the internet is NOT verified by this tool"
                          % (stype, ports, "; ".join(limits) if limits else
                             "no internal-LB annotation and no loadBalancerSourceRanges in the manifest"))

    for obj in objects:
        kind = obj.get("kind")
        meta = as_dict(obj.get("metadata"))
        ns, name = meta.get("namespace") or "default", meta.get("name")
        spec = as_dict(obj.get("spec"))
        routes = []  # (host, path, service)
        if kind == "Ingress":
            default = as_dict(spec.get("defaultBackend"))
            if default:
                routes.append(("*", "/", as_dict(default.get("service")).get("name") or default.get("serviceName")))
            for rule in as_list(spec.get("rules")):
                rule = as_dict(rule)
                for path in as_list(as_dict(rule.get("http")).get("paths")):
                    backend = as_dict(as_dict(path).get("backend"))
                    svc = as_dict(backend.get("service")).get("name") or backend.get("serviceName")
                    routes.append((rule.get("host") or "*", as_dict(path).get("path") or "/", svc))
            if not spec.get("tls"):
                graph.finding("T-K8S-04", "high", "%s/Ingress/%s" % (ns, name),
                              "no `tls` section: no certificate is declared for hosts %s; clear text, or the controller's "
                              "default certificate, unless TLS terminates upstream (not verified by this tool)"
                              % sorted({r[0] for r in routes}))
        elif kind == "HTTPRoute":
            hosts = as_list(spec.get("hostnames")) or ["*"]
            for rule in as_list(spec.get("rules")):
                for ref in as_list(as_dict(rule).get("backendRefs")):
                    routes.append((",".join(str(h) for h in hosts), "/", as_dict(ref).get("name")))
        else:
            continue
        internet = graph.node("internet", "Outside<br/>(declared, not probed)", "outside", "circle")
        hosts = sorted({r[0] for r in routes})
        iid = graph.node(nid("ing", ns, name), "%s %s<br/>%s" % (kind, name, ", ".join(hosts)), "edge", "hex")
        if kind == "Ingress":
            proto = "HTTPS (tls declared)" if spec.get("tls") else "HTTP (no tls declared)"
        else:
            proto = "protocol UNKNOWN (Gateway listener not read)"
        graph.edge(internet, iid, proto)
        for _host, path, svc in routes:
            if not svc:
                continue
            sid = graph.node(nid("svc", ns, svc), "svc %s<br/>%s (not in manifests)" % (svc, ns), "services", "round")
            graph.edge(iid, sid, path)
            exposed_services.add((ns, svc))

    for ns, svc in sorted(exposed_services):
        for w in targets(ns, svc):
            if w["role"] != "app":
                graph.finding("T-K8S-05", "medium" if restricted.get((ns, svc)) else "high",
                              "%s/%s/%s" % (w["ns"], w["kind"], w["name"]),
                              "datastore declared exposed outside the cluster through Service '%s'%s: "
                              "reachability is UNKNOWN until observed from an authorized vantage point or "
                              "confirmed by the owner" % (svc, " (source restriction declared)" if restricted.get((ns, svc)) else ""))

    # Inferred dependencies: a Service name used as a host in an env value, arg or ConfigMap.
    for w in workloads:
        own = {name for (ns, name) in services if ns == w["ns"] and w in targets(ns, name)}
        for key, value in w["env"]:
            for (sns, sname), _spec in services.items():
                if sname in own and sns == w["ns"]:
                    continue
                pattern = r"(?:^|[/@=\s,;])%s(\.%s(\.svc(\.cluster\.local)?)?)?(?=$|[:/\s,;?])" % (re.escape(sname), re.escape(sns))
                m = re.search(pattern, value)
                if not m or (sns != w["ns"] and not m.group(1)):
                    continue
                graph.edge(w["id"], nid("svc", sns, sname), key, inferred=True)
            hosts = set(URL_HOST.findall(value))
            if BARE_FQDN.match(value):
                hosts.add(value.split(":")[0])
            for host in hosts:
                if "." not in host or host.endswith((".svc", ".local", ".internal")) or re.match(r"^[0-9.]+$", host):
                    continue
                if any(host in (s, "%s.%s" % (s, n)) or host.startswith("%s.%s." % (s, n)) for (n, s) in services):
                    continue
                ext = graph.node(nid("ext", host), host, "external", "round")
                graph.edge(w["id"], ext, key, inferred=True)

    for ns in sorted(ns_seen - netpol_ns):
        graph.finding("T-K8S-01", "high", "namespace/%s" % ns,
                      "no NetworkPolicy selects this namespace: every pod accepts traffic from every pod of the cluster (flat network)")


# --------------------------------------------------------------------------- Compose


def add_compose(graph, doc, source):
    project = os.path.basename(os.path.dirname(source)) or "compose"
    services = as_dict(doc.get("services"))
    ids = {}
    for name, svc in services.items():
        svc = as_dict(svc)
        image = svc.get("image") or ("build:%s" % (as_dict(svc.get("build")).get("context") or svc.get("build") or "."))
        role = classify(image)
        ids[name] = graph.node(nid("cmp", project, name), "%s<br/>%s" % (name, image),
                               "data" if role != "app" else "services",
                               {"db": "cylinder", "cache": "cylinder", "queue": "queue"}.get(role, "box"))
    for name, svc in services.items():
        svc, me = as_dict(svc), ids[name]
        obj = "%s:%s" % (os.path.basename(source), name)
        image = svc.get("image")
        role = classify(image or "")
        for port in as_list(svc.get("ports")):
            if isinstance(port, dict):
                host_ip, published = port.get("host_ip") or "0.0.0.0", port.get("published")
            else:
                parts = str(port).split("/")[0].rsplit(":", 2)
                if len(parts) == 1:
                    continue  # container port only: random host port, not a stable exposure
                host_ip, published = (parts[0], parts[1]) if len(parts) == 3 else ("0.0.0.0", parts[0])
            local = host_ip in ("127.0.0.1", "::1", "localhost", "[::1]")
            if local:
                host = graph.node("localhost", "Host loopback", "outside", "circle")
                graph.edge(host, me, "127.0.0.1:%s" % published)
                continue
            internet = graph.node("internet", "Outside<br/>(declared, not probed)", "outside", "circle")
            graph.edge(internet, me, "%s:%s" % (host_ip, published))
            if role != "app":
                graph.finding("T-CMP-01", "high", obj,
                              "datastore port %s published on %s: reachable from every network the host is on "
                              "(Docker bypasses ufw-style host firewalls); internet reachability depends on the "
                              "host's network and is NOT verified by this tool" % (published, host_ip))
        if svc.get("privileged") is True:
            graph.finding("T-CMP-02", "high", obj, "privileged: true gives the container full access to the host kernel and devices")
        if svc.get("network_mode") == "host":
            graph.finding("T-CMP-02", "high", obj, "network_mode: host removes network isolation")
        for volume in as_list(svc.get("volumes")):
            src = volume.get("source") if isinstance(volume, dict) else str(volume).split(":")[0]
            if src and "docker.sock" in str(src):
                graph.finding("T-CMP-03", "critical", obj, "mounts the Docker socket: equivalent to root on the host")
        if image and unpinned(image):
            graph.finding("T-CMP-04", "medium", obj, "image '%s' is not pinned (no tag, or latest)" % image)
        depends = svc.get("depends_on")
        for dep in depends if isinstance(depends, (list, dict)) else []:
            if dep in ids:
                # Startup ordering, not observed traffic: drawn dashed like every inference.
                graph.edge(me, ids[dep], "depends_on (startup order)", inferred=True)
        env = svc.get("environment")
        pairs = []
        if isinstance(env, dict):
            pairs = [(str(k), str(v)) for k, v in env.items() if v is not None]
        elif isinstance(env, list):
            pairs = [tuple(str(e).split("=", 1)) for e in env if "=" in str(e)]
        for key, value in pairs:
            for other in services:
                if other != name and re.search(r"(?:^|[/@=\s,;])%s(?=$|[:/\s,;?])" % re.escape(other), value):
                    graph.edge(me, ids[other], key, inferred=True)
            for host in set(URL_HOST.findall(value)):
                if "." in host and host not in services and not re.match(r"^[0-9.]+$", host):
                    graph.edge(me, graph.node(nid("ext", host), host, "external", "round"), key, inferred=True)


# --------------------------------------------------------------------------- output

ZONES = [("outside", "Outside"), ("edge", "Edge: entry points"), ("services", "Services"),
         ("data", "Data: databases, caches, queues"), ("external", "External dependencies")]
SHAPES = {"box": '["%s"]', "round": '("%s")', "cylinder": '[("%s")]', "queue": '[["%s"]]',
          "hex": '{{"%s"}}', "circle": '(("%s"))'}


def mermaid(graph):
    def esc(text):
        return str(text).replace('"', "#quot;")

    # Declared and inferred edges between the same pair collapse into one line each.
    merged = {}
    for e in graph.edges:
        key = (e["from"], e["to"], e["inferred"])
        merged.setdefault(key, [])
        if e["label"] and e["label"] not in merged[key]:
            merged[key].append(e["label"])
    lines = ["flowchart LR"]
    for zone, title in ZONES:
        members = [n for n in graph.nodes.values() if n["zone"] == zone]
        if not members:
            continue
        lines.append('  subgraph %s["%s"]' % (zone, title))
        for n in sorted(members, key=lambda n: n["id"]):
            lines.append("    %s%s" % (n["id"], SHAPES[n["shape"]] % esc(n["label"])))
        lines.append("  end")
    for (src, dst, inferred), labels in merged.items():
        if (src, dst, False) in merged and inferred:
            continue  # a declared edge already says it
        arrow = "-.->" if inferred else "-->"
        label = '|"%s"|' % esc(", ".join(labels[:3])) if labels else ""
        lines.append("  %s %s%s %s" % (src, arrow, label, dst))
    exposed = sorted({e["to"] for e in graph.edges if e["from"] == "internet"})
    if exposed:
        lines.append("  classDef exposed stroke:#c0392b,stroke-width:3px")
        lines.append("  class %s exposed" % ",".join(exposed))
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("path", help="directory (or file) holding rendered manifests and Compose files")
    ap.add_argument("--json", metavar="FILE", help="also write nodes, edges and findings as JSON")
    ap.add_argument("--markdown", action="store_true", help="wrap the graph in a ```mermaid fence and append findings")
    args = ap.parse_args()

    files = []
    if os.path.isfile(args.path):
        files = [args.path]
    for root, dirs, names in os.walk(args.path):
        dirs[:] = sorted(d for d in dirs if d not in (".git", "node_modules", "vendor", ".terraform"))
        files += [os.path.join(root, n) for n in sorted(names) if n.endswith((".yaml", ".yml"))]

    graph, k8s_objects, skipped, read = Graph(), [], [], []
    for path in files:
        try:
            with open(path, encoding="utf-8") as handle:
                text = handle.read()
            code = "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("#"))
            if re.search(r"\{\{-?\s*(\.|\$|if|range|include|template|toYaml|with|define)", code):
                skipped.append((path, "Helm template: render it with `helm template` first"))
                continue
            docs = load_yaml_documents(text)
        except (YamlError, RecursionError, IndexError, KeyError, TypeError, ValueError, OSError) as exc:
            skipped.append((path, "%s: %s" % (type(exc).__name__, exc)))
            continue
        used = False
        for doc in docs:
            if not isinstance(doc, dict):
                continue
            if doc.get("kind") == "List" and isinstance(doc.get("items"), list):
                items = [d for d in doc["items"] if isinstance(d, dict)]
                k8s_objects += items
                used = used or bool(items)
            elif "apiVersion" in doc and "kind" in doc:
                k8s_objects.append(doc)
                used = True
            elif isinstance(doc.get("services"), dict) and "kind" not in doc:
                add_compose(graph, doc, path)
                used = True
        if used:
            read.append(path)
    add_kubernetes(graph, k8s_objects)

    order = {"critical": 0, "high": 1, "medium": 2, "low": 3}
    graph.findings.sort(key=lambda f: (order.get(f["severity"], 9), f["id"], f["object"]))
    chart = mermaid(graph)
    for path, why in skipped:
        print("skipped %s (%s)" % (path, why), file=sys.stderr)
    print("read %d file(s), %d Kubernetes object(s), %d node(s), %d edge(s), %d finding(s), %d skipped"
          % (len(read), len(k8s_objects), len(graph.nodes), len(graph.edges), len(graph.findings), len(skipped)),
          file=sys.stderr)
    if args.json:
        with open(args.json, "w", encoding="utf-8") as handle:
            json.dump({"files": read, "skipped": [{"file": p, "reason": w} for p, w in skipped],
                       "nodes": list(graph.nodes.values()), "edges": graph.edges,
                       "findings": graph.findings}, handle, indent=2)
            handle.write("\n")
    if args.markdown:
        print("```mermaid\n%s\n```\n" % chart)
        print("| Severity | Id | Object | Finding |\n|---|---|---|---|")
        for f in graph.findings:
            print("| %s | %s | `%s` | %s |" % (f["severity"], f["id"], f["object"], f["message"]))
    else:
        print(chart)
    return 0 if graph.nodes else 1


if __name__ == "__main__":
    sys.exit(main())
