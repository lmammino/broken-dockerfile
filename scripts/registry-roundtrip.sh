#!/usr/bin/env bash
# Registry round trip: build with the default builder, push to a local
# registry, then pull and probe on fresh docker:dind daemons that have never
# seen these layers (so they must unpack the serialized layer tars).
#
# Usage: scripts/registry-roundtrip.sh [exp...]   (default: exp1 exp2 exp3)
set -u
cd "$(dirname "$0")/.."

NET=wh-reg-net
REG=wh-registry
CRANE=gcr.io/go-containerregistry/crane:debug
OUT=results/registry-roundtrip
EXPS=("${@:-exp1-same-layer exp2-cross-layer exp3-opaque}")
read -r -a EXPS <<<"${EXPS[*]}"

PROBE='for d in /tmp /tmp/dir; do [ -d $d ] && echo "--- ls -la $d ---" && ls -la $d; done; for p in /tmp/foo /tmp/.wh.foo /tmp/dir/a /tmp/dir/b /tmp/dir/c /tmp/dir/.wh..wh..opq; do if [ -e "$p" ]; then echo "EXISTS  $p :: $(cat "$p")"; else echo "MISSING $p"; fi; done'

mkdir -p "$OUT"

cleanup() {
  docker rm -f "$REG" wh-dind-containerd wh-dind-overlay2 >/dev/null 2>&1
  docker network rm "$NET" >/dev/null 2>&1
}
cleanup
trap cleanup EXIT

docker network create "$NET" >/dev/null
docker run -d --name "$REG" --network "$NET" -p 5000:5000 registry:2 >/dev/null

# Two fresh daemons: default (containerd image store) and classic overlay2.
docker run -d --privileged --name wh-dind-containerd --network "$NET" \
  docker:dind --insecure-registry "$REG:5000" >/dev/null
docker run -d --privileged --name wh-dind-overlay2 --network "$NET" \
  docker:dind --insecure-registry "$REG:5000" \
  --feature containerd-snapshotter=false --storage-driver overlay2 >/dev/null

for d in wh-dind-containerd wh-dind-overlay2; do
  until docker exec "$d" docker info >/dev/null 2>&1; do sleep 1; done
  {
    docker exec "$d" docker version --format 'Engine {{.Server.Version}}'
    docker exec "$d" docker info --format 'Driver={{.Driver}} {{.DriverStatus}}'
  } >"$OUT/$d-env.txt"
done

for exp in "${EXPS[@]}"; do
  tag="localhost:5000/whiteout-test:$exp"
  ref="$REG:5000/whiteout-test:$exp"
  log="$OUT/$exp.log"
  : >"$log"

  echo "== build + push ($exp)" | tee -a "$log"
  docker build --no-cache -q -f "dockerfiles/$exp.Dockerfile" -t "$tag" context >>"$log" 2>&1
  docker push -q "$tag" >>"$log" 2>&1

  echo "== COPY layer entries in the registry (second-to-last layer)" >>"$log"
  docker run --rm --network "$NET" --entrypoint sh "$CRANE" -c \
    "d=\$(crane manifest --insecure $ref | sed -n 's/.*\"digest\": *\"\\(sha256:[0-9a-f]*\\)\".*/\\1/p' | tail -2 | head -1); \
     crane blob --insecure $ref@\$d | tar tzvf -" >>"$log" 2>&1

  echo "== crane export (flattened, whiteouts applied)" >>"$log"
  docker run --rm --network "$NET" --entrypoint sh "$CRANE" -c \
    "crane export --insecure $ref - | tar tvf - | grep ' tmp/' || true" >>"$log" 2>&1

  for d in wh-dind-containerd wh-dind-overlay2; do
    echo "== pull + run on $d" >>"$log"
    docker exec "$d" docker pull -q "$ref" >>"$log" 2>&1
    docker exec "$d" docker run --rm "$ref" sh -c "$PROBE" >>"$log" 2>&1
  done
  grep -E '^==|EXISTS|MISSING' "$log"
done
