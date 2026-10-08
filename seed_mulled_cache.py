"""Seed planemo's mulled resolution cache with an index of a Quay namespace.

Galaxy checks that a repository exists in the biocontainers namespace before
fetching its tags, and lists the whole namespace to do so. Seeding the cache
with an index written by ``mulled-cache`` saves every test chunk that listing.
"""

import json
import os
import sys

from beaker.cache import CacheManager
from beaker.util import parse_cache_config_options
from galaxy.tool_util.deps.mulled.util import NAMESPACE_HAS_REPO_NAME_KEY

# Beaker honours the expiry stored with a value, not the one Galaxy reads it
# with, so the index outlives Galaxy's 1 hour default for the whole job.
SEED_EXPIRE = 24 * 60 * 60


def main(seed_path: str, data_dir: str) -> None:
    with open(seed_path) as seed_file:
        repositories = json.load(seed_file).get("repositories", [])
    if not repositories:
        print(f"No repositories in {seed_path}, not seeding the mulled resolution cache")
        return
    cache_opts = {
        "cache.type": "file",
        "cache.data_dir": data_dir,
        "cache.lock_dir": os.path.join(data_dir, "seed_locks"),
        "cache.expire": SEED_EXPIRE,
    }
    cache = CacheManager(**parse_cache_config_options(cache_opts)).get_cache("mulled_resolution")
    cache[NAMESPACE_HAS_REPO_NAME_KEY] = repositories
    print(f"Seeded the mulled resolution cache in {data_dir} with {len(repositories)} repositories")


if __name__ == "__main__":
    main(*sys.argv[1:3])
