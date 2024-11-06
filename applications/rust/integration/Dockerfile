FROM artilleryio/artillery:latest

COPY benchmark.yaml /scripts/benchmark.yaml

# <service-name>.<namespace>.svc.cluster.local:<service-port>
CMD ["run", "-t", "http://rust-backend", "/scripts/benchmark.yaml"]