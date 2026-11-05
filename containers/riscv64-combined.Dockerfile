# SPDX-License-Identifier: AGPL-3.0-or-later
# This tag is built locally from the exact pinned hosted Dockerfile build stage.
ARG ASM_BUILD_IMAGE
FROM ${ASM_BUILD_IMAGE} AS qualification
ARG ASM_HOSTED_BUILD_ID
ARG ASM_CANDIDATE_REVISION
RUN apt-get update \
    && apt-get install --no-install-recommends --yes python3 openssl \
    && rm -rf /var/lib/apt/lists/* \
    && printf 'asm:x:65532:65532:Asm qualification:/nonexistent:/usr/sbin/nologin\n' >> /etc/passwd \
    && printf 'asm:x:65532:\n' >> /etc/group \
    && install -d -o 65532 -g 65532 -m 0700 /work /work/evidence
COPY candidate /inputs/candidate
COPY package-source /inputs/package-source
COPY input-manifest.json /inputs/input-manifest.json
LABEL build.asm.hosted-build-id=${ASM_HOSTED_BUILD_ID} \
      build.asm.candidate-revision=${ASM_CANDIDATE_REVISION}
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 LC_ALL=C QEMU_LD_PREFIX=/
USER 65532:65532
WORKDIR /work
ENTRYPOINT ["/usr/bin/python3", "/inputs/candidate/tools/riscv64_combined.py", "--inside"]
CMD []
