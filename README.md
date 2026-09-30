# Docker/BuildKit and `.wh.*` file names

What happens when a Dockerfile runs `COPY .wh.foo /tmp/.wh.foo`?

Short answer: BuildKit copies it as a literal regular file and writes it to
the layer tar as a plain regular-file entry `tmp/.wh.foo`. Any consumer that
unpacks that tar treats the entry as a whiteout for `tmp/foo`. The file
exists during the build and in containers run from the locally built image,
but it does not survive a save/export and re-import round trip.

## Environment

| Item | Value |
|---|---|
| Host | macOS (Darwin 27.0.0), arm64 |
| Docker runtime | OrbStack, Linux kernel 7.0.14-orbstack, aarch64 |
| Docker Engine / CLI | 29.4.0 (API 1.54), containerd v2.2.2, runc 1.5.1 |
| Storage driver | `overlay2` (containerd image store **off**) |
| Buildx | v0.33.0 |
| BuildKit (default `orbstack` builder, `docker` driver) | v0.29.0 |
| BuildKit (temporary `docker-container` builder) | v0.32.2 (`moby/buildkit:buildx-stable-1`) |
| Base image | `alpine:3.20` (3.20.10) |

## Layout

```text
context/                 build context: foo, .wh.foo, .wh..wh..opq, .wh., c
dockerfiles/
  exp1-same-layer.Dockerfile   foo and .wh.foo in ONE COPY
  exp2-cross-layer.Dockerfile  foo in a lower layer, .wh.foo in a later layer
  exp3-opaque.Dockerfile       /tmp/dir/{a,b} lower, then COPY .wh..wh..opq + c
  exp4-wh-empty.Dockerfile     COPY .wh. /tmp/.wh.
  reimport.Dockerfile          FROM an OCI layout, probes the paths
scripts/
  run-all.sh               runs every experiment through every path
  inspect_layers.py        lists tar entries (type, mode, size, content, PAX)
  container-builder.sh     creates/removes the temporary docker-container builder
  registry-roundtrip.sh    docker build + push to a local registry, pull on fresh daemons
results/<exp>/             logs, layer listings, extracted index/manifest/config
                           and the small layer blobs
results/registry-roundtrip/ logs of the registry round trip, per experiment
```

Every file in `context/` holds text that names the file. For example,
`.wh.foo` contains
`CONTENT-OF-.wh.foo: I am a regular file literally named .wh.foo`.

## How to reproduce

```sh
scripts/container-builder.sh create   # optional, enables steps 8-10
scripts/run-all.sh                    # or: scripts/run-all.sh exp2-cross-layer
scripts/container-builder.sh remove

scripts/registry-roundtrip.sh         # registry round trip, see below
```

For each experiment, `run-all.sh` runs these commands (paths shortened):

| # | Path | Command | Output |
|---|---|---|---|
| 1 | Default build | `docker build --no-cache --progress=plain -f $DF -t whiteout-test:$EXP context` | `01-build.log` |
| 2 | Runtime | `docker run --rm whiteout-test:$EXP sh -c "$PROBE"` | `02-run.log` |
| 3 | Docker image store | `docker image save` + `inspect_layers.py`; read-only listing of the overlay2 `diff/` dirs | `03-*` |
| 4 | Buildx `--load` | `docker buildx build --load ...` | `04-buildx-load.log` |
| 5 | OCI export (docker driver) | `docker buildx build --output type=oci,dest=oci.tar ...` | `05-oci-export.log` |
| 6 | BuildKit merged FS | `docker buildx build --output type=local,dest=fs-export ...` | `06-*` |
| 7 | Legacy builder | `DOCKER_BUILDKIT=0 docker build ...`, then run + save | `07-*` |
| 8 | OCI export (container driver) | `docker buildx build --builder whiteout-test-builder --output type=oci,dest=cb-oci.tar ...` | `08-*` |
| 9 | Re-unpack by dockerd | same builder `--output type=docker,dest=cb-docker.tar`, then `docker image load` + `docker run` | `09-*` |
| 10 | Re-unpack by BuildKit | same builder exports an OCI dir, `docker buildx prune -af` on that builder, then `--build-context base=oci-layout://<dir>:latest -f reimport.Dockerfile` | `10-reimport.log` |

