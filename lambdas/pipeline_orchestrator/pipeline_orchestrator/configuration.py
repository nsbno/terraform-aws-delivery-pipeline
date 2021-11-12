import collections
import json
import os
from dataclasses import dataclass, field
from functools import partial
from io import BytesIO
from typing import Union, Callable
from zipfile import ZipFile

import boto3
import yaml


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
    def from_s3(cls, bucket: str, key: str, version_id: str) -> "DeploymentInfo":
        """Get the data from S3"""
        s3_client = boto3.resource("s3")

        trigger_file = s3_client.Object(bucket, key)
        data = trigger_file.get()["Body"].read()

        return cls(**json.loads(data), artifact_bucket=bucket)


@dataclass
class DeploymentStep:
    """Defines one deployment step. The statemachine use this to create a
    singular state.

    This closely maps to :class:`stepfunctions.steps.states.Task`. Check out
    that class' documentation to get a better understanding of what is happening
    here.
    """
    name: str
    """The name of this step"""

    type: str
    """What type of step is this? Can be 'lambda' or 'ecs'"""

    parameters: dict
    """Parameters the step will run with"""

    @classmethod
    def for_ecs(
        cls,
        image: str,
        command: str,
        log_stream_prefix: str,
        environment_variables: dict = None,
        **kwargs
    ) -> "DeploymentStep":
        """Defines a step for creating an ECS Task

        This will automatically create a task definition that the step will
        reference.

        :arg image: Container image that will be used for the task
        :arg command: What the container will run
        :arg log_stream_prefix: The prefix for logs in the log group.
                                Typically the name of the repo
        :arg environment_variables: Environment variables for the container
        :arg kwargs: Parameters for the dataclass' __init__
        """
        kwargs["type"] = "ecs"

        task_definition = TaskDefinition(
            family=kwargs["name"].lower().replace(" ", "_"),
            image=image,
            entrypoint=["/bin/sh", "-c"],
            command=[command],
            environment_variables=environment_variables or {},
            log_stream_prefix=log_stream_prefix,
        )

        if "parameters" not in kwargs:
            kwargs["parameters"] = {}

        kwargs["parameters"] = {
            "LaunchType": "FARGATE",
            "Cluster": os.environ["ECS_CLUSTER"],
            "TaskDefinition": task_definition.arn,
            "NetworkConfiguration": {
                "AwsvpcConfiguration": {
                    "Subnets": json.loads(os.environ["SUBNETS"]),
                    "AssignPublicIp": "ENABLED",
                }
            },
            **kwargs["parameters"]
        }

        return cls(**kwargs)

    @classmethod
    def for_lambda(
        cls,
        function_name: str,
        payload: dict,
        **kwargs
    ) -> "DeploymentStep":
        """Defines a step for creating a Lambda Task

        :arg function_name: Name or ARN of the function to use
        :arg payload: The payload to pass to the lambda function
        :arg kwargs: Parameters for the dataclass' __init__
        """
        kwargs["type"] = "lambda"

        if "parameters" not in kwargs:
            kwargs["parameters"] = {}

        kwargs["parameters"] = {
            "FunctionName": function_name,
            "Payload": payload,
            **kwargs["parameters"]
        }

        return cls(**kwargs)


def _load_deployment_configuration(bucket: str, key: str) -> dict:
    s3_client = boto3.resource("s3")

    with BytesIO(s3_client.Object(bucket, key).get()["Body"].read()) as stream:
        stream.seek(0)

        with ZipFile(stream, 'r') as artifact:
            with artifact.open(".deployment/config.yaml") as yaml_config:
                return yaml.safe_load(yaml_config)


def _create_deployment_steps(
    steps: list[Union[dict, str]],
    deployment_info: DeploymentInfo
) -> Callable:
    """Creates a builder for each environment.

    :arg steps: The steps that every deployment environment will run
    :arg deployment_info: Information about this spesific deployment.
    """
    def deployment_steps(environment_name: str):
        """Builds the steps that will be used for each d"""
        predefined_steps = {
            "bump_versions": partial(
                DeploymentStep.for_lambda,
                name="Bump Versions",
                function_name=os.environ["SET_VERSION_LAMBDA_ARN"],
                payload={
                    "role_to_assume": os.environ["SET_VERSION_ROLE"],
                    "ssm_prefix": os.environ["SET_VERSION_SSM_PREFIX"],
                    "get_versions": False,
                    "set_versions": True,
                    "ecr_applications": [],
                    "lambda_applications": [],
                    "lambda_s3_bucket": os.environ["SET_VERSION_ARTIFACT_BUCKET"],
                    "lambda_s3_prefix": f"nsbno/{deployment_info.git_repo}/lambdas",
                    "frontend_applications": [],
                    "frontend_s3_bucket": os.environ["SET_VERSION_ARTIFACT_BUCKET"],
                    "frontend_s3_prefix": f"nsbno/{deployment_info.git_repo}/frontends",
                    "account_id": json.loads(os.environ["DEPLOY_ACCOUNTS"])[environment_name.lower()],
                    "versions.$": "$.versions.Payload",
                }
            ),
            "deploy_terraform": partial(
                DeploymentStep.for_ecs,
                name="Deploy Terraform",
                image="vydev/terraform:1.0.8",
                command="echo 'Hello World'",
                log_stream_prefix=f"{deployment_info.git_repo}/{environment_name.lower()}",
                environment_variables={"TF_IN_AUTOMATION": "true"},
            )
        }

        built_steps = []
        for step in steps:
            if isinstance(step, str):
                built_steps.append(predefined_steps[step]())

        return built_steps

    return deployment_steps


def _flatten(list_: list) -> list:
    if isinstance(list_, list):
        return [a for i in list_ for a in _flatten(i)]
    else:
        return [list_]


def get_deployment_config(
    deployment_info: DeploymentInfo
) -> dict:
    """Loads information about this deployment from S3"""
    # configuration = _load_deployment_configuration(
    #     deployment_info.artifact_bucket,
    #     deployment_info.artifact_key
    # )
    configuration = {
        "flow": [
            ["service", "test", "stage"],
            "prod"
        ],
        "deployment": {
            "steps": [
                "bump_versions",
                "deploy_terraform"
            ]
        }
    }

    deployment_steps_creator = _create_deployment_steps(
        configuration["deployment"]["steps"],
        deployment_info
    )

    environments = {
        environment: deployment_steps_creator(environment)
        for environment in _flatten(configuration["flow"])
    }

    return {
        "flow": configuration["flow"],
        "environments": environments
    }


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
    log_stream_prefix: str = ""

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
                        for name, value in self.environment_variables.items()
                    ],
                    "logConfiguration": {
                        "logDriver": "awslogs",
                        "options": {
                            "awslogs-group": self.log_group,
                            "awslogs-region": self.log_region,
                            "awslogs-stream-prefix": self.log_stream_prefix,
                        },
                    }
                },
            ],
        )

        self.arn = response["taskDefinition"]["taskDefinitionArn"]

        return self
