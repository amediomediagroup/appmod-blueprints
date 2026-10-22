"""Enable the native AKS AGC addon through Crossplane, then release its GitOps gate.

No Azure write is issued directly: az is used only for addon identity readback.
Invoke after the normal Azure claim is Ready; subscription registration must be authorized.
"""
import argparse
import ipaddress
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time


def run(*args, payload=None):
    result = subprocess.run(args, input=payload, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE)
    if result.returncode:
        raise RuntimeError(f"{' '.join(args[:5])}: {result.stderr.strip()}")
    return result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--values', required=True, help='Azure bootstrap chart values YAML')
    parser.add_argument('--bootstrap-kubeconfig', required=True)
    parser.add_argument('--aks-kubeconfig', required=True)
    parser.add_argument('--cluster-key', default='hub')
    parser.add_argument('--chart', default=str(Path(__file__).resolve().parents[2] /
                        'gitops/abstractions/crossplane/azure-platform-cluster'))
    args = parser.parse_args()
    values = json.loads(run('yq', '-o=json', '.', args.values))
    cluster = values['clusters'][args.cluster_key]
    if len(values['clusters']) != 1:
        raise ValueError('Use a single-cluster values file for this bootstrap operation.')
    agc = cluster['agc']
    if agc.get('enabled') is not True:
        raise ValueError('This command requires agc.enabled=true; disabling needs a reviewed teardown.')
    cidr = ipaddress.ip_network(agc['subnetCidr'])
    if cidr.version != 4 or cidr.prefixlen > 24:
        raise ValueError('AGC requires a dedicated IPv4 /24 or larger subnet.')
    name = cluster['clusterName']
    subscription = cluster.get('subscriptionId') or values['global']['subscriptionId']
    group = cluster['resourceGroup']
    k = ['kubectl', '--kubeconfig', args.bootstrap_kubeconfig]
    a = ['kubectl', '--kubeconfig', args.aks_kubeconfig]

    def get(kind, resource, *extra):
        return json.loads(run(*k, 'get', kind, resource, *extra, '-o', 'json'))

    def apply(doc):
        return run(*k, 'apply', '-f', '-', payload=json.dumps(doc))

    def render(template):
        return [d for d in json.loads(run('yq', 'eval-all', '-o=json', '-I=0',
                '[.]', '-', payload=run('helm', 'template', 'azure-platform', args.chart,
                '-f', args.values, '--show-only', 'templates/' + template))) if d]

    def wait(kind, resource):
        deadline = time.monotonic() + 900
        while time.monotonic() < deadline:
            state = get(kind, resource)
            conditions = {c['type']: c for c in state.get('status', {}).get('conditions', [])}
            # Connecting the provider client is not an Azure operation result.
            # Wait through initialization; surface actual async operation failures.
            observed = conditions.get('LastAsyncOperation', {})
            if observed.get('status') == 'False':
                raise RuntimeError(f"{kind}/{resource}: {observed.get('message', observed.get('reason', 'reconciliation failed'))}")
            synced = conditions.get('Synced', {})
            if (synced.get('status') == 'True'
                    and synced.get('observedGeneration') == state['metadata']['generation']
                    and conditions.get('Ready', {}).get('status') == 'True'):
                return
            time.sleep(2)
        raise RuntimeError(f"{kind}/{resource}: timed out waiting for current-generation Ready/Synced")

    # Revoke a previously published readiness label before any reconfiguration.
    run(*a, '-n', 'argocd', 'label', 'secret', name, 'agc_native_ready-', '--overwrite')
    registrations = render('registrations.yaml')
    required = {'Microsoft.ContainerService', 'Microsoft.Network',
                'Microsoft.NetworkFunction', 'Microsoft.ServiceNetworking'}
    by_namespace = {d['spec']['forProvider']['name']: d for d in registrations}
    if not required.issubset(by_namespace):
        raise ValueError('Values must declare all four AGC provider registrations.')
    features = {f['name'] for f in by_namespace['Microsoft.ContainerService']['spec']['forProvider'].get('feature', []) if f['registered']}
    if not {'ManagedGatewayAPIPreview', 'ApplicationLoadBalancerPreview'}.issubset(features):
        raise ValueError('Both native addon preview features must be registered.')
    existing = json.loads(run(*k, 'get', 'resourceproviderregistrations.azure.upbound.io', '-o', 'json'))
    expected_names = {d['metadata']['annotations']['crossplane.io/external-name']: d['metadata']['name'] for d in registrations}
    for resource in existing['items']:
        external = resource['metadata'].get('annotations', {}).get('crossplane.io/external-name')
        if external in expected_names and resource['metadata']['name'] != expected_names[external]:
            raise ValueError('Registration already has another owner: ' + resource['metadata']['name'])
    for doc in registrations:
        apply(doc)
    for doc in registrations:
        wait('resourceproviderregistrations.azure.upbound.io', doc['metadata']['name'])

    providers = render('agc-provider.yaml')
    if not providers:
        raise ValueError('nativeAgcProvider.enabled and its federated identity must be configured.')
    for doc in providers:
        if doc['kind'] != 'ProviderConfig':
            apply(doc)
    run(*k, 'wait', '--for=condition=Healthy', 'providers.pkg.crossplane.io/provider-azapi', '--timeout=600s')
    for doc in providers:
        if doc['kind'] == 'ProviderConfig':
            apply(doc)

    # Extend only the owned VNet field, never reapply an unrelated live Composition.
    claim = get('azureplatformclusters.platform.gitops.io', name, '-n', 'crossplane-system')
    comp_name = get('xazureplatformclusters.platform.gitops.io', claim['spec']['resourceRef']['name'])['spec']['compositionRef']['name']
    comp = get('composition', comp_name)
    resources = comp['spec']['pipeline'][0]['input']['resources']
    vnet_index = next(i for i, r in enumerate(resources) if r['name'] == 'vnet')
    xr = get('xazureplatformclusters.platform.gitops.io', claim['spec']['resourceRef']['name'])
    vnet_id = xr['status']['vnetId']
    live_vnet = json.loads(run('az', 'network', 'vnet', 'show', '--ids', vnet_id, '-o', 'json'))
    for subnet in live_vnet.get('subnets', []):
        if subnet['name'] == name + '-agc-snet':
            if ipaddress.ip_network(subnet['addressPrefix']) != cidr:
                raise ValueError('Refusing to resize an existing AGC subnet.')
            continue
        prefixes = subnet.get('addressPrefixes') or [subnet['addressPrefix']]
        if any(cidr.overlaps(ipaddress.ip_network(p)) for p in prefixes):
            raise ValueError('AGC subnet overlaps an existing subnet.')
    prefixes = live_vnet['addressSpace']['addressPrefixes']
    if any(cidr.overlaps(ipaddress.ip_network(p)) for p in prefixes if p != str(cidr)):
        raise ValueError('Use a distinct additional VNet prefix for the AGC subnet.')
    # This existing claim-based XRD must be updated through the legacy v1 API.
    xrd_resource = 'compositeresourcedefinitions.v1.apiextensions.crossplane.io'
    xrd = get(xrd_resource, 'xazureplatformclusters.platform.gitops.io')
    target = next(i for i, v in enumerate(xrd['spec']['versions']) if v['name'] == 'v1alpha1')
    path = f'/spec/versions/{target}/schema/openAPIV3Schema/properties/spec/properties/agcSubnetCidr'
    run(*k, 'patch', xrd_resource, xrd['metadata']['name'], '--type=json', '-p', json.dumps([
        {'op': 'add', 'path': path, 'value': {'type': 'string'}}]))
    for crd_name in ('azureplatformclusters.platform.gitops.io',
                     'xazureplatformclusters.platform.gitops.io'):
        run(*k, 'wait',
            '--for=jsonpath={.spec.versions[?(@.name=="v1alpha1")].schema.openAPIV3Schema.properties.spec.properties.agcSubnetCidr.type}=string',
            'crd/' + crd_name, '--timeout=120s')
    # Crossplane caches the XR schema. This marker triggers one rollout for this addition.
    run(*k, '-n', 'crossplane-system', 'patch', 'deployment', 'crossplane',
        '--type=merge', '-p', json.dumps({'spec': {'template': {'metadata': {
            'annotations': {'platform.gitops.io/agc-schema': 'v1'}}}}}))
    run(*k, '-n', 'crossplane-system', 'rollout', 'status', 'deployment/crossplane',
        '--timeout=180s')
    patches = resources[vnet_index].get('patches', [])
    if not any(p.get('fromFieldPath') == 'spec.agcSubnetCidr' for p in patches):
        if len(prefixes) > 1 and prefixes[1] != str(cidr):
            raise ValueError('VNet already has another additional prefix; refusing to overwrite it.')
        run(*k, 'patch', 'composition', comp_name, '--type=json', '-p', json.dumps([
            {'op': 'test', 'path': f'/spec/pipeline/0/input/resources/{vnet_index}/name', 'value': 'vnet'},
            {'op': 'add', 'path': f'/spec/pipeline/0/input/resources/{vnet_index}/patches/-',
             'value': {'type': 'FromCompositeFieldPath', 'fromFieldPath': 'spec.agcSubnetCidr',
                       'toFieldPath': 'spec.forProvider.addressSpace[1]',
                       'policy': {'fromFieldPath': 'Optional'}}}]))
    run(*k, '-n', 'crossplane-system', 'patch', 'azureplatformcluster', name,
        '--type=merge', '-p', json.dumps({'spec': {'agcSubnetCidr': str(cidr)}}))
    run(*k, 'wait', '--for=jsonpath={.spec.agcSubnetCidr}=' + str(cidr),
        'xazureplatformclusters.platform.gitops.io/' + xr['metadata']['name'], '--timeout=120s')
    vnet_ref = next(r for r in xr['spec']['resourceRefs'] if r['kind'] == 'VirtualNetwork')
    run(*k, 'wait', f'--for=jsonpath={{.spec.forProvider.addressSpace[?(@=="{cidr}")]}}={cidr}',
        'virtualnetworks.network.azure.upbound.io/' + vnet_ref['name'], '--timeout=180s')
    wait('virtualnetworks.network.azure.upbound.io', vnet_ref['name'])
    for doc in render('agc-subnet.yaml'):
        apply(doc)
        wait('subnets.network.azure.upbound.io', doc['metadata']['name'])
    for doc in render('native-agc.yaml'):
        apply(doc)
        wait('updateresources.resources.azapi.upbound.io', doc['metadata']['name'])
    run(*a, 'wait', '--for=condition=Accepted', 'gatewayclass/azure-alb-external', '--timeout=600s')
    node_group = run('az', 'aks', 'show', '-g', group, '-n', name,
                     '--query', 'nodeResourceGroup', '-o', 'tsv').strip()
    principal = run('az', 'identity', 'show', '-g', node_group,
                    '-n', 'applicationloadbalancer-' + name,
                    '--query', 'principalId', '-o', 'tsv').strip()
    if not principal:
        raise ValueError('Native addon managed identity has no principalId.')
    # Add only the new native identity to the dedicated subnet; no subscription role.
    with tempfile.TemporaryDirectory(prefix='agc-values-') as tmp:
        cluster['agc']['principalId'] = principal
        path = Path(tmp) / 'values.json'
        path.write_text(json.dumps(values))
        permission = run('helm', 'template', 'azure-platform', args.chart, '-f', str(path),
                         '--show-only', 'templates/agc-permissions.yaml')
        print(run(*k, 'apply', '-f', '-', payload=permission), end='')
    wait('roleassignments.authorization.azure.upbound.io', name + '-native-agc-subnet')
    subnet_id = f'/subscriptions/{subscription}/resourceGroups/{group}/providers/Microsoft.Network/virtualNetworks/{name}-vnet/subnets/{name}-agc-snet'
    run(*a, '-n', 'argocd', 'annotate', 'secret', name,
        'azure_agc_subnet_id=' + subnet_id, '--overwrite')
    run(*a, '-n', 'argocd', 'label', 'secret', name, 'agc_native_ready=true', '--overwrite')
    print('Native AGC prerequisites Ready; GitOps Gateway gate published. External traffic not yet verified.')


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, ValueError, KeyError, StopIteration) as error:
        print(f'AGC bootstrap stopped: {error}', file=sys.stderr)
        sys.exit(1)
