FROM ghcr.io/amediomediagroup/upstream/python:3.12-alpine@sha256:4c47124a8391cb7a9f571164147d154777cf012a4ece5f86097130d7a4478111
WORKDIR /app
COPY . .
RUN pip install requests
ENTRYPOINT ["python"]
CMD ["app.py"]