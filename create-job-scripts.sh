#!/bin/bash

script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
temp_dir=$(mktemp -d)

_jq() {
  echo ${1} | base64 --decode | jq -r ${2}
}
_jq_q() {
  echo ${1} | base64 --decode | jq ${2}
}

subl ${temp_dir}

# latest mozilla-central
# build_index_prefix=gecko.v2.mozilla-central.latest.firefox

# contains a patch allowing external pypi (https://hg.mozilla.org/try/rev/07d952b)
build_index_prefix=gecko.v2.try.revision.d6f981475764dc0fab78bc4f5d8d4601e1ca21f6.firefox

indexed_builds=( ${build_index_prefix}.win64-debug ${build_index_prefix}.win64-asan-opt ${build_index_prefix}.win64-ccov-opt )
worker_types=( t-win10-64 )

mkdir -p ${temp_dir}/jobs
rm ${script_dir}/.github/workflows/*.yml 2> /dev/null
for indexed_build in ${indexed_builds[@]}; do
  curl -sL https://firefox-ci-tc.services.mozilla.com/api/index/v1/task/${indexed_build} --output ${temp_dir}/indexed-build-task-${indexed_build}.json
  build_task_id=$(jq -r '.taskId' ${temp_dir}/indexed-build-task-${indexed_build}.json)
  curl -sL https://firefox-ci-tc.services.mozilla.com/api/queue/v1/task/${build_task_id} --output ${temp_dir}/build-task-${build_task_id}.json
  build_task_group_id=$(jq -r '.taskGroupId' ${temp_dir}/build-task-${build_task_id}.json)
  echo "- build task id: ${build_task_id}, in task group: ${build_task_group_id}, determined for indexed build: ${indexed_build}"

  i="1"
  continuation_token=""
  while [ $i -lt 2 ] || [ "${continuation_token}" != "null" ]; do
    if [ $i -lt 2 ]; then
      curl -sL "https://firefox-ci-tc.services.mozilla.com/api/queue/v1/task-group/${build_task_group_id}/list" --output ${temp_dir}/indexed-build-task-group-${indexed_build}-$(printf "%03d" ${i}).json
    else
      curl -sL "https://firefox-ci-tc.services.mozilla.com/api/queue/v1/task-group/${build_task_group_id}/list?continuationToken=${continuation_token}" --output ${temp_dir}/indexed-build-task-group-${indexed_build}-$(printf "%03d" ${i}).json
    fi
    continuation_token=$(jq -r '.continuationToken' ${temp_dir}/indexed-build-task-group-${indexed_build}-$(printf "%03d" ${i}).json)
    i=$[$i+1]
  done
  jq -s '[.[].tasks]|flatten' ${temp_dir}/indexed-build-task-group-${indexed_build}-*.json > ${temp_dir}/indexed-build-task-group-${indexed_build}.json

  for worker_type in ${worker_types[@]}; do
    jq --arg workerType ${worker_type} --arg buildTaskId ${build_task_id} '[ .[] | select(.status.workerType == $workerType and (.task.dependencies as $d | $buildTaskId | IN($d[]))) ]' ${temp_dir}/indexed-build-task-group-${indexed_build}.json > ${temp_dir}/tasks-${worker_type}.json
    echo "  - $(jq length ${temp_dir}/tasks-${worker_type}.json) tasks found for worker type: ${worker_type}"

    for task_base64 in $(jq -r '.[] | @base64' ${temp_dir}/tasks-${worker_type}.json); do
      task_name=$(_jq ${task_base64} '.task.metadata.name')
      test_suite=$(_jq ${task_base64} '.task.extra.suite')
      job=(${task_name/\// })
      workflow_path=${script_dir}/.github/workflows/${test_suite}-${job[0]}.yml
      if [ ! -f ${workflow_path} ]; then
        echo "---" > ${workflow_path}
        echo "name: ${test_suite} (${job[0]})" >> ${workflow_path}
        echo "on:" >> ${workflow_path}
        echo "  push:" >> ${workflow_path}
        echo "    branches:" >> ${workflow_path}
        echo "      - main" >> ${workflow_path}
        echo "jobs:" >> ${workflow_path}
        echo "created: ${workflow_path}"
      else
        echo "detected: ${workflow_path}"
      fi
      echo "  ${job[1]}:" >> ${workflow_path}
      echo "    runs-on: windows-2019" >> ${workflow_path}
      echo "    steps:" >> ${workflow_path}
      echo "      - uses: actions/checkout@v2" >> ${workflow_path}
      echo "      - name: mounts" >> ${workflow_path}
      echo "        run: |" >> ${workflow_path}
      for mount_base64 in $(_jq ${task_base64} '.task.payload.mounts[]|@base64'); do
        case $(_jq ${mount_base64} .format) in
          zip)
            artifact=$(_jq ${mount_base64} .content.artifact)
            echo "          curl -L https://firefox-ci-tc.services.mozilla.com/api/queue/v1/task/$(_jq ${mount_base64} .content.taskId)/artifacts/${artifact} --output $(basename ${artifact})" >> ${workflow_path}
            echo "          7z x -o$(_jq ${mount_base64} .directory) $(basename ${artifact})" >> ${workflow_path}
            ;;
          null)
            echo "          curl -L $(_jq ${mount_base64} .content.url) --output $(_jq ${mount_base64} .file)" >> ${workflow_path}
            ;;
        esac
      done
      echo "      - name: dependencies" >> ${workflow_path}
      echo "        run: |" >> ${workflow_path}
      echo "          python -m pip install --upgrade zstandard" >> ${workflow_path}
      echo "          python -m pip install --upgrade certifi" >> ${workflow_path}
      echo "      - name: test" >> ${workflow_path}
      echo "        env:" >> ${workflow_path}
      echo "          TASKCLUSTER_ROOT_URL: https://firefox-ci-tc.services.mozilla.com" >> ${workflow_path}
      echo "          PYTHON: C:\hostedtoolcache\windows\Python\3.7.9\x64\python.exe" >> ${workflow_path}
      for env_key in $(_jq ${task_base64} '.task.payload.env|to_entries|.[].key'); do
        if [ "${env_key}" != "PYTHON" ]; then
          env_value=$(_jq_q ${task_base64} .task.payload.env.${env_key})
          echo "          ${env_key}: ${env_value}" >> ${workflow_path}
        fi
      done
      echo "        run: |" >> ${workflow_path}
      for command in "$(_jq ${task_base64} '.task.payload.command[]')"; do
        # lose the env specific python paths in favour of the system default python
        tidied_command=$(echo ${command} | sed 's+C:/mozilla-build/python3/python3.exe+python+g' | sed 's+c:\\mozilla-build\\python3\\python3.exe+python+g')
        echo "          ${tidied_command}" >> ${workflow_path}
      done
    done
  done
done
