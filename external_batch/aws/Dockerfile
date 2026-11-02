# Runner image for AWS Batch array tasks.
# Build from the external_batch/ directory so both COPY paths resolve:
#   docker build -f aws/Dockerfile -t <account>.dkr.ecr.<region>.amazonaws.com/osaf-batch-runner:<os_ver> .
#   docker push  <account>.dkr.ecr.<region>.amazonaws.com/osaf-batch-runner:<os_ver>
ARG OPENSTUDIO_VERSION=3.11.0
FROM nrel/openstudio:${OPENSTUDIO_VERSION}

# ruby for the (stdlib-only) runner + AWS CLI v2 for the S3 sync in/out
RUN apt-get update && \
    apt-get install -y --no-install-recommends ruby curl unzip ca-certificates && \
    curl -s https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o /tmp/awscliv2.zip && \
    unzip -q /tmp/awscliv2.zip -d /tmp && /tmp/aws/install && \
    rm -rf /tmp/aws /tmp/awscliv2.zip /var/lib/apt/lists/* && \
    apt-get clean

COPY runner/run_chunk.rb /usr/local/openstudio-batch/run_chunk.rb
COPY demo/aggregate_csv.rb /usr/local/openstudio-batch/aggregate_csv.rb
COPY aws/task_wrapper.sh /usr/local/openstudio-batch/task_wrapper.sh
RUN chmod +x /usr/local/openstudio-batch/task_wrapper.sh

ENTRYPOINT ["/usr/local/openstudio-batch/task_wrapper.sh"]
