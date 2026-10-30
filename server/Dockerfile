# Signaling server image. Build from the server/ directory:
#   docker build -t ght-signaling server/
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt \
    && useradd --system --no-create-home --uid 10001 signal

COPY signaling_server.py .

USER signal
EXPOSE 8765
HEALTHCHECK --interval=30s --timeout=3s --retries=3 \
    CMD python -c "import os,urllib.request,ssl; s='https' if os.environ.get('GHT_SIGNAL_CERT') else 'http'; urllib.request.urlopen(s+'://127.0.0.1:'+os.environ.get('GHT_SIGNAL_PORT','8765')+'/healthz', timeout=2, context=ssl._create_unverified_context())" || exit 1

ENTRYPOINT ["python", "signaling_server.py"]
