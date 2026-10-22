"""Explicit registration IAM grant/status/revoke with an ownership journal.

Pass the original change evidence file to adopt an earlier owned grant. Merely
finding a matching existing Azure role does not confer deletion ownership.
"""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import uuid

ROLE_NAME = 'AEGIS AGC Registration Operator'
ACTIONS = {
    'Microsoft.Resources/subscriptions/providers/read',
    'Microsoft.ContainerService/register/action',
    'Microsoft.Network/register/action',
    'Microsoft.NetworkFunction/register/action',
    'Microsoft.ServiceNetworking/register/action',
    'Microsoft.Features/features/read',
    'Microsoft.Features/providers/features/read',
    'Microsoft.Features/providers/features/register/action',
}


def az(*args):
    result = subprocess.run(['az', *args, '-o', 'json'], text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(result.stderr.strip())
    return json.loads(result.stdout) if result.stdout.strip() else None


def save(path, record, action):
    record.setdefault('events', []).append({
        'at': datetime.now(timezone.utc).isoformat(), 'action': action})
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile('w', dir=path.parent, delete=False) as stream:
        json.dump(record, stream, indent=2)
        stream.write('\n')
        temp = stream.name
    os.replace(temp, path)


def validate_role(role, scope):
    permissions = role.get('permissions', [])
    if (role.get('roleName') != ROLE_NAME or len(permissions) != 1
            or set(permissions[0].get('actions', [])) != ACTIONS
            or permissions[0].get('notActions') or permissions[0].get('dataActions')
            or permissions[0].get('notDataActions')
            or role.get('assignableScopes') != [scope]):
        raise ValueError('Existing role differs from the narrow registration definition; refusing to modify/adopt it.')


def owned(record, kind):
    if kind + 'Owned' in record:
        return record[kind + 'Owned'] is True
    # Import the original recorded change format, never infer ownership from Azure.
    return (record.get(kind + 'Preexisting') is False
            and bool(record.get(kind + 'Id')))


def imports(record):
    if record.get('roleDefinitionId'):
        print('terraform import azurerm_role_definition.agc_registration '
              + repr(record['roleDefinitionId'] + '|' + record['scope']))
    if record.get('assignmentId'):
        print('terraform import azurerm_role_assignment.agc_registration '
              + repr(record['assignmentId']))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['grant', 'status', 'revoke'])
    parser.add_argument('--subscription', required=True)
    parser.add_argument('--principal-id')
    parser.add_argument('--role-guid')
    parser.add_argument('--assignment-guid')
    parser.add_argument('--evidence-path', required=True)
    parser.add_argument('--role-json', default=str(Path(__file__).with_name('registration-role.json')))
    parser.add_argument('--confirm', choices=['yes'])
    args = parser.parse_args()
    scope = '/subscriptions/' + str(uuid.UUID(args.subscription))
    path = Path(args.evidence_path)
    record = json.loads(path.read_text()) if path.exists() else {}
    if record and record.get('scope') != scope:
        raise ValueError('Evidence scope does not match requested subscription.')
    principal = args.principal_id or record.get('principalId')
    if not principal:
        raise ValueError('Provide --principal-id or the original evidence file.')
    principal = str(uuid.UUID(principal))
    if record.get('principalId', principal).lower() != principal:
        raise ValueError('Evidence principal does not match requested identity.')
    record.update({'scope': scope, 'principalId': principal})
    role_guid = args.role_guid or record.get('roleDefinitionGuid')
    roles = az('role', 'definition', 'list', '--name', role_guid or ROLE_NAME,
               '--scope', scope)
    if len(roles) > 1:
        raise ValueError('Multiple matching roles; use the recorded role GUID.')
    role = roles[0] if roles else None
    if role:
        validate_role(role, scope)
        if record.get('roleDefinitionId', role['id']).lower() != role['id'].lower():
            raise ValueError('Evidence role ID differs from Azure.')
    assignments = az('role', 'assignment', 'list', '--assignee-object-id', principal, '--all')
    matching = [a for a in assignments if role and a['scope'].lower() == scope.lower()
                and a['roleDefinitionId'].lower() == role['id'].lower()]
    if len(matching) > 1:
        raise ValueError('Duplicate assignments; reconcile ownership before proceeding.')
    assignment = matching[0] if matching else None
    if assignment and record.get('assignmentId', assignment['id']).lower() != assignment['id'].lower():
        raise ValueError('Evidence assignment ID differs from Azure.')

    if args.command == 'status':
        print(json.dumps({'roleDefinitionId': role['id'] if role else None,
                          'assignmentId': assignment['id'] if assignment else None,
                          'roleOwned': owned(record, 'roleDefinition'),
                          'assignmentOwned': owned(record, 'assignment')}, indent=2))
        imports(record)
        return

    if args.command == 'revoke':
        if args.confirm != 'yes' or not path.exists():
            raise ValueError('Revoke requires --confirm yes and existing ownership evidence.')
        if assignment and not owned(record, 'assignment'):
            raise ValueError('Existing assignment is not recorded as owned; refusing deletion.')
        if assignment:
            az('role', 'assignment', 'delete', '--ids', assignment['id'])
            save(path, record, 'owned-assignment-removed')
        if role and owned(record, 'roleDefinition'):
            remaining = az('role', 'assignment', 'list', '--role', role['id'], '--all')
            if remaining:
                save(path, record, 'role-retained-other-assignments')
                print('Role retained: other assignments still use it.')
            else:
                az('role', 'definition', 'delete', '--name', role['name'], '--scope', scope)
                save(path, record, 'owned-role-removed')
        save(path, record, 'revoke-completed')
        return

    # Persist ownership before each next step so partial grants can be traced/revoked.
    if 'actor' not in record:
        record['actor'] = az('account', 'show', '--query',
                             '{subscription:id,tenant:tenantId,user:user.name,type:user.type}')
    role_owned = owned(record, 'roleDefinition')
    assignment_owned = owned(record, 'assignment')
    if not role:
        body = json.loads(Path(args.role_json).read_text().replace('{{SUBSCRIPTION_ID}}', args.subscription))
        if (set(body['Actions']) != ACTIONS or body['AssignableScopes'] != [scope]
                or body.get('NotActions') or body.get('DataActions') or body.get('NotDataActions')):
            raise ValueError('Role template differs from the authorized registration permissions.')
        if role_guid:
            body['Id'] = scope + '/providers/Microsoft.Authorization/roleDefinitions/' + str(uuid.UUID(role_guid))
        with tempfile.TemporaryDirectory(prefix='agc-role-') as tmp:
            template = Path(tmp) / 'role.json'
            template.write_text(json.dumps(body))
            role = az('role', 'definition', 'create', '--role-definition', str(template))
        role_owned = True
    record.setdefault('roleDefinitionPreexisting', not role_owned)
    record.update({'roleDefinitionOwned': role_owned, 'roleDefinitionId': role['id'],
                   'roleDefinitionGuid': role['name']})
    save(path, record, 'role-created' if role_owned and not roles else 'role-verified')
    if not assignment:
        guid = args.assignment_guid or record.get('assignmentGuid') or str(uuid.uuid5(
            uuid.NAMESPACE_URL, scope.lower() + ':' + principal + ':' + role['id'].lower()))
        assignment = az('role', 'assignment', 'create', '--assignee-object-id', principal,
                        '--assignee-principal-type', 'ServicePrincipal', '--role', role['id'],
                        '--scope', scope, '--name', str(uuid.UUID(guid)))
        assignment_owned = True
    record.setdefault('assignmentPreexisting', not assignment_owned)
    record.update({'assignmentOwned': assignment_owned, 'assignmentId': assignment['id'],
                   'assignmentGuid': assignment['name'], 'status': 'assigned',
                   'terraformRoleDefinitionImportId': role['id'] + '|' + scope,
                   'terraformAssignmentImportId': assignment['id'],
                   'rollbackAssignmentCommand': 'az role assignment delete --ids ' + assignment['id']})
    save(path, record, 'assignment-verified')
    imports(record)
    print('Evidence:', path)


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, ValueError, KeyError, OSError) as error:
        print('Registration IAM stopped: ' + str(error), file=sys.stderr)
        sys.exit(1)
