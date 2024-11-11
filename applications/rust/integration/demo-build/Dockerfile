FROM artilleryio/artillery:latest

COPY benchmark.yaml /scripts/benchmark.yaml

# <service-name>.<namespace>.svc.cluster.local:<service-port>
COPY start-script.sh /
RUN chmod +x /start-script.sh
ENTRYPOINT [ "/start-script.sh" ]
CMD [ "$SERVICE_URL", "$BENCHMARK_FILE" ]