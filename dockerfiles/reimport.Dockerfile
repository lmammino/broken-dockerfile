# Uses an exported OCI layout as base (via --build-context base=oci-layout://...)
# so BuildKit must unpack the serialized layers again.
FROM base
RUN for d in /tmp /tmp/dir; do [ -d $d ] && echo "--- ls -la $d ---" && ls -la $d; done; \
    for p in /tmp/foo /tmp/.wh.foo /tmp/dir/a /tmp/dir/b /tmp/dir/c /tmp/dir/.wh..wh..opq /tmp/.wh.; do \
      if [ -e "$p" ]; then echo "EXISTS  $p :: $(cat "$p")"; else echo "MISSING $p"; fi; done
