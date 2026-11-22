FROM python:3.12-alpine
COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt && rm /tmp/requirements.txt
WORKDIR /app
COPY render.py zk_watcher.py /app/
# Runs as root on purpose: signalling the nginx master (root, in a shared PID namespace) needs the
# same uid. The compose file drops every capability and makes the filesystem read-only.
ENV PYTHONUNBUFFERED=1
CMD ["python", "/app/zk_watcher.py"]
