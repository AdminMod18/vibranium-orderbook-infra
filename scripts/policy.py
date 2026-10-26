#!/usr/bin/env python3
"""Políticas mínimas que debe cumplir cada ambiente (falla con exit 1 y explica qué y dónde)."""
import sys
import yaml

env, path = sys.argv[1], sys.argv[2]
docs = [d for d in yaml.safe_load_all(open(path)) if d]
errors = []

def pods(doc):
    spec = doc.get("spec", {})
    if doc["kind"] in ("Deployment", "StatefulSet"):
        return spec["template"]["spec"]
    return None

for d in docs:
    name = f'{d["kind"]}/{d["metadata"]["name"]}'
    ps = pods(d)
    if ps is None:
        continue
    sc = ps.get("securityContext", {})
    if not sc.get("runAsNonRoot"):
        errors.append(f"{name}: falta securityContext.runAsNonRoot")
    for c in ps["containers"]:
        cn = f'{name}:{c["name"]}'
        img = c["image"]
        tag = img.rsplit(":", 1)[1] if ":" in img.rsplit("/", 1)[-1] else ""
        if tag in ("", "latest"):
            errors.append(f"{cn}: imagen sin versión fija ({img})")
        if env == "prod" and tag in ("main", "dev"):
            errors.append(f"{cn}: prod exige una versión inmutable, no '{tag}'")
        if "requests" not in c.get("resources", {}) or "memory" not in c.get("resources", {}).get("limits", {}):
            errors.append(f"{cn}: faltan resources.requests o limits.memory")
        if "readinessProbe" not in c:
            errors.append(f"{cn}: falta readinessProbe")
        s = c.get("securityContext", {})
        if s.get("allowPrivilegeEscalation") is not False or "ALL" not in s.get("capabilities", {}).get("drop", []):
            errors.append(f"{cn}: debe fijar allowPrivilegeEscalation=false y drop ALL")
    if d["metadata"]["name"] == "orderbook":
        c = ps["containers"][0]
        for p in ("startupProbe", "livenessProbe"):
            if p not in c:
                errors.append(f"{name}: el escritor necesita {p}")
        if d["spec"]["replicas"] != 1:
            errors.append(f"{name}: el escritor es de UN solo escritor (replicas debe ser 1)")

for d in docs:
    if d["kind"] in ("RoleBinding", "ClusterRoleBinding"):
        for sub in d.get("subjects", []):
            if sub.get("kind") == "ServiceAccount" and sub.get("namespace") != f"vibranium-{env}":
                errors.append(f'{d["kind"]}/{d["metadata"]["name"]}: el sujeto {sub["name"]} apunta al namespace {sub.get("namespace")!r}, no a vibranium-{env}')

kinds = {(d["kind"], d["metadata"]["name"]) for d in docs}
if not any(k == "NetworkPolicy" for k, _ in kinds):
    errors.append("faltan NetworkPolicy")
if env != "local" and any(k == "Secret" for k, _ in kinds):
    errors.append("un ambiente no-local no debe llevar Secret en git (use scripts/create-secret.sh)")

if errors:
    print(f"[{env}] POLÍTICAS INCUMPLIDAS:")
    for e in errors:
        print("  -", e)
    sys.exit(1)
print(f"[{env}] políticas OK ({len(docs)} objetos)")
