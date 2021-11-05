import dataclasses
import json
import logging
import os
from dataclasses import dataclass, field
from io import BytesIO
from zipfile import ZipFile

import boto3
import yaml
from stepfunctions.steps import states, compute
from stepfunctions.steps.choice_rule import ChoiceRule
from stepfunctions.workflow import Workflow

logger = logging.getLogger(__name__)
logger.setLevel(logging.DEBUG)


@dataclass
class DeploymentInfo:
    """The info we expect from any provider to be able to start the pipeline."""
    git_owner: str
    git_repo: str
    git_branch: str
    git_user: str
    git_sha1: str
    artifact_bucket: str
    artifact_key: str = field(init=False)

    def __post_init__(self):
        self.artifact_key = "/".join([
            self.artifact_bucket,
            self.git_owner,
            self.git_repo,
            "branches",
            self.git_branch,
            f"{self.git_sha1}.zip"
        ])

    @classmethod
    def from_s3(cls, bucket: str, key: str, version_id: str) -> object:
        """Get the data from S3"""
        s3_client = boto3.resource("s3")

        trigger_file = s3_client.Object(bucket, key)
        data = trigger_file.get(VersionId=version_id)["Body"].read()

        return cls(**json.loads(data), artifact_bucket=bucket)


def _get_config(bucket: str, key: str) -> dict:
    """Loads"""
    s3_client = boto3.resource("s3")

    with BytesIO(s3_client.Object(bucket, key).get()["Body"].read()) as stream:
        stream.seek(0)

        with ZipFile(stream, 'r') as artifact:
            with artifact.open(".deployment/config.yaml") as yaml_config:
                return yaml.safe_load(yaml_config)


@dataclass
class TaskDefinition:
    """Task definition for any ECS container

    Used to specify and create a task definition in AWS.
    """
    family: str
    image: str
    entrypoint: list[str]
    command: list[str]
    environment_variables: dict[str, str]

    task_role_arn: str = os.environ["TASK_ROLE_ARN"]
    execution_role_arn: str = os.environ["EXECUTION_ROLE_ARN"]

    log_group: str = os.environ["LOG_GROUP"]
    log_region: str = os.environ["AWS_REGION"]

    compatability: str = "FARGATE"
    network_mode: str = "awsvpc"
    cpu: str = "256"
    memory: str = "512"

    def __post_init__(self):
        ecs_client = boto3.client("ecs")

        response = ecs_client.register_task_definition(
            family=self.family,
            taskRoleArn=self.task_role_arn,
            executionRoleArn=self.execution_role_arn,
            networkMode=self.network_mode,
            cpu=self.cpu,
            memory=self.memory,
            requiresCompatibilities=[self.compatability],
            containerDefinitions=[
                {
                    "name": self.family,
                    "image": self.image,
                    "entryPoint": self.entrypoint,
                    "command": self.command,
                    "environment": [
                        {"name": name, "value": value}
                        for name, value in self.environment_variables
                    ],
                    "logConfiguration": {
                        "logDriver": "awslogs",
                        "options": {
                            "awslogs-group": self.log_group,
                            "awslogs-region": self.log_region,
                            "awslogs-stream-prefix": self.family,
                        },
                    }
                },
            ],
        )

        self.arn = response["taskDefinition"]["taskDefinitionArn"]

        return self


def _deploy_to_environment(name: str, ):
    """Construct a chain of steps to deploy to a single environment.

    :arg name: The name of the environment
    """
    set_version = compute.LambdaStep(
        state_id=f"{name} - Set Versions",
        parameters={
            "FunctionName": "{env.set_version_lambda}",
            "Payload": {
                # TODO: Fix assumptions
                "role_to_assume": "${local.name_prefix}-trusted-set-version",
                "ssm_prefix": "local.name_prefix",
                "get_versions": False,
                "set_versions": True,
                "ecr_applications": [],
                "lambda_applications": [],
                "lambda_s3_bucket": "data.aws_s3_bucket.project_bucket.id",
                "lambda_s3_prefix": "nsbno/trafikksystem-aws/lambdas",
                "frontend_applications": [],
                "frontend_s3_bucket": "data.aws_s3_bucket.project_bucket.id",
                "frontend_s3_prefix": "nsbno/trafikksystem-aws/frontends",
                # TODO: This isn't applicable on the service account
                "account_id": "local.test_account_id",
                "versions.$": "$.versions",
            }
        },
        result_path=None
    )

    commands = [
        "echo Hello World"
    ]
    command = " && ".join(commands)
    task_definition = TaskDefinition(
        family="deploy",
        image="{image}:{verson}",
        entrypoint=["/bin/sh", "-c"],
        command=[command],
    )
    deploy = compute.EcsRunTaskStep(
        state_id=f"{name} - Deploy",
        parameters={
            "Cluster": os.environ["ECS_CLUSTER"],
            "TaskDefinition": task_definition.arn,
            "Overrides": {
                "ContainerOverrides": [{
                    # Giving the container a name with the git hash makes it
                    # easier to track.
                    "name.$": f"States.Format('{name}-{{}}', $.git-hash)"
                }]
            },
        },
        result_path=None
    )

    error_catcher = states.Pass(state_id=f"{name} - Error Catcher")
    catch_error = states.Catch(error_equals=["States.ALL"], next_step=error_catcher)

    set_version.add_catch(catch_error)
    deploy.add_catch(catch_error)

    return states.Chain(steps=[set_version, deploy])