`$PROBE` runs `ls -la` on `/tmp` and `/tmp/dir`, then prints `EXISTS <path> ::
<content>` or `MISSING <path>` for each file of interest.

Steps 9 and 10 matter most. In steps 2 and 3 the daemon runs and saves from
the overlay2 directories that BuildKit wrote. It never parses a layer tar.
Steps 9 and 10 force a fresh unpack of the serialized layers.

## Results

### Experiment 1: `COPY foo .wh.foo /tmp/` (same layer)

BuildKit build (`01-build.log`). The build succeeds with no warnings and the
RUN step sees both files:

```text
#7 0.142 -rw-r--r--    1 root     root            64 Sep 24 14:19 .wh.foo
#7 0.142 -rw-r--r--    1 root     root            48 Sep 24 14:19 foo
#7 0.142 EXISTS  /tmp/foo :: CONTENT-OF-foo: I am the regular file named foo
#7 0.142 EXISTS  /tmp/.wh.foo :: CONTENT-OF-.wh.foo: I am a regular file literally named .wh.foo
```

`docker run` on that image (`02-run.log`) shows both files too.

Layer tar from `docker image save` (`03-docker-save-layers.txt`). The step 8
OCI export (`08-container-oci-layers.txt`) has the same entries:

```text
== layer 1: created_by: COPY foo .wh.foo /tmp/ # buildkit
  DIR  1777 0:0 size=0    tmp
  REG  0644 0:0 size=64   tmp/.wh.foo   <-- .wh. name
         content: 'CONTENT-OF-.wh.foo: I am a regular file literally named .wh.foo'
  REG  0644 0:0 size=48   tmp/foo
```

After a fresh unpack, `foo` survives and `.wh.foo` is gone. This happens in
both step 9 (`docker load`) and step 10 (BuildKit re-import):

```text
EXISTS  /tmp/foo :: CONTENT-OF-foo: I am the regular file named foo
MISSING /tmp/.wh.foo
```

### Experiment 2: `foo` in a lower layer, `.wh.foo` added later

In the BuildKit build and in `docker run` on the built image, both files
exist:

```text
#9 0.117 EXISTS  /tmp/foo :: CONTENT-OF-foo: I am the regular file named foo
#9 0.118 EXISTS  /tmp/.wh.foo :: CONTENT-OF-.wh.foo: I am a regular file literally named .wh.foo
```

The overlay2 storage holds `.wh.foo` as a plain file in the upper layer
(`03-overlay2-storage.txt`):

```text
--- .../wkkj2txp7r07grph3iul4ig40/diff/tmp
-rw-r--r--    1 root     root            64 Sep 24 14:19 .wh.foo
--- .../r947zefzt51na5a3xwujcba4w/diff/tmp
-rw-r--r--    1 root     root            48 Sep 24 14:19 foo
```

The serialized layer (`03-docker-save-layers.txt`, same in the OCI export):

```text
== layer 1: created_by: COPY foo /tmp/foo # buildkit
  REG  0644 0:0 size=48   tmp/foo
== layer 3: created_by: COPY .wh.foo /tmp/.wh.foo # buildkit
  DIR  1777 0:0 size=0    tmp
  REG  0644 0:0 size=64   tmp/.wh.foo   <-- .wh. name
         content: 'CONTENT-OF-.wh.foo: I am a regular file literally named .wh.foo'
```

A plain regular-file entry. Nothing marks it as literal rather than as a
whiteout: no PAX header or xattr, and it keeps its non-empty content.

After a fresh unpack, **both files are gone**. The entry deleted `foo` from
the lower layer (`09-loaded-run.log`, `10-reimport.log`):

```text
MISSING /tmp/foo
MISSING /tmp/.wh.foo
```

### Experiment 3: `.wh..wh..opq` over a directory with inherited files

In the BuildKit build and on the locally built image, the marker is a plain
file and `a` and `b` stay visible:

```text
#9 0.135 -rw-r--r--    1 root     root            74 Sep 24 14:19 .wh..wh..opq
#9 0.135 -rw-r--r--    1 root     root             8 Sep 24 14:24 a
#9 0.135 -rw-r--r--    1 root     root             8 Sep 24 14:24 b
#9 0.135 -rw-r--r--    1 root     root            54 Sep 24 14:19 c
```

