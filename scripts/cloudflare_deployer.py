"""Reuse the workspace's established Cloudflare Pages API deployer.

The other Asodya web projects keep one implementation of the Pages upload
protocol. This adapter lets reports use the same implementation without
requiring Wrangler or Node.js on the deployment machine.
"""
from __future__ import annotations

import importlib.util
import json
import os
import time
from pathlib import Path
from urllib.request import Request, urlopen


def _load_deployer():
    candidates = (
        Path(__file__).resolve().parents[2] / "domain" / "scripts" / "cloudflare_deployer.py",
        Path(__file__).resolve().parents[2] / "certifications" / "scripts" / "cloudflare_deployer.py",
    )
    for path in candidates:
        if path.is_file() and path.resolve() != Path(__file__).resolve():
            spec = importlib.util.spec_from_file_location("asodya_shared_cloudflare_deployer", path)
            if spec is None or spec.loader is None:
                continue
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            return module
    raise RuntimeError("Could not find the shared Asodya Cloudflare Pages deployer.")


_shared = _load_deployer()


def _cloudflare_request(method: str, path: str, payload: dict | None = None) -> dict:
    account_email = os.environ["CLOUDFLARE_EMAIL"]
    api_key = os.environ["CLOUDFLARE_API_KEY"]
    body = json.dumps(payload).encode() if payload is not None else None
    headers = {
        "X-Auth-Email": account_email,
        "X-Auth-Key": api_key,
        "Content-Type": "application/json",
    }
    request = Request(
        f"https://api.cloudflare.com/client/v4{path}",
        data=body,
        headers=headers,
        method=method,
    )
    with urlopen(request, timeout=30) as response:
        result = json.loads(response.read().decode("utf-8"))
    if not result.get("success"):
        raise RuntimeError(f"Cloudflare API request failed: {method} {path}")
    return result


def _ensure_pages_dns(project_name: str, custom_domain: str, *, proxied: bool) -> None:
    if "." not in custom_domain:
        raise RuntimeError(f"Custom domain is not a DNS name: {custom_domain}")

    zone_name = custom_domain.split(".", 1)[1]
    zones = _cloudflare_request("GET", f"/zones?name={zone_name}&status=active")["result"]
    if not zones:
        raise RuntimeError(f"Cloudflare zone not found for {custom_domain}")
    zone_id = zones[0]["id"]
    target = f"{project_name}.pages.dev"
    records = _cloudflare_request(
        "GET", f"/zones/{zone_id}/dns_records?name={custom_domain}"
    )["result"]
    payload = {
        "type": "CNAME",
        "name": custom_domain,
        "content": target,
        "ttl": 1,
        "proxied": proxied,
    }
    if records:
        record = records[0]
        if record["type"] != "CNAME" or record["content"] != target or not record.get("proxied"):
            _cloudflare_request("PUT", f"/zones/{zone_id}/dns_records/{record['id']}", payload)
    else:
        _cloudflare_request("POST", f"/zones/{zone_id}/dns_records", payload)
    print(f"DNS ensured: {custom_domain} -> {target} (proxied={proxied})")


def _wait_for_pages_domain(project_name: str, custom_domain: str, timeout: int = 90) -> bool:
    endpoint = f"/accounts/{os.environ['CLOUDFLARE_ACCOUNT_ID']}/pages/projects/{project_name}/domains"
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        domains = _cloudflare_request("GET", endpoint)["result"]
        match = next((d for d in domains if d.get("name") == custom_domain), None)
        if match and match.get("status") == "active":
            return True
        time.sleep(5)
    return False


def deploy_pages_project(project_name, build_dir, custom_domain=None, branch="main", timestamp_str=None):
    if custom_domain:
        # Pages must see an unproxied CNAME while it provisions/verifies its
        # certificate. Proxy it only after the custom domain becomes active.
        _ensure_pages_dns(project_name, custom_domain, proxied=False)
    _deploy_assets(
        project_name,
        build_dir,
        custom_domain=custom_domain,
        branch=branch,
        timestamp_str=timestamp_str,
    )
    if custom_domain:
        if _wait_for_pages_domain(project_name, custom_domain):
            _ensure_pages_dns(project_name, custom_domain, proxied=True)
        else:
            raise RuntimeError(f"Cloudflare Pages custom domain did not become active: {custom_domain}")


