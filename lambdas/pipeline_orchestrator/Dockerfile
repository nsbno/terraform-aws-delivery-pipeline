FROM public.ecr.aws/lambda/python:3.9

COPY requirements.txt .
RUN ["pip", "install", "-r", "requirements.txt", "--target", "."]

COPY pipeline_orchestrator /var/task/pipeline_orchestrator

CMD ["pipeline_orchestrator.handler"]
