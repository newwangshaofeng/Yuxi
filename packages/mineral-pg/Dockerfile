FROM python:3.13-slim
WORKDIR /app
RUN pip install --no-cache-dir uv==0.12.6
COPY pyproject.toml uv.lock ./
RUN uv sync --locked --no-dev --no-install-project
COPY src ./src
RUN uv sync --locked --no-dev && useradd --uid 10001 --create-home mineral
USER mineral
ENV PATH="/app/.venv/bin:$PATH"
EXPOSE 8061
CMD ["mineral-pg"]