Serialized layer:

```text
== layer 3: created_by: COPY .wh..wh..opq c /tmp/dir/ # buildkit
  DIR  0755 0:0 size=0    tmp/dir
  REG  0644 0:0 size=74   tmp/dir/.wh..wh..opq   <-- .wh. name
  REG  0644 0:0 size=54   tmp/dir/c
```

After a fresh unpack (steps 9 and 10), the entry acts as an opaque marker.
The inherited files disappear and the sibling from the same layer stays:

```text
MISSING /tmp/dir/a
MISSING /tmp/dir/b
EXISTS  /tmp/dir/c :: CONTENT-OF-c: added in the same layer as .wh..wh..opq
MISSING /tmp/dir/.wh..wh..opq
```

### Experiment 4: `COPY .wh. /tmp/.wh.`

BuildKit does **not** reject it. Every BuildKit path builds it, and the
built image runs and shows `/tmp/.wh.` with its content. The layer contains
`REG 0644 size=58 tmp/.wh.`. The failures come later, when something
unpacks that layer:

- `docker image load` (step 9):
  `failed to mknod('/tmp', S_IFCHR, 0): file exists`
- BuildKit re-import (step 10):
  `ERROR: failed to build: failed to solve: failed to compute cache key: invalid whiteout name: .wh.: invalid archive`
- Legacy builder, at the COPY step itself:
  `Step 2/3 : COPY .wh. /tmp/.wh.` then `failed to mknod('/tmp', S_IFCHR, 0): file exists`

### Registry round trip (`docker push` / `docker pull`)

`scripts/registry-roundtrip.sh` tests the most common real-world path: build
with the default builder, push, pull somewhere else. For exp1 to exp3 it:

1. starts `registry:2` on a dedicated Docker network;
2. runs a plain `docker build` (default builder, overlay2) and
   `docker push localhost:5000/whiteout-test:$EXP`;
3. lists the `COPY` layer blob as stored in the registry (`crane blob`), and
   flattens the image with `crane export`;
4. pulls and runs the probe on two fresh `docker:dind` daemons (Engine
   29.8.1) that have never seen these layers: one with the **containerd image
   store** (the default, `overlayfs` snapshotter) and one with the classic
   **overlay2** graph driver.

The registry holds the same plain regular-file entries as before:

```text
exp1:  tmp/.wh.foo (64 bytes) + tmp/foo (48 bytes), same layer
exp2:  tmp/.wh.foo (64 bytes)
exp3:  tmp/dir/.wh..wh..opq (74 bytes) + tmp/dir/c
```

Both fresh daemons give the same results as the tarball and OCI-layout
re-imports (steps 9 and 10):

| Experiment | containerd image store | overlay2 |
|---|---|---|
| exp1 | `foo` EXISTS, `.wh.foo` MISSING | same |
| exp2 | `foo` and `.wh.foo` both MISSING | same |
| exp3 | `a`, `b`, `.wh..wh..opq` MISSING, `c` EXISTS | same |