def deployment_configuration(deployment_info: DeploymentInfo) -> Workflow:
    """Create a chain of steps that defines our deployment pipeline"""
    config = _get_config(deployment_info.artifact_bucket, deployment_info.artifact_key)

    get_latest_versions = compute.LambdaStep(
        state_id="Get Latest Artifact Versions",
        parameters={
            "FunctionName": os.environ["SET_VERSION_LAMBDA_ARN"],
            "Payload": {
                # TODO: Fix assumptions
                "role_to_assume": os.environ["SET_VERSION_ROLE"],
                "ssm_prefix": os.environ["SET_VERSION_SSM_PREFIX"],
                "get_versions": True,
                "set_versions": False,
                "ecr_applications": [],
                "lambda_applications": [],
                "lambda_s3_bucket": os.environ["SET_VERSION_LAMBDA_S3_BUCKET"],
                "lambda_s3_prefix": os.environ["SET_VERSION_LAMBDA_S3_PREFIX"],
                "frontend_applications": [],
                "frontend_s3_bucket": os.environ["SET_VERSION_FRONTEND_S3_BUCKET"],
                "frontend_s3_prefix": os.environ["SET_VERSION_FRONTEND_S3_PREFIX"]
            }
        },
        result_selector={
            "ecr.$": "$.Payload.ecr",
            "frontend.$": "$.Payload.frontend",
            "lambda.$": "$.Payload.lambda"
        },
        result_path="$.versions"
    )

    pre_prod_deployment = states.Parallel(
        state_id="Service, Test, Stage",
        result_path="$.results"
    )
    for environment in ("Service", "Test", "Stage"):
        pre_prod_deployment.add_branch(_deploy_to_environment(environment))

    fail_or_deploy_to_prod = states.Choice(state_id=f"{pre_prod_deployment} - Check for errors")
    # We don't want to deploy to prod if any the previous steps failed
    fail_or_deploy_to_prod.add_choice(
        ChoiceRule.IsPresent(
            variable="$.results[*].Error",
            value=True
        ),
        next_step=states.Fail(state_id=f"{pre_prod_deployment.state_id} Error")
    )

    fail_or_deploy_to_prod.default_choice(_deploy_to_environment("Prod"))

    main_flow = states.Chain(steps=[
        get_latest_versions,
        pre_prod_deployment,
        fail_or_deploy_to_prod
    ])

    workflow_name = f"deployment-{deployment_info.git_repo}"
    try:
        account_id = boto3.client("sts").get_caller_identity().get("Account")
        region = boto3.session.Session().region_name
        workflow = Workflow.attach(
            state_machine_arn=f"arn:aws:states:{region}:{account_id}:"
                              f"stateMachine:{workflow_name}"
        )
        workflow.update(definition=main_flow)
    except boto3.client("stepfunctions").exceptions.StateMachineDoesNotExist:
        workflow = Workflow(
            name=f"deployment-{deployment_info.git_repo}",
            definition=main_flow,
            role=os.environ["STEP_FUNCTION_ROLE_ARN"],
        )
        workflow.create()

    return workflow


def start_pipeline(workflow: Workflow, deployment_info: DeploymentInfo) -> None:
    """Starts the pipeline based on the deployment info.

    Do note that because we are editing the pipeline earlier, we have to wait a
    few seconds before starting. This is because step functions are eventually
    consistent.

    Find out more here:
    https://docs.aws.amazon.com/step-functions/latest/dg/concepts-read-consistency.html
    """
    workflow.execute(
        name=deployment_info.git_sha1,
        inputs=dataclasses.asdict(deployment_info),
    )


def handler(event, _):
    """Orchestrates the program

    :arg event: An S3 event
    :arg _: The context, we don't use this.
    """
    logger.debug(event)

    logger.info("Getting data from S3")
    deployment_info = DeploymentInfo.from_s3(
        bucket=event["Records"][0]["s3"]["bucket"]["name"],
        key=event["Records"][0]["s3"]["object"]["key"],
        version_id=event["Records"][0]["s3"]["object"].get("versionId", None)
    )
    logger.info("Got data from S3!")

    logger.info("Starting Deployment Configuration")
    # TODO: Only change if this handler or the actual config has changed.
    #       Might be a usecase for the pulumi automation api?
    workflow = deployment_configuration(deployment_info)
    logger.info("Finished Deployment Configuration")

    logger.info("Starting the pipeline!")
    start_pipeline(workflow, deployment_info)
    logger.info("Finished starting the pipeline!")
