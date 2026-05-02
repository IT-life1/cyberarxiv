FROM python:3.10-slim

WORKDIR /app

COPY mcp_server/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY mcp_server/ .

ENV CYBERARXIV_DB_PATH=/data/cyberarxiv.duckdb
ENV ML_SERVICE_URL=http://cyberarxiv-ml:5001
ENV ML_DEFAULT_MODEL=best_model

CMD ["python", "server.py"]
