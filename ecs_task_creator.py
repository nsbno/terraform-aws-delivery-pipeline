import json
import os
import logging
from dataclasses import dataclass

import boto3
import requests

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)


def _set_github_deployment_state(deployment_url: str, state: str):
    # TODO: This is for demo purposes and must be changed to be propper modular
    response = requests.post(
        f"{deployment_url}/statuses",
        auth=(os.environ["GH_USERNAME"], os.environ["GH_PASSWORD"]),
        json={
            "state": state,
            "log_url": "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        }
    )

    return response.json()


@dataclass
class TaskDefinition:
    """Task definition for any ECS container

    Used to specify and create a task definition in AWS.
    """
    name: str
    image_version: str
    entrypoint: list[str]
    command: list[str]


    task_role_arn: str = os.environ["TASK_ROLE_ARN"]
    execution_role_arn: str = os.environ["EXECUTION_ROLE_ARN"]

    family: str = os.environ["TASK_FAMILY"]
    image: str = os.environ["DOCKER_IMAGE"]

    log_group: str = os.environ["LOG_GROUP"]
    log_prefix: str = os.environ["TASK_FAMILY"]
    log_region: str = os.environ["AWS_REGION"]

    compatability: str = "FARGATE"
    network_mode: str = "awsvpc"
    cpu: str = "256"
    memory: str = "512"

    def __enter__(self):
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
                    "name": self.name,
                    "image": f"{self.image}:{self.image_version}",
                    "entryPoint": self.entrypoint,
                    "command": self.command,
                    "logConfiguration": {
                        "logDriver": "awslogs",
                        "options": {
                            "awslogs-group": self.log_group,
                            "awslogs-region": self.log_region,
                            "awslogs-stream-prefix": self.log_prefix,
                        },
                    }
                },
            ],
        )

        self.arn = response["taskDefinition"]["taskDefinitionArn"]

        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        ecs_client = boto3.client("ecs")

        response = ecs_client.deregister_task_definition(
            taskDefinition=self.arn
        )


def handler(event: dict, _):
    """The entrypoint for our lambda function

    Handles input validation and process flow.

    In the event, we're expecting the following values:
     * terraform_version: The version of terraform to run.
     * environment: Which environment we're deploying to.
     * commit: A SHA-1 hash which will be used to pull from S3.
    """
    accounts = json.loads(os.environ["DEPLOY_ACCOUNTS"])
    selected_account = accounts[event["environment"]]
    deployment_role_arn = f"arn:aws:iam:{selected_account}:role/{os.environ['DEPLOY_ROLE']}"

    commands = [
        f"aws s3 cp s3://{os.environ['ARTIFACT_BUCKET']}/{event['commit']}.zip ./infrastructure.zip",
        f"unzip infrastructure.zip",

        f"aws configure set credential_source \"EcsContainer\"",
        f"aws configure set region \"{os.environ['AWS_REGION']}\"",
        f"aws configure set role_arn \"{deployment_role_arn}\"",

        f"cd terraform/{event['environment']}",
        f"terraform init -no-color",
        f"terraform plan -no-color"
    ]
    command = " && ".join(commands)

    logger.info(command)

    with TaskDefinition(
        name="terraform",
        image_version=event["terraform_version"],
        entrypoint=["/bin/sh", "-c"],
        command=[command],
        log_prefix=f"{event['commit']}/{event['environment']}"
    ) as task_definition:
        ecs_client = boto3.client("ecs")
        task_result = ecs_client.run_task(
            cluster=os.environ["ECS_CLUSTER"],
            launchType=task_definition.compatability,
            taskDefinition=task_definition.arn,
            count=1,
            platformVersion="LATEST",
            networkConfiguration={
                "awsvpcConfiguration": {
                    "subnets": json.loads(os.environ["SUBNETS"]),
                    "assignPublicIp": "ENABLED",
                }
            }
        )
        _set_github_deployment_state(event["deployment_url"], "in_progress")

    return {
        "logGroup": task_definition.log_group,
        "taskArn": task_result["tasks"][0]["taskArn"],
        "clusterArn": task_result["tasks"][0]["clusterArn"],
    }
