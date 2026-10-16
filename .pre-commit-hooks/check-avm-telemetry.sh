#!/usr/bin/env bash
# check-avm-telemetry.sh
# Ensures all AVM (Azure Verified Module) module blocks explicitly set
# enable_telemetry = false. AVM modules send usage telemetry to Microsoft
# by default — this must be disabled for enterprise/air-gapped environments.
#
# PASS:  module "acr" { enable_telemetry = false ... }
# FAIL:  module "acr" { ... }                         (missing)
# FAIL:  module "acr" { enable_telemetry = true ... } (explicitly enabled)
#
# Detection: modules sourced from Azure AVM registry paths:
#   Azure/avm-*  |  azure/avm-*

set -euo pipefail

ERRORS=0

for file in "$@"; do
  [[ "$file" == *.tf ]] || continue

  # Extract module blocks that use AVM sources
  # Parse module name + source, then check for enable_telemetry in the same block
  python3 - "$file" << 'PYEOF'
import sys, re

file = sys.argv[1]
content = open(file).read()

# Find all module blocks
module_pattern = re.compile(
    r'module\s+"([^"]+)"\s*\{([^}]*(?:\{[^}]*\}[^}]*)*)\}',
    re.DOTALL
)

errors = 0
for m in module_pattern.finditer(content):
    name = m.group(1)
    body = m.group(2)

    # Check if this is an AVM module
    source_match = re.search(r'source\s*=\s*"([^"]*)"', body)
    if not source_match:
        continue
    source = source_match.group(1)

    # Only check Azure AVM modules
    if not re.search(r'[Aa]zure/avm-', source):
        continue

    # Check for enable_telemetry
    telemetry_match = re.search(r'enable_telemetry\s*=\s*(true|false)', body)
    if not telemetry_match:
        line = content[:m.start()].count('\n') + 1
        print(f"❌ {file}:{line} — module \"{name}\" ({source})")
        print(f"   Missing: enable_telemetry = false")
        errors += 1
    elif telemetry_match.group(1) == 'true':
        line = content[:m.start()].count('\n') + 1
        print(f"❌ {file}:{line} — module \"{name}\" ({source})")
        print(f"   enable_telemetry = true  (must be false)")
        errors += 1

sys.exit(errors)
PYEOF
  ERRORS=$((ERRORS + $?))
done

if [ "$ERRORS" -gt 0 ]; then
  echo ""
  echo "All AVM modules must set: enable_telemetry = false"
  echo "This disables Microsoft telemetry collection for enterprise deployments."
  exit 1
fi
echo "✓ All AVM modules have enable_telemetry = false"