def _deploy_assets(project_name, build_dir, custom_domain=None, branch="main", timestamp_str=None):
    import base64, hashlib, mimetypes, urllib.request
    cf_request = _shared.cf_request
    ACCOUNT_ID, EMAIL, API_KEY, API_BASE = _shared.ACCOUNT_ID, _shared.EMAIL, _shared.API_KEY, _shared.API_BASE
    build_path = Path(build_dir)
    if not build_path.exists():
        raise RuntimeError(f"Build dir not found: {build_dir}")

    # 1. Create or get project
    try:
        cf_request("GET", f"/accounts/{ACCOUNT_ID}/pages/projects/{project_name}")
        print(f"Project '{project_name}' exists.")
    except Exception:
        print(f"Creating project '{project_name}' (production branch: {branch})...")
        cf_request("POST", f"/accounts/{ACCOUNT_ID}/pages/projects", {
            "name": project_name,
            "production_branch": branch
        })
        print(f"Project '{project_name}' created.")

    # 2. Request Upload Token (JWT)
    tok_res = cf_request("GET", f"/accounts/{ACCOUNT_ID}/pages/projects/{project_name}/upload-token")
    jwt = tok_res["result"]["jwt"]
    jwt_headers = {
        "Authorization": f"Bearer {jwt}",
        "Content-Type": "application/json"
    }

    # 3. Hash all build files with leading slashes in manifest
    files = []
    manifest = {}
    for p in sorted(build_path.rglob("*")):
        if not p.is_file() or p.name == "_worker.js":
            continue
        rel = p.relative_to(build_path).as_posix()
        manifest_path = f"/{rel}" if not rel.startswith("/") else rel
        data = p.read_bytes()
        digest = hashlib.md5(data).hexdigest()
        mime, _ = mimetypes.guess_type(p.name)
        files.append({
            "path": manifest_path,
            "hash": digest,
            "content_type": mime or "application/octet-stream",
            "base64": base64.b64encode(data).decode("ascii"),
            "size": len(data)
        })
        manifest[manifest_path] = digest

    print(f"Total build files: {len(files)}")

    # 4. Check missing hashes
    hashes = list(set([f["hash"] for f in files]))
    missing_res = cf_request("POST", "/pages/assets/check-missing", {"hashes": hashes}, headers=jwt_headers)
    missing = set(missing_res.get("result", []))
    print(f"Missing hashes to upload: {len(missing)}")

    # 5. Upload missing files in batches
    if missing:
        batches = []
        cur_batch = []
        cur_bytes = 0
        max_bytes = 7000000
        max_files = 50

        for f in files:
            if f["hash"] not in missing:
                continue
            if cur_batch and (len(cur_batch) >= max_files or cur_bytes + f["size"] > max_bytes):
                batches.append(cur_batch)
                cur_batch = []
                cur_bytes = 0
            cur_batch.append({
                "base64": True,
                "key": f["hash"],
                "metadata": {"contentType": f["content_type"]},
                "value": f["base64"]
            })
            cur_bytes += f["size"]
        if cur_batch:
            batches.append(cur_batch)

        print(f"Uploading in {len(batches)} batches...")
        for i, b in enumerate(batches, 1):
            cf_request("POST", "/pages/assets/upload", b, headers=jwt_headers)
            print(f" - Uploaded batch {i}/{len(batches)}")

    # 6. Upsert hashes
    cf_request("POST", "/pages/assets/upsert-hashes", {"hashes": hashes}, headers=jwt_headers)

    # 7. Create production deployment using multipart/form-data
    boundary = "----CloudflarePagesDeploymentBoundary"
    form_data = bytearray()

    def add_field(name, value):
        form_data.extend(f"--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n{value}\r\n".encode())

    add_field("branch", branch)
    add_field("commit_dirty", "false")
    add_field("commit_hash", "production-build")
    add_field("commit_message", f"Deploy {project_name} - {timestamp_str or ''}")
    add_field("manifest", json.dumps(manifest, separators=(',', ':')))
    worker = build_path / "_worker.js"
    if worker.exists():
        form_data.extend(f'--{boundary}\r\nContent-Disposition: form-data; name="_worker.js"; filename="_worker.js"\r\nContent-Type: application/javascript+module\r\n\r\n'.encode())
        form_data.extend(worker.read_bytes())
        form_data.extend(b'\r\n')
    form_data.extend(f"--{boundary}--\r\n".encode())

    dep_headers = {
        "X-Auth-Email": EMAIL,
        "X-Auth-Key": API_KEY,
        "Content-Type": f"multipart/form-data; boundary={boundary}"
    }

    req = urllib.request.Request(
        f"{API_BASE}/accounts/{ACCOUNT_ID}/pages/projects/{project_name}/deployments",
        data=bytes(form_data),
        headers=dep_headers,
        method="POST"
    )
    with urllib.request.urlopen(req) as resp:
        dep = json.loads(resp.read().decode("utf-8"))
        dep_id = dep["result"]["id"]
        dep_url = dep["result"]["url"]
        print(f"Deployment created: {dep_id} -> {dep_url}")

    # 8. Poll until success
    for _ in range(30):
        try:
            s = cf_request("GET", f"/accounts/{ACCOUNT_ID}/pages/projects/{project_name}/deployments/{dep_id}")
            stage = s["result"]["latest_stage"]
            status = stage["status"]
            print(f"Deploy status: {stage['name']} -> {status}")
            if status == "success":
                break
            if status == "failure":
                raise RuntimeError(f"Deployment failed at stage {stage['name']}")
        except urllib.error.HTTPError as e:
            if e.code == 404:
                print("Deploy status: initializing (404)...")
            else:
                raise
        time.sleep(2)

    # 9. Attach Custom Domain AFTER first deployment is live
    if custom_domain:
        try:
            domains = cf_request("GET", f"/accounts/{ACCOUNT_ID}/pages/projects/{project_name}/domains")
            existing_domains = [d.get("name") for d in domains.get("result", [])]
            if custom_domain not in existing_domains:
                print(f"Attaching custom domain '{custom_domain}' to {project_name}...")
                cf_request("POST", f"/accounts/{ACCOUNT_ID}/pages/projects/{project_name}/domains", {
                    "name": custom_domain
                })
                print(f"Attached custom domain '{custom_domain}'.")
            else:
                print(f"Custom domain '{custom_domain}' already attached.")
        except Exception as e:
            print(f"Custom domain attach note: {e}")

    print(f"✅ Successfully deployed {project_name} to {dep_url}")
    if custom_domain:
        print(f"   Live at: https://{custom_domain}")
