import dataclasses
import logging

from pipeline_orchestrator.state_machine import state_machine_builder, \
    create_or_update_state_machine
from stepfunctions.workflow import Workflow

from pipeline_orchestrator.configuration import DeploymentInfo, get_deployment_config

logger = logging.getLogger(__name__)
logger.setLevel(logging.DEBUG)


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
    # TODO: TBH, we should remove the trigger from S3 and call directly from
    #       the CI instead. That way we create a true separation between
    #       artifact and deployment. That way we can also return errors to
    #       the CI about the initialization of the deployment.
    deployment_info = DeploymentInfo.from_s3(
        bucket=event["Records"][0]["s3"]["bucket"]["name"],
        key=event["Records"][0]["s3"]["object"]["key"],
        version_id=event["Records"][0]["s3"]["object"].get("versionId", None)
    )
    logger.info("Got data from S3!")

    logger.info("Getting deployment configuration")
    config = get_deployment_config(deployment_info)
    logger.info("Got deployment configuration")

    logger.info("Starting Deployment Configuration")
    machine = state_machine_builder(
        environments=config["environments"],
        flow=config["flow"],
        deployment_info=deployment_info
    )
    workflow = create_or_update_state_machine(
        name=f"deployment-{deployment_info.git_repo}",
        definition=machine
    )
    logger.info("Finished Deployment Configuration")

    logger.info("Starting the pipeline!")
    start_pipeline(workflow, deployment_info)
    logger.info("Finished starting the pipeline!")
