FROM artilleryio/artillery:latest

COPY benchmark.yaml /scripts/benchmark.yaml

WORKDIR /scripts

# Run the Artillery benchmark with the provided benchmark.yaml file
CMD [ "run", "benchmark.yaml" ]
