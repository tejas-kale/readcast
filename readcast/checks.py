"""Read-only checks for the services used by publication."""

from __future__ import annotations

import os
from urllib.parse import quote

import boto3
import requests

from .publishing import _repository


def check_connections(config: dict) -> list[str]:
    """Check configured endpoints without creating audio or remote resources."""
    key = os.environ["OPENROUTER_API_KEY"]
    response = requests.get(
        "https://openrouter.ai/api/v1/models",
        headers={"Authorization": f"Bearer {key}"}, timeout=15,
    )
    if response.status_code != 200:
        raise RuntimeError(f"OpenRouter connection returned HTTP {response.status_code}")

    client = boto3.client(
        "s3", endpoint_url=f"https://{config['r2_account_id']}.r2.cloudflarestorage.com",
        aws_access_key_id=os.environ["R2_ACCESS_KEY_ID"],
        aws_secret_access_key=os.environ["R2_SECRET_ACCESS_KEY"],
        region_name="auto",
    )
    client.list_objects_v2(Bucket=config["r2_bucket"], MaxKeys=1)

    worker = requests.head(config["worker_url"].rstrip("/") + "/audio/readcast-setup-probe-does-not-exist.mp3", timeout=15)
    if worker.status_code != 404:
        raise RuntimeError(f"Worker probe returned HTTP {worker.status_code}; expected 404")

    owner, repository, pages_url = _repository(config["github_pages_url"])
    github = requests.get(
        f"https://api.github.com/repos/{quote(owner)}/{quote(repository)}",
        headers={"Authorization": f"Bearer {os.environ['GITHUB_TOKEN']}",
                 "Accept": "application/vnd.github+json", "User-Agent": "Readcast setup check"},
        timeout=15,
    )
    if github.status_code != 200:
        raise RuntimeError(f"GitHub repository access returned HTTP {github.status_code}")
    pages = requests.get(pages_url, timeout=15)
    if not 200 <= pages.status_code < 300:
        raise RuntimeError(f"GitHub Pages returned HTTP {pages.status_code}")
    return ["OpenRouter", "R2", "audio Worker", "GitHub repository", "GitHub Pages"]
