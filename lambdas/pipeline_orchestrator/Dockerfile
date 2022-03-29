FROM python:3.9

COPY requirements.txt .
RUN ["pip", "install", "-r", "requirements.txt", "--target", "${LAMBDA_TASK_ROOT}"]

COPY pipeline_orchestrator /var/task/pipeline_orchestrator

CMD ["pipeline_orchestrator.handler"]
