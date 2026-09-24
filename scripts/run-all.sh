#!/usr/bin/env bash
# Runs every experiment through every output path and stores logs and
# layer listings under results/<experiment>/.
#
# Usage: scripts/run-all.sh [experiment ...]   (default: all)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CTX="$ROOT/context"
DF_DIR="$ROOT/dockerfiles"
RES="$ROOT/results"
INSPECT="$ROOT/scripts/inspect_layers.py"

# Optional isolated BuildKit (docker-container driver). Created by
# scripts/container-builder.sh; skipped when absent.
CB_NAME="whiteout-test-builder"
BASE_IMAGE="alpine:3.20"

# Probe run inside containers created from the final image.
PROBE='for d in /tmp /tmp/dir; do [ -d $d ] && echo "--- ls -la $d ---" && ls -la $d; done;
for p in /tmp/foo /tmp/.wh.foo /tmp/dir/a /tmp/dir/b /tmp/dir/c /tmp/dir/.wh..wh..opq /tmp/.wh.; do
  if [ -e "$p" ]; then echo "EXISTS  $p :: $(cat "$p")"; else echo "MISSING $p"; fi; done'

EXPERIMENTS=("$@")
if [ ${#EXPERIMENTS[@]} -eq 0 ]; then
  EXPERIMENTS=(exp1-same-layer exp2-cross-layer exp3-opaque exp4-wh-empty)
fi

# run <logfile> <cmd...>: tee output to logfile, record command and exit code.
run() {
  local log=$1; shift
  { echo "\$ $*"; "$@" 2>&1; echo "[exit code: $?]"; } | tee "$log"
}

# extract_and_inspect <archive> <outdir> <listing>
extract_and_inspect() {
  local archive=$1 out=$2 listing=$3
  rm -rf "$out" && mkdir -p "$out"
  tar -xf "$archive" -C "$out"
  python3 "$INSPECT" "$out" | tee "$listing"

  # Keep metadata and small (non-base) layer blobs; drop big blobs.
  find "$out/blobs" -type f -size +512k -delete
  rm -f "$archive"
}

# save_and_inspect <tag> <log prefix> <extract dir>
save_and_inspect() {
  local tag=$1 prefix=$2 dir=$3
  run "$prefix.log" docker image save "$tag" -o "$dir.tar"
  if [ -s "$dir.tar" ]; then
    extract_and_inspect "$dir.tar" "$dir" "$prefix-layers.txt"
  fi
  rm -f "$dir.tar"
}

# storage_peek <tag> <file>: read-only look at the overlay2 layer dirs
# backing an image, to see how the daemon stores tmp/ internally.
storage_peek() {
  local tag=$1 file=$2 dirs
  dirs=$(docker image inspect -f '{{.GraphDriver.Data.UpperDir}}:{{.GraphDriver.Data.LowerDir}}' "$tag" | tr ':' ' ')
  run "$file" docker run --rm -v /var/lib/docker/overlay2:/var/lib/docker/overlay2:ro "$BASE_IMAGE" \
    sh -c 'for d in "$@"; do [ -d "$d/tmp" ] || continue; echo "--- $d/tmp"; ls -laR "$d/tmp"; done' sh $dirs
}

for exp in "${EXPERIMENTS[@]}"; do
  df="$DF_DIR/$exp.Dockerfile"
  out="$RES/$exp"
  tag="whiteout-test:$exp"
  rm -rf "$out" && mkdir -p "$out"
  echo "################ $exp ################"

  # 1. Default path: `docker build` (BuildKit, docker driver).
  run "$out/01-build.log" docker build --no-cache --progress=plain -f "$df" -t "$tag" "$CTX"
  build_ok=$(docker image inspect "$tag" >/dev/null 2>&1 && echo yes || echo no)

  if [ "$build_ok" = yes ]; then
    # 2. Runtime view.
    run "$out/02-run.log" docker run --rm "$tag" sh -c "$PROBE"

    # 3. Serialized layers from Docker's image store.
    save_and_inspect "$tag" "$out/03-docker-save" "$out/docker-save"
    storage_peek "$tag" "$out/03-overlay2-storage.txt"
  fi

  # 4. Explicit buildx --load (same docker driver).
  run "$out/04-buildx-load.log" docker buildx build --load --no-cache --progress=plain \
    -f "$df" -t "$tag-buildx" "$CTX"

  # 5. OCI layout export from the docker driver.
  run "$out/05-oci-export.log" docker buildx build --no-cache --progress=plain \
    --output "type=oci,dest=$out/oci.tar" -f "$df" "$CTX"
  if [ -f "$out/oci.tar" ]; then
    extract_and_inspect "$out/oci.tar" "$out/oci-layout" "$out/05-oci-layers.txt"
  fi

  # 6. BuildKit's merged filesystem view of the final stage (no layers).
  rm -rf "$out/fs-export"
  run "$out/06-fs-export.log" docker buildx build --no-cache --progress=plain \
    --output "type=local,dest=$out/fs-export" -f "$df" "$CTX"
  if [ -d "$out/fs-export/tmp" ]; then
    { echo "\$ find fs-export/tmp -exec ls -ld {} +"; (cd "$out" && find fs-export/tmp -exec ls -ld {} +); } \
      | tee "$out/06-fs-export-tree.txt"
    rm -rf "$out/fs-export"
  fi

  # 7. Legacy (non-BuildKit) builder, for comparison.
  run "$out/07-legacy-build.log" env DOCKER_BUILDKIT=0 docker build --no-cache \
    -f "$df" -t "$tag-legacy" "$CTX"
  if docker image inspect "$tag-legacy" >/dev/null 2>&1; then
    run "$out/07-legacy-run.log" docker run --rm "$tag-legacy" sh -c "$PROBE"
    save_and_inspect "$tag-legacy" "$out/07-legacy-save" "$out/legacy-save"
    storage_peek "$tag-legacy" "$out/07-legacy-overlay2-storage.txt"
  fi

  # 8. Isolated BuildKit (docker-container driver): OCI export.
  if docker buildx inspect "$CB_NAME" >/dev/null 2>&1; then
    run "$out/08-container-oci-export.log" docker buildx build --builder "$CB_NAME" \
      --no-cache --progress=plain --output "type=oci,dest=$out/cb-oci.tar" -f "$df" "$CTX"
    if [ -f "$out/cb-oci.tar" ]; then
      extract_and_inspect "$out/cb-oci.tar" "$out/cb-oci-layout" "$out/08-container-oci-layers.txt"
    fi

    # 9. Same builder, docker-archive output loaded into the daemon. The
    # daemon must unpack the serialized layer tars itself here.
    run "$out/09-container-docker-export.log" docker buildx build --builder "$CB_NAME" \
      --no-cache --progress=plain --output "type=docker,dest=$out/cb-docker.tar" \
      -f "$df" -t "$tag-cb" "$CTX"
    if [ -f "$out/cb-docker.tar" ]; then
      docker image rm -f "$tag-cb" >/dev/null 2>&1
      run "$out/09-docker-load.log" docker image load -i "$out/cb-docker.tar"
      rm -f "$out/cb-docker.tar"
      if docker image inspect "$tag-cb" >/dev/null 2>&1; then
        run "$out/09-loaded-run.log" docker run --rm "$tag-cb" sh -c "$PROBE"
      fi
    fi

    # 10. BuildKit re-imports its own OCI export as a base image. The
    # builder cache is pruned first so the layers must be unpacked again.
    layout="$out/cb-oci-dir"
    rm -rf "$layout"
    docker buildx build --builder "$CB_NAME" --no-cache --progress=quiet \
      --output "type=oci,dest=$layout,tar=false,name=reimport:latest" -f "$df" "$CTX" >/dev/null 2>&1
    if [ -f "$layout/index.json" ]; then
      docker buildx prune --builder "$CB_NAME" -af >/dev/null 2>&1
      run "$out/10-reimport.log" docker buildx build --builder "$CB_NAME" --no-cache \
        --progress=plain --build-context "base=oci-layout://$layout:latest" \
        -f "$DF_DIR/reimport.Dockerfile" "$CTX"
    fi
    rm -rf "$layout"
  fi
done
