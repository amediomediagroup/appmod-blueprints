#!/bin/sh

split=$1
extraargs=$2 # Not curretnly used but holds the extra args variable passed if needed.
echo "$split"

serviceName=${split%%:*}  # Extract the service name
port=${split#*:}   # Extract the port

# Run artillery with provided arguments
run run -t http://$serviceName /scripts/benchmark.yaml