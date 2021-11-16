FROM python:3.9

WORKDIR /app

COPY requiremets.txt requiremets.txt
RUN ["pip", "install", "-r", "requiremets.txt"]

COPY step_function_status.py step_function_status.py

CMD ["python3", "./step_function_status.py"]
