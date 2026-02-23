import aws_cdk as cdk
from aws_cdk import aws_iam as iam
from aws_cdk import aws_lambda as lambda_
from aws_cdk import aws_secretsmanager as secretsmanager
from constructs import Construct

from .config import EnvConfig


class SecretRotationStack(cdk.Stack):
    def __init__(
        self,
        scope: Construct,
        construct_id: str,
        *,
        config: EnvConfig,
        refresh_secret: secretsmanager.ISecret,
        **kwargs,
    ) -> None:
        super().__init__(scope, construct_id, **kwargs)

        handler_code = """
import json
import random
import string
import boto3

sm = boto3.client('secretsmanager')

def _rand(n=20):
    chars = string.ascii_letters + string.digits
    return ''.join(random.choice(chars) for _ in range(n))

def _current(secret_id):
    return json.loads(sm.get_secret_value(SecretId=secret_id, VersionStage='AWSCURRENT')['SecretString'])

def _pending_exists(secret_id, token):
    try:
        sm.get_secret_value(SecretId=secret_id, VersionId=token, VersionStage='AWSPENDING')
        return True
    except sm.exceptions.ResourceNotFoundException:
        return False

def create_secret(secret_id, token):
    if _pending_exists(secret_id, token):
        return
    current = _current(secret_id)
    pending = {
        'refresh_user': current.get('refresh_user', f'mood-{_rand(8)}'),
        'refresh_password': _rand(24),
    }
    sm.put_secret_value(
        SecretId=secret_id,
        ClientRequestToken=token,
        SecretString=json.dumps(pending),
        VersionStages=['AWSPENDING'],
    )

def set_secret(secret_id, token):
    return

def test_secret(secret_id, token):
    pending = sm.get_secret_value(SecretId=secret_id, VersionId=token, VersionStage='AWSPENDING')
    json.loads(pending['SecretString'])

def finish_secret(secret_id, token):
    meta = sm.describe_secret(SecretId=secret_id)
    current_version = None
    for version, stages in meta.get('VersionIdsToStages', {}).items():
        if 'AWSCURRENT' in stages:
            current_version = version
            break
    if current_version == token:
        return
    sm.update_secret_version_stage(
        SecretId=secret_id,
        VersionStage='AWSCURRENT',
        MoveToVersionId=token,
        RemoveFromVersionId=current_version,
    )

def lambda_handler(event, context):
    secret_id = event['SecretId']
    token = event['ClientRequestToken']
    step = event['Step']

    meta = sm.describe_secret(SecretId=secret_id)
    versions = meta.get('VersionIdsToStages', {})
    if token not in versions:
        raise ValueError('Invalid rotation token')
    if 'AWSCURRENT' in versions[token]:
        return
    if 'AWSPENDING' not in versions[token]:
        raise ValueError('Token not AWSPENDING')

    if step == 'createSecret':
        create_secret(secret_id, token)
    elif step == 'setSecret':
        set_secret(secret_id, token)
    elif step == 'testSecret':
        test_secret(secret_id, token)
    elif step == 'finishSecret':
        finish_secret(secret_id, token)
    else:
        raise ValueError('Invalid step')
"""

        fn = lambda_.Function(
            self,
            "RotationLambda",
            function_name=f"mood-{config.env_name}-refresh-secret-rotation",
            runtime=lambda_.Runtime.PYTHON_3_12,
            handler="index.lambda_handler",
            timeout=cdk.Duration.seconds(60),
            code=lambda_.Code.from_inline(handler_code),
        )

        refresh_secret.grant_read(fn)
        refresh_secret.grant_write(fn)
        fn.add_to_role_policy(
            iam.PolicyStatement(
                actions=["kms:Decrypt"],
                resources=["*"],
            )
        )

        invoke_permission = lambda_.CfnPermission(
            self,
            "AllowSecretsManagerInvoke",
            action="lambda:InvokeFunction",
            function_name=fn.function_name,
            principal="secretsmanager.amazonaws.com",
            source_arn=refresh_secret.secret_arn,
        )

        rotation_schedule = secretsmanager.CfnRotationSchedule(
            self,
            "RotationSchedule",
            secret_id=refresh_secret.secret_arn,
            rotation_lambda_arn=fn.function_arn,
            rotation_rules=secretsmanager.CfnRotationSchedule.RotationRulesProperty(
                automatically_after_days=7
            ),
        )
        rotation_schedule.add_dependency(invoke_permission)

        cdk.CfnOutput(
            self,
            "SecretRotationLambdaArn",
            value=fn.function_arn,
            export_name=f"Mood-{config.env_name}-SecretRotationLambdaArn",
        )