`crane export` (go-containerregistry, `crane:debug` image) agrees on exp2
and exp3, but **not on exp1**: its flattened output drops `tmp/foo` too, so
the whiteout hides a sibling from its own layer. The OCI spec says it should
not ("Files that are present in the same layer as a whiteout file can only be
hidden by whiteout files in subsequent layers"). `mutate.Extract` records
whiteouts in its `fileMap` while it reads a layer, and `tmp/.wh.foo` comes
before `tmp/foo` in the tar, so `foo` is skipped. The outcome depends on the
entry order.

Logs are in `results/registry-roundtrip/`.

### Legacy builder (`DOCKER_BUILDKIT=0`)

The legacy builder applies whiteout semantics at COPY time, inside the build.
Every save of its images fails:

| Experiment | RUN after COPY / `docker run` | overlay2 upper dir | `docker image save` |
|---|---|---|---|
| exp1 | `foo` present, `.wh.foo` MISSING | only `foo` | `Error response from daemon: open .../merged/tmp/.wh.foo: no such file or directory` |
| exp2 | `foo` and `.wh.foo` both MISSING | `c--------- 0,0 foo` (overlay whiteout device) | same error |
| exp3 | `a`, `b`, `.wh..wh..opq` MISSING, `c` present | only `c` | `open .../merged/tmp/dir/.wh..wh..opq: no such file or directory` |
| exp4 | build fails | n/a | n/a |

### Output-path comparison

| Path | `.wh.foo` in build RUN | `.wh.foo` in container | Layer entry |
|---|---|---|---|
| `docker build` (BuildKit, docker driver) | yes | yes (image built locally) | REG `tmp/.wh.foo` |
| `docker buildx build --load` | yes | same image path as above | same |
| `--output type=oci` (docker driver) | not run: `ERROR: failed to build: OCI exporter is not supported for the docker driver.` | n/a | n/a |
| `--output type=local` | yes (`fs-export/tmp/.wh.foo` regular file) | n/a | n/a |
| `--output type=oci` (docker-container driver) | yes | n/a | REG `tmp/.wh.foo` |
| OCI/docker tar re-unpacked (dockerd or BuildKit) | n/a | **no**, treated as a whiteout | n/a |
| Legacy builder | no, whiteout applied at COPY | no | save fails |

## Conclusion

1. **Does `COPY .wh.foo /tmp/.wh.foo` succeed?** Yes, with BuildKit, with no
   warning. The legacy builder also "succeeds" but turns the file into a
   whiteout. `COPY .wh.` succeeds with BuildKit and fails with the legacy
   builder.

2. **Can `.wh.foo` exist during a Docker build?** Yes, with BuildKit. In
   BuildKit snapshots it is a normal file, visible to later `RUN` steps and
   to `--output type=local`. With the legacy builder, no.

3. **Can `.wh.foo` exist in a container from the final image?** Only when
   the container runs from the image BuildKit built on the same daemon, which
   reuses BuildKit's overlay2 directories. Once the image goes through a
   serialized layer (`docker load` of an export, or BuildKit importing an OCI
   layout, or `docker pull` on a fresh daemon), `.wh.foo` never exists. Moving
   the same image through a registry or tarball changes its filesystem.

4. **How is `.wh.foo` serialized?** As a plain regular-file tar entry
   `tmp/.wh.foo` with its original mode and content, no special PAX
   headers. Under OCI rules that entry is exactly a whiteout for `tmp/foo`,
   and both unpackers tested treat it that way: it deletes a lower
   `tmp/foo` (exp2). The same holds for `.wh..wh..opq`, which acts as an
   opaque marker (exp3). `.wh.` gives an archive that no unpacker tested
   accepts (exp4).

5. **Does the internal snapshot differ from the exported image?** Yes.
   BuildKit's snapshot (and the local overlay2 image made from it) keeps
   literal files. The serialized layer has the same bytes, but it means
   something else to any unpacker. BuildKit does not escape, reject or warn
   about the name. The legacy builder is different again: it applies the
   whiteout during the build and then cannot save the image.

6. **"OCI images cannot represent normal files whose basename starts with
   `.wh.`": is it borne out?** Yes. The tooling tested accepted such files
   and wrote them into layers, but the only encoding it produced is the
   whiteout encoding. Every unpack of those layers deleted the files
   (and the target), or rejected the archive for `.wh.`. No test ever
   produced a regular `.wh.*` file from a serialized layer. The name only
   survives in the local, never-serialized build output.

## Notes and limits

- Builds used only the overlay2 graph driver. The containerd image store (the
  default on new Docker installs) was not enabled on the build host, so the
  docker-driver OCI export was unavailable and step 10 used the
  docker-container builder instead. The registry round trip does pull with
  the containerd image store, on a fresh `docker:dind` daemon.
- `docker image load` printed no per-layer progress without a TTY. The
  changed filesystem in step 9 shows that the layers were applied again.
- `scripts/container-builder.sh` adds a buildx builder and a BuildKit
  container. It was removed after the run. The experiment images are still
  tagged `whiteout-test:*`. Remove them with
  `docker image rm $(docker image ls -q whiteout-test)`.
- `RUN touch /tmp/.wh.foo` (creating the name in a RUN step, not with COPY)
  was not tested.
