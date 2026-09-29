# Docker Desktop disk image: inspect and migrate

Use this when the script reports a Docker Desktop disk image that is not in use. Switching engines does not move volumes, so assume the image holds databases the active engine lacks. Never delete, reset or uninstall Docker Desktop until the volumes are checked; a reset or uninstall wipes them too. Do not start Docker Desktop to look.

- **Inspect read-only from the active engine** (no Docker Desktop needed). The image is partitioned, so find the offset first, then mount with `noload` so the journal is not replayed:
  ```bash
  D=~/Library/Containers/com.docker.docker/Data/vms/0/data
  docker run --rm --privileged -v "$D":/d:ro alpine sh -c 'apk add -q sfdisk >/dev/null
    O=$(( $(sfdisk -d /d/Docker.raw | sed -n "s/.*start= *\([0-9]*\).*/\1/p" | head -1) * 512 ))
    mkdir /m && mount -t ext4 -o ro,noload,loop,offset=$O /d/Docker.raw /m
    du -sm /m/docker/volumes/*/ | sort -rn; umount /m'
  ```
  Compare the names with `docker volume ls` on the active engine. Report each named volume with its size, last write date and whether it exists in the new engine. Hash-named volumes and throwaway test environments (e.g. `wp-env-*`) are usually disposable. Say so, but let the user decide.
- **Migrate what the user picks** by copying from the same read-only mount into a volume of the same name on the active engine (`docker volume create <name>`, then `cp -a /m/docker/volumes/<name>/_data/. /dst/` with the new volume mounted at `/dst`), so compose projects find their data unchanged. Confirm that each copied database starts. Only then offer to delete the disk image, as its own approval.
