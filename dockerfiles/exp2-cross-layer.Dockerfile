# Experiment 2: foo exists in a LOWER layer, .wh.foo is added in a LATER layer.
FROM alpine:3.20
COPY foo /tmp/foo
RUN echo "--- ls -la /tmp ---" && ls -la /tmp && for p in /tmp/foo /tmp/.wh.foo; do if [ -e "$p" ]; then echo "EXISTS  $p :: $(cat "$p")"; else echo "MISSING $p"; fi; done
COPY .wh.foo /tmp/.wh.foo
RUN echo "--- ls -la /tmp ---" && ls -la /tmp && for p in /tmp/foo /tmp/.wh.foo; do if [ -e "$p" ]; then echo "EXISTS  $p :: $(cat "$p")"; else echo "MISSING $p"; fi; done
