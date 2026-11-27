#!/usr/bin/env python3
"""Diagnose a missing GitHub raw script without executing or installing it."""
from __future__ import annotations

import argparse
import json
import sys
import urllib.error
import urllib.parse
import urllib.request
from typing import Any

USER_AGENT = "sing-box-yg-repair-kit/1.2.0 (read-only GitHub source diagnostic)"


class FetchError(Exception):
    def __init__(self, status: int | None, message: str):
        super().__init__(message)
        self.status = status


def fetch(url: str, timeout: int = 15) -> tuple[int, bytes]:
    request = urllib.request.Request(
        url,
        headers={
            "User-Agent": USER_AGENT,
            "Accept": "application/vnd.github+json, application/json, */*",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as exc:
        body = exc.read(4096)
        raise FetchError(exc.code, body.decode("utf-8", "replace")) from exc
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise FetchError(None, str(exc)) from exc


def raw_url(repo: str, ref: str, path: str) -> str:
    safe_path = urllib.parse.quote(path.lstrip("/"), safe="/")
    safe_ref = urllib.parse.quote(ref, safe="")
    return f"https://raw.githubusercontent.com/{repo}/{safe_ref}/{safe_path}"


def find_candidates(tree: list[dict[str, Any]], requested_path: str) -> list[str]:
    requested = requested_path.rsplit("/", 1)[-1].casefold()
    stem = requested.rsplit(".", 1)[0]
    paths = [
        item.get("path", "")
        for item in tree
        if item.get("type") == "blob" and isinstance(item.get("path"), str)
    ]
    exact_basename = [p for p in paths if p.rsplit("/", 1)[-1].casefold() == requested]
    if exact_basename:
        return sorted(exact_basename, key=lambda x: (x.count("/"), x.casefold()))
    similar = [
        p for p in paths
        if stem in p.casefold() or ("sb-manager" in p.casefold() and p.casefold().endswith(".sh"))
    ]
    return sorted(similar, key=lambda x: (x.count("/"), x.casefold()))[:20]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Read-only diagnostic for a GitHub raw URL returning 404. Does not run remote code."
    )
    parser.add_argument("--repo", default="mxw1589/jiedian", help="GitHub OWNER/REPOSITORY")
    parser.add_argument("--path", default="sb-manager-debian-alpine.sh", help="Expected file path inside repository")
    parser.add_argument("--ref", default="main", help="Branch/tag/commit to check first (default: main)")
    parser.add_argument("--timeout", type=int, default=15, help="HTTP timeout in seconds")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if "/" not in args.repo or any(ch.isspace() for ch in args.repo):
        print("[ERROR] --repo must be OWNER/REPOSITORY", file=sys.stderr)
        return 2
    if args.timeout < 1:
        print("[ERROR] --timeout must be >= 1", file=sys.stderr)
        return 2

    owner, repo_name = args.repo.split("/", 1)
    repo = f"{owner}/{repo_name}"
    print("GitHub raw source diagnostic (read-only)")
    print(f"Repository : {repo}")
    print(f"Requested  : {args.path}")
    print(f"First ref  : {args.ref}")
    print("No remote file will be executed or installed.\n")

    metadata_url = f"https://api.github.com/repos/{repo}"
    try:
        _, metadata_bytes = fetch(metadata_url, args.timeout)
        metadata = json.loads(metadata_bytes)
    except FetchError as exc:
        if exc.status == 404:
            print("[NOT FOUND] GitHub API cannot see this repository.")
            print("It may have been deleted, renamed, made private, or the owner/repository is incorrect.")
            print("Ask the repository maintainer for the current public repository URL.")
            return 3
        if exc.status == 403:
            print("[API LIMIT / FORBIDDEN] GitHub API refused the metadata request.")
            print("Wait for the unauthenticated API limit to reset, then rerun this diagnostic.")
            return 4
        print(f"[NETWORK ERROR] Cannot query GitHub repository metadata: {exc}")
        return 4
    except (json.JSONDecodeError, TypeError) as exc:
        print(f"[ERROR] Invalid GitHub repository metadata: {exc}")
        return 4

    default_branch = metadata.get("default_branch") or "main"
    print(f"Default branch: {default_branch}")

    refs: list[str] = []
    for ref in (args.ref, default_branch, "main", "master"):
        if ref and ref not in refs:
            refs.append(ref)

    raw_results: dict[str, int | None] = {}
    for ref in refs:
        url = raw_url(repo, ref, args.path)
        try:
            status, _ = fetch(url, args.timeout)
            raw_results[ref] = status
            print(f"[RAW {status}] {url}")
            if status == 200:
                print("\n[FOUND] The requested file exists at this ref.")
                print("This diagnostic only verifies availability; it does not download or execute the file.")
                return 0
        except FetchError as exc:
            raw_results[ref] = exc.status
            if exc.status is None:
                print(f"[RAW NETWORK ERROR] {url}: {exc}")
            else:
                print(f"[RAW {exc.status}] {url}")

    # Inspect the repository tree on likely branches to identify a rename or move.
    all_candidates: list[tuple[str, str]] = []
    for ref in refs:
        tree_url = f"https://api.github.com/repos/{repo}/git/trees/{urllib.parse.quote(ref, safe='')}?recursive=1"
        try:
            _, tree_bytes = fetch(tree_url, args.timeout)
            tree_data = json.loads(tree_bytes)
            tree = tree_data.get("tree", [])
            for candidate in find_candidates(tree, args.path):
                pair = (ref, candidate)
                if pair not in all_candidates:
                    all_candidates.append(pair)
            if tree_data.get("truncated"):
                print(f"[WARNING] GitHub returned a truncated file tree for ref {ref}.")
        except FetchError as exc:
            if exc.status not in (404,):
                print(f"[TREE CHECK] Could not inspect ref {ref}: {exc}")
        except (json.JSONDecodeError, TypeError):
            print(f"[TREE CHECK] Invalid tree response for ref {ref}.")

    if all_candidates:
        print("\n[POSSIBLE MOVED/RENAMED FILES]")
        for ref, candidate in all_candidates:
            print(f"  path: {candidate}")
            print(f"  url : {raw_url(repo, ref, candidate)}")
        print("\nDo not substitute a candidate blindly. Confirm it with the maintainer and verify the expected SHA-256 first.")
        return 2

    print("\n[NOT FOUND] No exact file or obvious sb-manager candidate was found in the inspected refs.")
    print("The 404 is upstream: the requested file path is unavailable at the checked refs.")
    print("This is not caused by Debian, IPv6, sing-box core, or the local /usr/bin/sb repair patch.")
    print("Do not disable SHA-256 verification or replace the URL with an untrusted mirror.")
    print("Ask the installer author/maintainer for the current script URL and matching checksum.")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
