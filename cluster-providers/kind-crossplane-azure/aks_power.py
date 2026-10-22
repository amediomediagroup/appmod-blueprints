"""Supervised AKS stop/start that preserves Crossplane ownership.

Crossplane stays on Kind and remains the desired-state owner. A full-cluster
stop is only safe if the AKS managed resource cannot reconcile while stopped,
so this helper suspends reconciliation first, then restores it.

Usage:
  aks_power.py stop  --bootstrap-kubeconfig K --subscription S --resource-group R --cluster C
  aks_power.py start --bootstrap-kubeconfig K --subscription S --resource-group R --cluster C
  aks_power.py status --bootstrap-kubeconfig K --subscription S --resource-group R --cluster C
"""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import time

AKS_ID_TEMPLATE = ('/subscriptions/{sub}/resourceGroups/{rg}'
                   '/providers/Microsoft.ContainerService/managedClusters/{name}')
# Crossplane on Kind is the owner of these; both must be suspended together.
DEPENDENT_KINDS = (
    ('kubernetesclusters.containerservice.azure.upbound.io', 'spec.managementPolicies'),
    ('kubernetesclusternodepools.containerservice.azure.upbound.io', 'spec.managementPolicies'),
)


def run(*args):
    result = subprocess.run(args, text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(f"{' '.join(args[:4])}: {result.stderr.strip()}")
    return result.stdout


def kubectl(kubeconfig, *args):
    return run('kubectl', '--kubeconfig', kubeconfig, *args)


def managed_resources(kubeconfig, cluster_id):
    """Find Crossplane MRs whose Azure identity belongs to this cluster."""
    found = []
    for kind, policies in DEPENDENT_KINDS:
        items = json.loads(kubectl(kubeconfig, 'get', kind, '-o', 'json'))['items']
        for item in items:
            external = str(item['metadata'].get('annotations', {}).get('crossplane.io/external-name', ''))
            for_provider = item.get('spec', {}).get('forProvider', {})
            parent = str(for_provider.get('kubernetesClusterId', ''))
            observed = str(item.get('status', {}).get('atProvider', {}).get('id', ''))
            if any(cluster_id.lower() in value.lower()
                   for value in (external, parent, observed) if value):
                found.append({'kind': kind, 'name': item['metadata']['name'],
                              'policiesPath': policies,
                              'policies': item['spec'].get('managementPolicies', ['*'])})
    return found


def set_policies(kubeconfig, entry, policies):
    patch = json.dumps([{'op': 'replace', 'path': '/spec/managementPolicies', 'value': policies}])
    kubectl(kubeconfig, 'patch', entry['kind'], entry['name'], '--type=json', '-p', patch)
    deadline = time.monotonic() + 300
    while time.monotonic() < deadline:
        item = json.loads(kubectl(kubeconfig, 'get', entry['kind'], entry['name'], '-o', 'json'))
        if item['spec'].get('managementPolicies') == policies:
            return
        time.sleep(2)
    raise RuntimeError(f"{entry['kind']}/{entry['name']}: policies did not converge")


def wait_power_state(args, wanted, timeout=3600):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        state = run('az', 'aks', 'show', '-g', args.resource_group, '-n', args.cluster,
                    '--query', 'powerState.code', '-o', 'tsv').strip()
        if state == wanted:
            return state
        if state == 'Failed':
            raise RuntimeError('AKS reported powerState Failed')
        time.sleep(15)
    raise RuntimeError(f'AKS did not reach {wanted}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['stop', 'start', 'status'])
    parser.add_argument('--bootstrap-kubeconfig', required=True)
    parser.add_argument('--subscription', required=True)
    parser.add_argument('--resource-group', required=True)
    parser.add_argument('--cluster', required=True)
    parser.add_argument('--evidence', help='Append a JSON record to this path')
    args = parser.parse_args()
    cluster_id = AKS_ID_TEMPLATE.format(sub=args.subscription, rg=args.resource_group,
                                        name=args.cluster)
    entries = managed_resources(args.bootstrap_kubeconfig, cluster_id)
    if not entries:
        raise ValueError('No Crossplane managed resource matched this AKS cluster; refusing to act.')

    if args.action == 'status':
        print(json.dumps({'clusterId': cluster_id, 'managed': entries,
                          'powerState': run('az', 'aks', 'show', '-g', args.resource_group,
                                            '-n', args.cluster, '--query', 'powerState.code',
                                            '-o', 'tsv').strip()}, indent=2))
        return

    record = {'at': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
              'action': args.action, 'clusterId': cluster_id, 'managed': []}
    if args.action == 'stop':
        # Suspend the owner BEFORE the cloud write so a stopped cluster is never
        # reconciled. Absence of a powerState field is not proof of safety.
        for entry in entries:
            set_policies(args.bootstrap_kubeconfig, entry, ['Observe'])
            record['managed'].append({'kind': entry['kind'], 'name': entry['name'],
                                      'suspended': True})
        run('az', 'aks', 'stop', '--subscription', args.subscription,
            '-g', args.resource_group, '-n', args.cluster, '--no-wait')
        record['powerState'] = wait_power_state(args, 'Stopped')
    else:
        # Resume only after the cluster is healthy again.
        run('az', 'aks', 'start', '--subscription', args.subscription,
            '-g', args.resource_group, '-n', args.cluster, '--no-wait')
        record['powerState'] = wait_power_state(args, 'Running')
        for entry in entries:
            set_policies(args.bootstrap_kubeconfig, entry, entry['policies'])
            record['managed'].append({'kind': entry['kind'], 'name': entry['name'],
                                      'suspended': False})
    if args.evidence:
        path = Path(args.evidence)
        history = json.loads(path.read_text()) if path.exists() else []
        history.append(record)
        path.write_text(json.dumps(history, indent=2) + '\n')
    print(json.dumps(record, indent=2))


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, ValueError, KeyError, OSError) as error:
        print(f'AKS power action stopped: {error}', file=sys.stderr)
        sys.exit(1)
