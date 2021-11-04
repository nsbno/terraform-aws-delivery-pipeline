import dataclasses
import json
import logging
from dataclasses import dataclass, field
from io import BytesIO
from itertools import zip_longest
from typing import Union, Optional
from zipfile import ZipFile

import boto3
import yaml

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
class _StepFunctionData:
    """Base class for common state function methods"""
    def to_sfn(self):
        """Turns the data into valid state function language JSON"""
        pass


@dataclass
class StepFunctionState(_StepFunctionData):
    """Simple implementation of the step function language

    The spec can be found here: https://states-language.net/spec.html
    """
    type: str
    # input_path: list = None
    # output_path: list = None
    # next: str = None
    # end: bool = None
    # result_path: list = None
    # parameters: dict = None
    # result_selector: dict = None
    # catch: list[dict] = None

    # def __post_init__(self):
    #     if not (self.next or self.end) and self.type not in ("Fail", "Succeed", "Choice"):
    #         raise ValueError("Either 'next' or 'end' has to be specified")
    #     if self.next and self.end:
    #         raise ValueError("The variables 'next' and 'end' are mutually exclusive")


@dataclass
class StepFunctionParallel(StepFunctionState):
    branches: list["StepFunctionSteps"]
    type: str = "Parallel"


@dataclass
class Default(_StepFunctionData):
    next: str


@dataclass
class ChoiceRule(_StepFunctionData):
    """A rule for a StepFunctionChoice

    See the specification for options:
    https://states-language.net/spec.html#choice-state
    """
    variable: str
    test: str
    test_value: any
    next: str

    def to_sfn(self):
        return {
            "Variable": self.variable,
            self.test: self.test_value,
            "Next": self.next
        }


@dataclass
class StepFunctionChoice(StepFunctionState):
    choices: list[ChoiceRule]
    default: str
    type: str = "Choice"


@dataclass
class StepFunctionSteps(_StepFunctionData):
    """Steps to execute. The first state is the start state"""
    steps: dict[str, StepFunctionState]
    start_at: str = field(init=False)

    def __post_init__(self):
        self.start_at = list(self.steps)[0]


def _create_state_machine(steps: dict, error_catcher: StepFunctionState) -> StepFunctionSteps:
    for current_step, next_step in zip_longest(list(steps), list(steps)[1:]):
        if next_step:
            if steps[current_step].type == "Choice":
                steps[current_step].default = next_step
            else:
                steps[current_step].next = next_step
                steps[current_step].end = None
        else:
            steps[current_step].next = None
            steps[current_step].end = True

    return StepFunctionSteps(steps={**steps, "Prod - Catch Errors": error_catcher})


def _create_deployment_steps(envrionment: str) -> dict:
    return {
        f"{envrionment} - Bump Version": StepFunctionState(),
        f"{envrionment} - Deploy Terraform": StepFunctionState(),
    }


def deployment_configuration(deployment_info: DeploymentInfo):
    """Creates or modifies the step function pipeline according to the
    deployment configuration."""
    config = _get_config(deployment_info.artifact_bucket, deployment_info.artifact_key)

    # TODO: Build the SFN JSON
    state_machine = _create_state_machine(
        steps={
            "Deploy Service, Test and Stage": StepFunctionParallel(
                branches=[
                    StepFunctionSteps(steps=_create_deployment_steps("Service")),
                    StepFunctionSteps(steps=_create_deployment_steps("Test")),
                    StepFunctionSteps(steps=_create_deployment_steps("Stage"))
                ]
            )
            "Check Errors": StepFunctionChoice(),
            **_create_deployment_steps("Prod"),
        },
        error_catcher=StepFunctionState(),
    )

    # TODO: Deploy the SFN.
    pass


def start_pipeline(pipeline_arn: str, deployment_info: DeploymentInfo) -> None:
    """Starts the pipeline based on the deployment info.

    Do note that because we are editing the pipeline earlier, we have to wait a
    few seconds before starting. This is because step functions are eventually
    consistent.

    Find out more here:
    https://docs.aws.amazon.com/step-functions/latest/dg/concepts-read-consistency.html
    """
    account_id = boto3.client("sts").get_caller_identity().get("Account")
    region = boto3.session.Session().region_name

    client = boto3.client("stepfunctions")
    client.start_execution(
        stateMachineArn=f"arn:aws:states:{region}:{account_id}:stateMachine:{deployment_info.git_repo}",
        name=deployment_info.git_sha1,
        input=dataclasses.asdict(deployment_info),
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
    pipeline_arn = deployment_configuration(deployment_info)
    logger.info("Finished Deployment Configuration")

    logger.info("Starting the pipeline!")
    start_pipeline(pipeline_arn, deployment_info)
    logger.info("Finished starting the pipeline!")
