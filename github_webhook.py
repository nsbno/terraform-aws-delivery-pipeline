import json
import logging
import os

import boto3
import requests

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)


def _create_github_deployment(deployments_url: str):
    # TODO: This is for demo purposes and must be changed to be propper modular
    response = requests.post(
        deployments_url,
        auth=(os.environ["GH_USERNAME"], os.environ["GH_PASSWORD"]),
        json={
            "auto_merge": False,
            "required_contexts": False,
            "environment": "test",
        }
    )

    print(response.status_code)
    print(response.text)

    return response.json()["url"]


def _set_github_deployment_state(deployment_url: str, state: str):
    # TODO: This is for demo purposes and must be changed to be propper modular
    response = requests.post(
        f"{deployment_url}/statuses",
        auth=(os.environ["GH_USERNAME"], os.environ["GH_PASSWORD"]),
        json={
            "state": state,
        }
    )

    print(response.status_code)
    print(response.text)

    return response.json()


def start_deployment(event):
    """Initiates our deployment pipeline"""
    data = json.loads(event["body"])

    if not data["ref"] == "refs/heads/master":
        logger.info(f"Pushed data was not in master. It was in {data['ref']}.")
        return
    if data["before"] == data["after"]:
        logger.info("There were no changes in this push.")
        return

    deployment_url = _create_github_deployment(data["repository"]["deployments_url"])
    _set_github_deployment_state(deployment_url, "queued")

    lambda_client = boto3.client("lambda")
    response = lambda_client.invoke(
        # TODO: Don't hardcode these values
        FunctionName="nicolas-infrademo-deployment-pipeline-delivery-pipeline-trigger",
        InvocationType="RequestResponse",
        Payload=json.dumps({
            "terraform_version": "1.0.0",
            "environment": "test",
            "commit": data["after"],
            "deployment_url": deployment_url
        })
    )


def is_valid_signature(event):
    # TODO: Implement a check for the GiHub signature field to verify the origin
    return True


def handler(event, _):
    if not is_valid_signature(event):
        return json.dumps({
            "statusCode": 401,
            "body": "Request signature does not match GitHub's signature"
        })

    github_event = event["headers"]["X-GitHub-Event"]
    if github_event == "push":
        start_deployment(event)
    else:
        logger.info(f"No relevant event from GitHub. Event was {github_event}")

    return {
        "statusCode": 200,
        "body": "Deployment started"
    }
