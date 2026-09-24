# Experiment 4: a file named exactly ".wh." (empty whiteout target).
FROM alpine:3.20
COPY .wh. /tmp/.wh.
RUN echo "--- ls -la /tmp ---" && ls -la /tmp && for p in /tmp/.wh.; do if [ -e "$p" ]; then echo "EXISTS  $p :: $(cat "$p")"; else echo "MISSING $p"; fi; done
