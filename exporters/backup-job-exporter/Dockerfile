FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY main.py collector.py ./
ENV STATUS_DIR=/status
ENV EXPORTER_PORT=9301
EXPOSE 9301
CMD ["python", "main.py"]
