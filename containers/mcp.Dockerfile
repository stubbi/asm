FROM python:3.14-slim-bookworm@sha256:516b51cb9db2ef061e465c803e50f64361b82cefd91e525b889b967b83e83527

ARG ASM_SOURCE_REVISION
ENV ASM_SOURCE_REVISION=${ASM_SOURCE_REVISION} \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    HOME=/nonexistent
LABEL org.opencontainers.image.source="https://github.com/stubbi/asm" \
      org.opencontainers.image.licenses="AGPL-3.0-or-later" \
      org.opencontainers.image.revision=${ASM_SOURCE_REVISION}

WORKDIR /app
COPY requirements-mcp.txt /app/requirements-mcp.txt
RUN python -c 'import os,re; value=os.environ["ASM_SOURCE_REVISION"]; assert re.fullmatch("[0-9a-f]{40}",value) and value != "0"*40' \
    && python -m pip install --no-cache-dir --only-binary=:all: --require-hashes -r /app/requirements-mcp.txt
COPY tools/mcp_server.py tools/agent_catalog.py tools/agent_workflow.py tools/registry.py /app/tools/
COPY skills/asm-build /app/skills/asm-build
COPY LICENSE /app/LICENSE

USER 65532:65532
EXPOSE 8080
STOPSIGNAL SIGTERM
ENTRYPOINT ["python", "/app/tools/mcp_server.py"]
CMD ["--transport", "streamable-http", "--host", "0.0.0.0", "--port", "8080", "--public-origin", "https://api.asm.build", "--catalog-source", "internal"]
