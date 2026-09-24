#!/usr/bin/env python3
"""List every tar entry of every layer in an extracted image archive.

Works on both `docker image save` output and OCI layout exports.
Usage: inspect_layers.py <extracted-dir> [--all]

Without --all, only entries under tmp/ are printed (the base image
layer is summarised as an entry count).
"""
import json
import os
import sys
import tarfile

TYPES = {
    tarfile.REGTYPE: "REG",
    tarfile.AREGTYPE: "REG",
    tarfile.DIRTYPE: "DIR",
    tarfile.SYMTYPE: "SYM",
    tarfile.LNKTYPE: "LNK",
    tarfile.CHRTYPE: "CHR",
    tarfile.BLKTYPE: "BLK",
    tarfile.FIFOTYPE: "FIFO",
}
WH_PREFIX = ".wh."
MAX_CONTENT = 200


def blob(root, digest):
    algo, hexd = digest.split(":", 1)
    return os.path.join(root, "blobs", algo, hexd)


def load_json(path):
    with open(path) as f:
        return json.load(f)


def resolve_manifest(root):
    """Return (config, [layer paths]) for the single image in root."""
    index = load_json(os.path.join(root, "index.json"))
    desc = index["manifests"][0]
    manifest = load_json(blob(root, desc["digest"]))

    # Follow nested indexes (e.g. docker save wraps an index in an index).
    while "manifests" in manifest:
        desc = manifest["manifests"][0]
        manifest = load_json(blob(root, desc["digest"]))

    config = load_json(blob(root, manifest["config"]["digest"]))
    layers = [blob(root, layer["digest"]) for layer in manifest["layers"]]
    return config, layers


def layer_history(config):
    return [h for h in config.get("history", []) if not h.get("empty_layer")]


def describe(tf, m):
    kind = TYPES.get(m.type, repr(m.type))
    line = f"  {kind:4} {m.mode:04o} {m.uid}:{m.gid} size={m.size:<4} {m.name}"

    if m.type in (tarfile.CHRTYPE, tarfile.BLKTYPE):
        line += f"  (dev {m.devmajor}:{m.devminor})"
    if m.pax_headers:
        line += f"  pax={dict(m.pax_headers)}"
    if os.path.basename(m.name.rstrip("/")).startswith(WH_PREFIX):
        line += "   <-- .wh. name"
    if m.isreg() and m.size <= MAX_CONTENT:
        content = tf.extractfile(m).read().decode(errors="replace").rstrip("\n")
        line += f"\n         content: {content!r}"
    return line


def main():
    root = sys.argv[1]
    show_all = "--all" in sys.argv
    config, layers = resolve_manifest(root)
    history = layer_history(config)

    for i, path in enumerate(layers):
        created_by = history[i].get("created_by", "?") if i < len(history) else "?"
        print(f"== layer {i}: {os.path.relpath(path, root)}")
        print(f"   created_by: {created_by}")

        with tarfile.open(path, "r:*") as tf:
            members = tf.getmembers()
            shown = [m for m in members if show_all or m.name.startswith("tmp")]
            if not shown:
                print(f"   ({len(members)} entries, none under tmp/)")
                continue
            for m in shown:
                print(describe(tf, m))


if __name__ == "__main__":
    main()
