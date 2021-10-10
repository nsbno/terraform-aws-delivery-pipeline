import json
import os
import logging
from dataclasses import dataclass

import boto3

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)

@dataclass
class TaskDefinition:
    """Task definition for any ECS container

    Used to specify and create a task definition in AWS.
    """
    image_version: str
    entrypoint: list[str]
    command: list[str]

    task_role_arn: str = os.environ["TASK_ROLE_ARN"]
    execution_role_arn: str = os.environ["EXECUTION_ROLE_ARN"]

    family: str = os.environ["TASK_FAMILY"]
    image: str = os.environ["DOCKER_IMAGE"]

    log_group: str = os.environ["LOG_GROUP"]
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
                    "name": "terraform",
                    "image": f"{self.image}:{self.image_version}",
                    "entryPoint": self.entrypoint,
                    "command": self.command,
                    "logConfiguration": {
                        "logDriver": "awslogs",
                        "options": {
                            "awslogs-group": self.log_group,
                            "awslogs-region": self.log_region,
                            # TODO: Might be usefull to use the commit hash here
                            "awslogs-stream-prefix": self.family,
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
    # TODO: Resolve environment name to actual account number + role name.
    # TODO: Create an container that assumes a role and runs terraform apply
    commands = [
        f"aws s3 cp s3://{os.environ['ARTIFACT_BUCKET']}/{event['commit']}.zip ./infrastructure.zip",
        f"unzip infrastructure.zip",
    ]

    command = " && ".join(commands)

    logger.info(command)

    with TaskDefinition(
        image_version=event["terraform_version"],
        entrypoint=["/bin/sh", "-c"],
        command=[command]
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

    # TODO: Report back if everything went OK + where to get logs
    logger.info(task_result)
