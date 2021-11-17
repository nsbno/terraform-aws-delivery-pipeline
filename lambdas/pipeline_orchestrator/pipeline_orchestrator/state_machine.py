import logging
import os
from functools import partial

from stepfunctions.steps.states import Task

from stepfunctions.steps.integration_resources import IntegrationPattern, \
    get_service_integration_arn
from stepfunctions.steps.compute import ECS_SERVICE_NAME, EcsApi
from stepfunctions.steps.fields import Field

import boto3
from stepfunctions.steps.choice_rule import ChoiceRule
from stepfunctions.steps import states, compute

from pipeline_orchestrator.configuration import DeploymentInfo, DeploymentStep
from stepfunctions.workflow import Workflow

logger = logging.getLogger(__name__)
logger.setLevel(logging.DEBUG)


# TODO: This is here while we wait for my PR to be accepted to the sfn module
#       https://github.com/aws/aws-step-functions-data-science-sdk-python/pull/180
class EcsRunTaskStep(Task):
    def __init__(
        self,
        state_id,
        wait_for_completion=True,
        wait_for_callback=False,
        **kwargs
    ):
        if wait_for_completion and wait_for_callback:
            raise ValueError("Only one of wait_for_completion and wait_for_callback can be true")

        if wait_for_callback:
            kwargs[Field.Resource.value] = get_service_integration_arn(
                ECS_SERVICE_NAME,
                EcsApi.RunTask,
                IntegrationPattern.WaitForTaskToken
            )
        elif wait_for_completion:
            kwargs[Field.Resource.value] = get_service_integration_arn(
                ECS_SERVICE_NAME,
                EcsApi.RunTask,
                IntegrationPattern.WaitForCompletion
            )
        else:
            kwargs[Field.Resource.value] = get_service_integration_arn(
                ECS_SERVICE_NAME,
                EcsApi.RunTask
            )

        super(EcsRunTaskStep, self).__init__(state_id, **kwargs)


def _environment(name: str, jobs: list[DeploymentStep]) -> states.Chain:
    """Builds an environment based on a predefined list of jobs

    Every step in an environment will be caught by an error catcher to allow
    other branches in the flow step to complete. The flow step itself is
    responsible for actually stopping the execution of the state machine.

    :arg name: The name of the environment
    :arg jobs: The jobs that this environment will execute
    :returns: A chain with all the jobs from the given jobs list.
    """
    environment = states.Chain()
    error_catcher = states.Pass(state_id=f"{name} - Error Catcher")
    catch_error = states.Catch(error_equals=["States.ALL"], next_step=error_catcher)

    job_type_functions = {
        "lambda": compute.LambdaStep,
        "ecs": partial(
            EcsRunTaskStep,
            wait_for_completion=False,
            wait_for_callback=True
        ),
    }
    for job in jobs:
        step = job_type_functions[job.type](
            state_id=f"{name} - {job.name}",
            parameters=job.parameters
        )

        step.add_catch(catch_error)
        environment.append(step)

    return environment


def state_machine_builder(
    environments: dict,
    flow: list,
    applications: dict,
    deployment_info: DeploymentInfo
) -> states.Chain:
    """Builds our state machine based on the git info and deployment config"""
    get_latest_versions = compute.LambdaStep(
        state_id="Get Latest Artifact Versions",
        parameters={
            "FunctionName": os.environ["SET_VERSION_LAMBDA_ARN"],
            "Payload": {
                "role_to_assume": os.environ["SET_VERSION_ROLE"],
                "ssm_prefix": os.environ["SET_VERSION_SSM_PREFIX"],
                "get_versions": True,
                "set_versions": False,
                "ecr_applications": applications["ecr"],
                "lambda_applications": applications["lambda"],
                "lambda_s3_bucket": os.environ["SET_VERSION_ARTIFACT_BUCKET"],
                "lambda_s3_prefix": f"{deployment_info.git_repo}/lambdas",
                "frontend_applications": applications["frontend"],
                "frontend_s3_bucket": os.environ["SET_VERSION_ARTIFACT_BUCKET"],
                "frontend_s3_prefix": f"{deployment_info.git_repo}/frontends"
            }
        },
        result_path="$.versions"
        # TODO: Ideally, we'd truncate the "Payload" part here, but the SDK
        #       doesn't support the ResultSelector yet.
        #       https://github.com/aws/aws-step-functions-data-science-sdk-python/pull/102
        #
        # result_selector={
        #     "ecr.$": "$.Payload.ecr",
        #     "frontend.$": "$.Payload.frontend",
        #     "lambda.$": "$.Payload.lambda"
        # },
    )

    deployments = {
        # TODO: Use "jobs" when we actually have a working config parser.
        environment: _environment(environment, jobs)
        for environment, jobs in environments.items()
    }

    main_flow = states.Chain()

    failed_deployment = states.Fail(state_id="Deployment Failed")
    success_deployment = states.Succeed(state_id="Deployment Succeeded")

    main_flow.append(get_latest_versions)

    for flow_step in flow:
        if not isinstance(flow_step, list):
            # Why wrap this in a list? While it is 100% possible to just append
            # this step by itself, I think it makes it more clear what is a
            # deployment stage and what is not in the actual output.
            flow_step = [flow_step]

        name = ", ".join(flow_step)

        parallel_deploy = states.Parallel(
            state_id=name,
            result_path="$.results"
        )
        for branch in flow_step:
            parallel_deploy.add_branch(deployments[branch])

        check_for_fail_in_parallel = states.Choice(
            state_id=f"{name} - Check for errors"
        )
        check_for_fail_in_parallel.add_choice(
            # We need to check each and every step, if not one might error and
            # we do not catch it. The JsonPath language has a wildcard selector,
            # but it is not supported by the choice rules.
            ChoiceRule.Or([
                ChoiceRule.IsPresent(
                    variable=f"$.results[{result_selector}].Error",
                    value=True
                )
                for result_selector in range(len(flow_step))
            ]),
            next_step=failed_deployment
        )

        main_flow.append(parallel_deploy)
        main_flow.append(check_for_fail_in_parallel)

    # Because the last step is a choice, we need an explicit success step.
    main_flow.append(success_deployment)

    return main_flow


def create_or_update_state_machine(
    name: str,
    definition: states.Chain,
) -> Workflow:
    """Creates or updates a repository's state machine based on the given
    definition.
    """
    try:
        account_id = boto3.client("sts").get_caller_identity().get("Account")
        region = boto3.session.Session().region_name
        workflow = Workflow.attach(
            state_machine_arn=f"arn:aws:states:{region}:{account_id}:"
                              f"stateMachine:{name}"
        )

        workflow.update(definition=definition)
        logger.info(f"Updated existing state machine: {workflow.state_machine_arn}")
    except boto3.client("stepfunctions").exceptions.StateMachineDoesNotExist:
        workflow = Workflow(
            name=name,
            definition=definition,
            role=os.environ["STEP_FUNCTION_ROLE_ARN"],
        )

        workflow.create()
        logger.info(f"Created new state machine: {workflow.state_machine_arn}")

    return workflow
