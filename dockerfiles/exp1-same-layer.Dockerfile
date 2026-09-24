# Experiment 1: foo and .wh.foo copied in the SAME instruction (same layer).
FROM alpine:3.20
COPY foo .wh.foo /tmp/
RUN echo "--- ls -la /tmp ---" && ls -la /tmp && for p in /tmp/foo /tmp/.wh.foo; do if [ -e "$p" ]; then echo "EXISTS  $p :: $(cat "$p")"; else echo "MISSING $p"; fi; done
