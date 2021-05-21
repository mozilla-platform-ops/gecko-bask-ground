#!/bin/bash

script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

indexed_builds=( gecko.v2.mozilla-central.latest.firefox.win64-debug gecko.v2.mozilla-central.latest.firefox.win64-asan-opt gecko.v2.mozilla-central.latest.firefox.win64-ccov-opt )
worker_types=( t-win10-64 )


rm ${script_dir}/jobs/*.yml
mkdir -p ${script_dir}/jobs
for indexed_build in ${indexed_builds[@]}; do
  curl -sL https://firefox-ci-tc.services.mozilla.com/api/index/v1/task/${indexed_build} --output indexed-build-task-${indexed_build}.json
  build_task_id=$(jq -r '.taskId' indexed-build-task-${indexed_build}.json)
  curl -sL https://firefox-ci-tc.services.mozilla.com/api/queue/v1/task/${build_task_id} --output build-task-${build_task_id}.json
  build_task_group_id=$(jq -r '.taskGroupId' build-task-${build_task_id}.json)
  echo "- build task id: ${build_task_id}, in task group: ${build_task_group_id}, determined for indexed build: ${indexed_build}"

  i="1"
  continuation_token=""
  while [ $i -lt 2 ] || [ "${continuation_token}" != "null" ]; do
    if [ $i -lt 2 ]; then
      curl -sL "https://firefox-ci-tc.services.mozilla.com/api/queue/v1/task-group/${build_task_group_id}/list" --output indexed-build-task-group-${indexed_build}-$(printf "%03d" ${i}).json
    else
      curl -sL "https://firefox-ci-tc.services.mozilla.com/api/queue/v1/task-group/${build_task_group_id}/list?continuationToken=${continuation_token}" --output indexed-build-task-group-${indexed_build}-$(printf "%03d" ${i}).json
    fi
    continuation_token=$(jq -r '.continuationToken' indexed-build-task-group-${indexed_build}-$(printf "%03d" ${i}).json)
    i=$[$i+1]
  done
  jq -s '[.[].tasks]|flatten' indexed-build-task-group-${indexed_build}-*.json > indexed-build-task-group-${indexed_build}.json
  #curl -sL https://firefox-ci-tc.services.mozilla.com/api/queue/v1/task-group/${build_task_group_id}/list --output indexed-build-task-group-${indexed_build}.json

  for worker_type in ${worker_types[@]}; do
    jq --arg workerType ${worker_type} --arg buildTaskId ${build_task_id} '[ .[] | select(.status.workerType == $workerType and (.task.dependencies as $d | $buildTaskId | IN($d[]))) ]' indexed-build-task-group-${indexed_build}.json > tasks-${worker_type}.json
    echo "  - $(jq length tasks-${worker_type}.json) tasks found for worker type: ${worker_type}"

    for task_base64 in $(jq -r '.[] | @base64' tasks-${worker_type}.json); do
      _jq() {
        echo ${task_base64} | base64 --decode | jq -r ${1}
      }
      task_name=$(_jq '.task.metadata.name')
      test_suite=$(_jq '.task.extra.suite')
      commit_sha=$(_jq '.task.payload.env.GECKO_HEAD_REV')
      command_0=$(_jq '.task.payload.command[0]')
      #mozharness_artifact_task_id=$(_jq '.task.payload.mounts[] | select(.format == "zip" and .directory == "mozharness") | .content.taskId')


      job=(${task_name/\// })
      workflow_path=${script_dir}/jobs/${test_suite}-${job[0]}.yml
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
      echo "          curl -L https://hg.mozilla.org/try/raw-file/${commit_sha}/taskcluster/scripts/misc/fetch-content --output fetch-content" >> ${workflow_path}
      echo "          curl -L https://hg.mozilla.org/try/raw-file/${commit_sha}/taskcluster/scripts/run-task --output run-task" >> ${workflow_path}
      echo "          curl -L https://firefox-ci-tc.services.mozilla.com/api/queue/v1/task/${build_task_id}/artifacts/public/build/mozharness.zip --output mozharness.zip" >> ${workflow_path}
      echo "          7z x -omozharness mozharness.zip" >> ${workflow_path}
      echo "      - name: dependencies" >> ${workflow_path}
      echo "        run: |" >> ${workflow_path}
      echo "          python -m pip install --upgrade zstandard" >> ${workflow_path}
      echo "          python -m pip install --upgrade certifi" >> ${workflow_path}
      echo "      - name: test" >> ${workflow_path}
      echo "        env:" >> ${workflow_path}
      echo "          TASKCLUSTER_ROOT_URL: https://firefox-ci-tc.services.mozilla.com" >> ${workflow_path}
      echo "          PYTHON: C:\hostedtoolcache\windows\Python\3.7.9\x64\python.exe" >> ${workflow_path}
      echo "        run: |" >> ${workflow_path}
      echo "          ${command_0/C:\/mozilla-build\/python3\/python3.exe run-task -- c:\\\\mozilla-build\\\\python3\\\\python3.exe/python run-task -- python}" >> ${workflow_path}
    done
  done
done
