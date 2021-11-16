"""Sidecar container that reports back to Step Functions"""
import json
import logging
import os
import signal

import boto3
import requests


logger = logging.getLogger(__name__)
logger.setLevel(logging.DEBUG)


def report_to_step_function(token: str, success: bool, output: str, error: str):
    """Reports the status """
    sfn_client = boto3.client("stepfunctions")

    if success:
        logger.info("Reporting success!")
        sfn_client.send_task_success(
            taskToken=token,
            output=output
        )
    else:
        logger.info("Reporting Failure!")
        sfn_client.send_task_failure(
            taskToken=token,
            error=error,
            cause=output
        )


def get_container_info(container_name: str) -> dict:
    """Gets information about the given container

    See for more info:
    https://docs.aws.amazon.com/AmazonECS/latest/userguide/task-metadata-endpoint-v4-fargate.html

    :arg container_name: Name of the container to get info about
    """
    task_info = requests.get(
        f"{os.environ['ECS_CONTAINER_METADATA_URI_V4']}/task"
    ).json()

    logger.debug(task_info)

    return next(filter(
        lambda container: container["Name"] == container_name,
        task_info["Containers"]
    ))


def build_log_stream_link(container_info: dict) -> str:
    """Creates a link to CloudWatch Logs based on the container info

    """
    log_info = container_info["LogOptions"]

    return f"https://{log_info['awslogs-region']}.console.aws.amazon.com/" \
           f"cloudwatch/home?region={log_info['awslogs-region']}" \
           f"#logsV2:log-groups/" \
           f"log-group/{log_info['awslogs-group'].replace('/', '$252F')}/" \
           f"log-events/{log_info['awslogs-stream'].replace('/', '$252F')}"


def main(token: str, main_container_name: str):
    logger.info("Started! Waiting for SIGTERM...")

    # We want to wait until the main container exists.
    # The main container is essential, so if it exits docker will send
    # a SIGTERM to all other containers in the task.
    # But we also have to set SIGTERM as blocking to allow us to catch it later.
    # If not we'd just instant exit and never recieve it.
    signal.pthread_sigmask(signal.SIG_BLOCK, [signal.SIGTERM])
    signal.sigwait([signal.SIGTERM])

    logger.info("Received SIGTERM! Checking status on main container...")

    # We now got 30 seconds to do our business!

    main_container_info = get_container_info(main_container_name)
    logger.debug(main_container_info)

    output = {
        "log_stream": build_log_stream_link(main_container_info)
    }

    report_to_step_function(
        token=token,
        success=main_container_info["ExitCode"] == 0,
        output=json.dumps(output),
        error="NonZeroExitCode"
    )


if __name__ == "__main__":
    # TODO: Send fail if we get an exception here
    try:
        main(
            token=os.environ["TASK_TOKEN"],
            main_container_name=os.environ["MAIN_CONTAINER_NAME"]
        )
    except Exception:
        logger.exception(
            "Caught unknown exception in the main function. Sending failure..."
        )

        report_to_step_function(
            token=os.environ["TASK_TOKEN"],
            success=False,
            output="Sidecar failed for unknown reason",
            error="Unknown"
        )

