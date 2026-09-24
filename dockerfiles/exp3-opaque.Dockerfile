# Experiment 3: /tmp/dir/{a,b} exist in a LOWER layer, a later COPY adds
# .wh..wh..opq (plus a new file c) into /tmp/dir.
FROM alpine:3.20
RUN mkdir /tmp/dir && echo lower-a > /tmp/dir/a && echo lower-b > /tmp/dir/b
RUN echo "--- ls -la /tmp/dir ---" && ls -la /tmp/dir && for p in /tmp/dir/a /tmp/dir/b /tmp/dir/c /tmp/dir/.wh..wh..opq; do if [ -e "$p" ]; then echo "EXISTS  $p :: $(cat "$p")"; else echo "MISSING $p"; fi; done
COPY .wh..wh..opq c /tmp/dir/
RUN echo "--- ls -la /tmp/dir ---" && ls -la /tmp/dir && for p in /tmp/dir/a /tmp/dir/b /tmp/dir/c /tmp/dir/.wh..wh..opq; do if [ -e "$p" ]; then echo "EXISTS  $p :: $(cat "$p")"; else echo "MISSING $p"; fi; done
